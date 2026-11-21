#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# assemblrr Jellyfin 12+ configuration — sourced by config.sh / config_edit.sh
# Uses standard `Authorization: MediaBrowser` headers (Jellyfin 12 removed legacy X-Emby-* headers).
# Requires: lib/core.sh, lib/api.sh, lib/languages.sh

if [ -n "${_ASSEMBLRR_JELLYFIN_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_JELLYFIN_SOURCED=1

_jellyfin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/languages.sh
[ -f "$_jellyfin_dir/languages.sh" ] && source "$_jellyfin_dir/languages.sh"

_jf_auth_header() {
    local token="${1:-}"
    if [ -n "$token" ]; then
        printf 'Authorization: MediaBrowser Client="assemblrr", Device="assemblrr", DeviceId="assemblrr-cli", Version="1.0", Token="%s"' "$token"
    else
        printf 'Authorization: MediaBrowser Client="assemblrr", Device="setup-script", DeviceId="assemblrr-setup", Version="1.0"'
    fi
}

_jf_is_up() {
    http_request GET "http://${API_HOST}:8096/System/Info/Public"
}

_jf_first_user_ready() {
    http_request GET "http://${API_HOST}:8096/Startup/FirstUser" || return 1
    [ -n "$(printf '%s' "$HTTP_BODY" | jq -r '.Name // ""' 2>/dev/null || echo "")" ]
}

_jf_health_up() {
    http_request GET "http://${API_HOST}:8096/health"
}

configure_jellyfin() {
    local jellyfin_port=8096
    local max_wait=120

    echo >&2
    if ! wait_until "Waiting for Jellyfin to start" "$max_wait" 3 _jf_is_up; then
        log_step_fail "Jellyfin: not responsive after ${max_wait}s"
        return 1
    fi
    echo >&2

    local public_info wizard_complete=""
    http_request GET "http://${API_HOST}:${jellyfin_port}/System/Info/Public" || true
    public_info="$HTTP_BODY"

    if [ -n "$public_info" ]; then
        wizard_complete=$(printf '%s' "$public_info" | jq -r '.StartupWizardCompleted // ""' 2>/dev/null || echo "")
        if [ "$wizard_complete" = "True" ] || [ "$wizard_complete" = "true" ]; then
            log_step "Jellyfin: startup wizard already completed"
            echo "Configuring Jellyfin libraries" >&2
            local lib_rc=0
            configure_jellyfin_libraries || lib_rc=$?
            echo >&2
            return "$lib_rc"
        fi
    fi

    _cfg_log_info "Jellyfin: attempting startup wizard bypass via API..."
    echo >&2
    if ! wait_until "Waiting for Jellyfin startup user to initialize" 60 3 _jf_first_user_ready; then
        log_step_fail "Jellyfin: startup user not initialized after 60s"
        configure_jellyfin_xml_fallback
        return $?
    fi
    echo >&2

    if http_request POST "http://${API_HOST}:${jellyfin_port}/Startup/Configuration" \
        -H "Content-Type: application/json" \
        -d '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}'; then
        log_step "Jellyfin: set startup locale (en-US)"
    else
        log_step_fail "Jellyfin: failed to set startup locale (HTTP ${HTTP_STATUS})"
    fi

    local user_payload
    user_payload=$(jq -nc --arg n "$AUTH_USERNAME" --arg p "$AUTH_PASSWORD" \
        '{Name:$n,Password:$p,EnableAutoLogin:false}')
    if http_request POST "http://${API_HOST}:${jellyfin_port}/Startup/User" \
        -H "Content-Type: application/json" \
        -d "$user_payload"; then
        log_step "Jellyfin: set admin user credentials ($AUTH_USERNAME)"
    else
        log_step_fail "Jellyfin: failed to set admin user via API (HTTP ${HTTP_STATUS})"
        configure_jellyfin_xml_fallback
        return $?
    fi

    if http_request POST "http://${API_HOST}:${jellyfin_port}/Startup/Complete" \
        -H "Content-Type: application/json"; then
        log_step "Jellyfin: startup wizard completed via API"
    else
        log_step_fail "Jellyfin: failed to complete startup wizard (HTTP ${HTTP_STATUS})"
        configure_jellyfin_xml_fallback
        return $?
    fi

    sleep 3
    http_request GET "http://${API_HOST}:${jellyfin_port}/System/Info/Public" || true
    local wizard_status
    wizard_status=$(printf '%s' "$HTTP_BODY" | jq -r '.StartupWizardCompleted // ""' 2>/dev/null || echo "")

    if [ "$wizard_status" = "True" ] || [ "$wizard_status" = "true" ]; then
        log_step "Jellyfin: startup wizard bypass verified"
    else
        log_step_fail "Jellyfin: wizard completion could not be verified via API"
        configure_jellyfin_xml_fallback
        return $?
    fi

    echo "Configuring Jellyfin libraries" >&2
    local lib_rc=0
    configure_jellyfin_libraries || lib_rc=$?
    echo >&2
    return "$lib_rc"
}

configure_jellyfin_xml_fallback() {
    local system_xml="$INSTALL_DIR/config/jellyfin/system.xml"
    local max_wait=60 wait_time=0

    echo >&2
    while [ $wait_time -lt $max_wait ]; do
        [ -f "$system_xml" ] && break
        wait_inline "Waiting for Jellyfin system.xml" "$wait_time"
        sleep 3
        wait_time=$((wait_time + 3))
    done
    echo >&2

    if [ ! -f "$system_xml" ]; then
        log_step_fail "Jellyfin: system.xml not found after ${max_wait}s"
        return 1
    fi

    if grep -q '<IsStartupWizardCompleted>false</IsStartupWizardCompleted>' "$system_xml" 2>/dev/null; then
        sed -i 's/<IsStartupWizardCompleted>false<\/IsStartupWizardCompleted>/<IsStartupWizardCompleted>true<\/IsStartupWizardCompleted>/g' "$system_xml"
        log_step "Jellyfin: marked startup wizard as complete in system.xml"
    elif grep -q '<IsStartupWizardCompleted>' "$system_xml" 2>/dev/null; then
        sed -i 's/<IsStartupWizardCompleted>[^<]*<\/IsStartupWizardCompleted>/<IsStartupWizardCompleted>true<\/IsStartupWizardCompleted>/g' "$system_xml"
        log_step "Jellyfin: updated IsStartupWizardCompleted in system.xml"
    else
        sed -i 's/<\/ServerConfiguration>/  <IsStartupWizardCompleted>true<\/IsStartupWizardCompleted>\n<\/ServerConfiguration>/' "$system_xml"
        log_step "Jellyfin: added IsStartupWizardCompleted to system.xml"
    fi

    run_docker restart jellyfin 2>/dev/null || true
    log_step "Jellyfin: restarted to apply system.xml changes"

    echo >&2
    wait_until "Waiting for Jellyfin to come back online" 60 3 _jf_health_up || true
    echo >&2
}

configure_jellyfin_libraries() {
    local jellyfin_port=8096
    local auth_payload auth_response access_token user_id

    auth_payload=$(jq -nc --arg u "$AUTH_USERNAME" --arg p "$AUTH_PASSWORD" '{Username:$u,Pw:$p}')
    if ! http_request POST "http://${API_HOST}:${jellyfin_port}/Users/AuthenticateByName" \
        -H "Content-Type: application/json" \
        -H "$(_jf_auth_header)" \
        -d "$auth_payload"; then
        log_step_fail "Jellyfin: failed to authenticate for library setup (HTTP ${HTTP_STATUS})"
        return 1
    fi
    auth_response="$HTTP_BODY"

    access_token=$(printf '%s' "$auth_response" | jq -r '.AccessToken // ""' 2>/dev/null || echo "")
    if [ -z "$access_token" ]; then
        log_step_fail "Jellyfin: failed to get access token"
        return 1
    fi
    user_id=$(printf '%s' "$auth_response" | jq -r '.User.Id // ""' 2>/dev/null || echo "")

    local auth_hdr
    auth_hdr=$(_jf_auth_header "$access_token")

    local -a lib_names=("Movies" "TV Shows")
    local -a lib_types=("movies" "tvshows")
    local -a lib_paths=("/data/media/movies" "/data/media/tv")

    if [ -n "${MEDIA_DIRECTORY:-}" ] && [ -d "${MEDIA_DIRECTORY}/media/music" ]; then
        lib_names+=("Music")
        lib_types+=("music")
        lib_paths+=("/data/media/music")
    fi

    local existing_libs="[]"
    if http_request GET "http://${API_HOST}:${jellyfin_port}/Library/VirtualFolders" -H "$auth_hdr"; then
        existing_libs="$HTTP_BODY"
    fi

    local dupe_ids
    dupe_ids=$(printf '%s' "$existing_libs" | jq -r '.[] | . as $lib | .Locations[]? as $loc | {"/data/media/movies": "Movies", "/data/media/tv": "TV Shows", "/data/media/music": "Music"}[$loc] as $expected | select($expected and $lib.Name != $expected) | "\(.ItemId)|\(.Name)"' 2>/dev/null || echo "")

    if [ -n "$dupe_ids" ]; then
        local dupe_id dupe_name
        while IFS='|' read -r dupe_id dupe_name; do
            [ -n "$dupe_id" ] || continue
            http_request DELETE "http://${API_HOST}:${jellyfin_port}/Items/${dupe_id}" -H "$auth_hdr" || true
            log_step "Jellyfin: removed duplicate library '${dupe_name}'"
        done <<< "$dupe_ids"
        if http_request GET "http://${API_HOST}:${jellyfin_port}/Library/VirtualFolders" -H "$auth_hdr"; then
            existing_libs="$HTTP_BODY"
        fi
    fi

    local critical_errors=0 i
    for i in "${!lib_names[@]}"; do
        local lib_name="${lib_names[$i]}"
        local lib_type="${lib_types[$i]}"
        local lib_path="${lib_paths[$i]}"

        local lib_exists
        lib_exists=$(printf '%s' "$existing_libs" | jq --arg ln "$lib_name" --arg lp "$lib_path" -r 'if [.[] | select(.Name == $ln and (.Locations // [] | index($lp)))][0] then "yes" else "no" end' 2>/dev/null || echo "no")

        if [ "$lib_exists" = "yes" ]; then
            log_step "Jellyfin: ${lib_name} library already exists (${lib_path})"
            continue
        fi

        local enc_name enc_path
        enc_name=$(urlencode "$lib_name")
        enc_path=$(jq -rn --arg p "$lib_path" '($p | @uri) | gsub("%2F"; "/")' 2>/dev/null || echo "${lib_path}")

        if http_request POST \
            "http://${API_HOST}:${jellyfin_port}/Library/VirtualFolders?name=${enc_name}&collectionType=${lib_type}&paths=${enc_path}&refreshProgress=0" \
            -H "Content-Type: application/json" \
            -H "$auth_hdr"; then
            log_step "Jellyfin: added ${lib_name} library (${lib_path})"
        else
            log_step_fail "Jellyfin: failed to add ${lib_name} library (HTTP ${HTTP_STATUS})"
            if [ "$lib_type" = "movies" ] || [ "$lib_type" = "tvshows" ]; then
                critical_errors=$((critical_errors + 1))
            fi
        fi
    done

    # Set subtitle preference: always show subtitles in preferred ISO 639-2/T language.
    if [ -n "$user_id" ]; then
        local sub_lang="${SUBTITLE_LANGUAGE:-en}"
        sub_lang="${sub_lang%%,*}"
        sub_lang=${sub_lang// /}

        local jf_lang
        jf_lang=$(iso639_to_code3 "$sub_lang")

        if http_request GET "http://${API_HOST}:${jellyfin_port}/Users/${user_id}" -H "$auth_hdr" && [ -n "$HTTP_BODY" ]; then
            local patched_cfg
            patched_cfg=$(printf '%s' "$HTTP_BODY" | jq --arg lang "$jf_lang" '.Configuration.SubtitleMode = "Always" | .Configuration.SubtitleLanguagePreference = $lang | .Configuration' 2>/dev/null || echo "")
            if [ -n "$patched_cfg" ] && [ "$patched_cfg" != "null" ]; then
                if http_request POST "http://${API_HOST}:${jellyfin_port}/Users/${user_id}/Configuration" \
                    -H "Content-Type: application/json" \
                    -H "$auth_hdr" \
                    -d "$patched_cfg"; then
                    log_step "Jellyfin: set subtitle preference (Always, ${jf_lang})"
                else
                    log_step_fail "Jellyfin: failed to set subtitle preference (HTTP ${HTTP_STATUS})"
                fi
            fi
        fi
    fi

    # Reuse existing "assemblrr" API key if present; otherwise create one.
    local jf_api_key=""
    if http_request GET "http://${API_HOST}:${jellyfin_port}/Auth/Keys" -H "$auth_hdr"; then
        jf_api_key=$(printf '%s' "$HTTP_BODY" | jq -r '.Items[]? | select(.AppName == "assemblrr") | .AccessToken // ""' 2>/dev/null | head -1 || echo "")
    fi

    if [ -z "$jf_api_key" ]; then
        if http_request POST "http://${API_HOST}:${jellyfin_port}/Auth/Keys?app=assemblrr" -H "$auth_hdr"; then
            if http_request GET "http://${API_HOST}:${jellyfin_port}/Auth/Keys" -H "$auth_hdr"; then
                jf_api_key=$(printf '%s' "$HTTP_BODY" | jq -r '.Items[]? | select(.AppName == "assemblrr") | .AccessToken // ""' 2>/dev/null | head -1 || echo "")
            fi
        else
            log_step_fail "Jellyfin: failed to create API key (HTTP ${HTTP_STATUS})"
        fi
    fi

    if [ -n "$jf_api_key" ]; then
        write_secret_file "$INSTALL_DIR/secrets/jellyfin_api_key.txt" "$jf_api_key"
        log_step "Jellyfin: API key ready for Radarr/Sonarr connections"
    else
        log_step_fail "Jellyfin: API key missing after creation"
    fi

    if [ "${GPU_TRANSCODING:-none}" != "none" ]; then
        configure_jellyfin_transcoding "$access_token" "$jellyfin_port" || true
    fi

    [ "$critical_errors" -eq 0 ]
}

# Parse `vainfo --display drm` output into hardware decode/encode capabilities JSON.
# Outputs compact JSON {"decode":[...],"hevc10":bool,"vp9_10":bool,"hevc_enc":bool,"av1_enc":bool}; returns 1 if none found.
jellyfin_parse_vainfo_caps() {
    local vainfo_text="${1:-}"
    [ -n "$vainfo_text" ] || return 1

    local parsed
    parsed=$(printf '%s\n' "$vainfo_text" | awk -F: '
        function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
        NF >= 2 {
            p = trim($1); e = trim($2)
            if (e == "VAEntrypointVLD") {
                if (p ~ /^VAProfileH264/) dec["h264"] = 1
                else if (p == "VAProfileHEVCMain") dec["hevc"] = 1
                else if (p ~ /^VAProfileMPEG2/) dec["mpeg2video"] = 1
                else if (p ~ /^VAProfileVC1/) dec["vc1"] = 1
                else if (p ~ /^VAProfileVP8/) dec["vp8"] = 1
                else if (p == "VAProfileVP9Profile0") dec["vp9"] = 1
                else if (p == "VAProfileAV1Profile0") dec["av1"] = 1
                else if (p == "VAProfileHEVCMain10") { hevc10 = 1; dec["hevc"] = 1 }
                else if (p == "VAProfileVP9Profile2") { vp9_10 = 1; dec["vp9"] = 1 }
            } else if (e ~ /^VAEntrypointEnc/) {
                if (p == "VAProfileHEVCMain" || p == "VAProfileHEVCMain10") hevc_enc = 1
                else if (p == "VAProfileAV1Profile0") av1_enc = 1
            }
        }
        END {
            order[1]="h264"; order[2]="hevc"; order[3]="mpeg2video"; order[4]="vc1"; order[5]="vp8"; order[6]="vp9"; order[7]="av1"
            out = ""
            count = 0
            for (i = 1; i <= 7; i++) {
                c = order[i]
                if (dec[c]) {
                    if (out != "") out = out ","
                    out = out "\"" c "\""
                    count++
                }
            }
            if (count == 0) exit 1
            printf "{\"decode\":[%s],\"hevc10\":%s,\"vp9_10\":%s,\"hevc_enc\":%s,\"av1_enc\":%s}\n",
                out, (hevc10 ? "true" : "false"), (vp9_10 ? "true" : "false"),
                (hevc_enc ? "true" : "false"), (av1_enc ? "true" : "false")
        }
    ' 2>/dev/null || echo "")

    [ -n "$parsed" ] || return 1
    printf '%s\n' "$parsed"
}

# Build an updated /System/Configuration/encoding JSON payload for hardware transcoding.
# Mode: amd | vaapi | intel | qsv | nvidia | nvenc | none; optional caps_json overrides codecs.
jellyfin_build_encoding_patch_json() {
    local current_json="${1:-"{}"}"
    local gpu_mode="${2:-none}"
    local render_dev="${3:-/dev/dri/renderD128}"
    local caps_json="${4:-}"
    gpu_mode="${gpu_mode,,}"

    [ -n "$current_json" ] || current_json="{}"

    local use_caps=0
    if [ -n "$caps_json" ] && printf '%s' "$caps_json" | jq -e '(.decode // []) | length > 0' >/dev/null 2>&1; then
        use_caps=1
    fi

    case "$gpu_mode" in
        amd|vaapi)
            if [ "$use_caps" -eq 1 ]; then
                printf '%s' "$current_json" | jq -c --arg dev "$render_dev" --argjson caps "$caps_json" '
                    .HardwareAccelerationType = "vaapi" |
                    .VaapiDevice = $dev |
                    .EnableHardwareEncoding = true |
                    .HardwareDecodingCodecs = $caps.decode |
                    .EnableDecodingColorDepth10Hevc = $caps.hevc10 |
                    .EnableDecodingColorDepth10Vp9 = $caps.vp9_10 |
                    .AllowHevcEncoding = $caps.hevc_enc |
                    .AllowAv1Encoding = $caps.av1_enc
                '
            else
                printf '%s' "$current_json" | jq -c --arg dev "$render_dev" '
                    .HardwareAccelerationType = "vaapi" |
                    .VaapiDevice = $dev |
                    .EnableHardwareEncoding = true |
                    .HardwareDecodingCodecs = ["h264", "hevc", "vp9", "av1"] |
                    .EnableDecodingColorDepth10Hevc = true |
                    .EnableDecodingColorDepth10Vp9 = true |
                    .AllowHevcEncoding = true |
                    .AllowAv1Encoding = false
                '
            fi
            ;;
        intel|qsv)
            if [ "$use_caps" -eq 1 ]; then
                printf '%s' "$current_json" | jq -c --arg dev "$render_dev" --argjson caps "$caps_json" '
                    .HardwareAccelerationType = "qsv" |
                    .QsvDevice = $dev |
                    .VaapiDevice = $dev |
                    .EnableHardwareEncoding = true |
                    .HardwareDecodingCodecs = $caps.decode |
                    .EnableDecodingColorDepth10Hevc = $caps.hevc10 |
                    .EnableDecodingColorDepth10Vp9 = $caps.vp9_10 |
                    .AllowHevcEncoding = $caps.hevc_enc |
                    .AllowAv1Encoding = $caps.av1_enc
                '
            else
                printf '%s' "$current_json" | jq -c --arg dev "$render_dev" '
                    .HardwareAccelerationType = "qsv" |
                    .QsvDevice = $dev |
                    .VaapiDevice = $dev |
                    .EnableHardwareEncoding = true |
                    .HardwareDecodingCodecs = ["h264", "hevc", "vp9", "av1"] |
                    .EnableDecodingColorDepth10Hevc = true |
                    .EnableDecodingColorDepth10Vp9 = true |
                    .AllowHevcEncoding = true |
                    .AllowAv1Encoding = false
                '
            fi
            ;;
        nvidia|nvenc)
            printf '%s' "$current_json" | jq -c '
                .HardwareAccelerationType = "nvenc" |
                .EnableHardwareEncoding = true |
                .HardwareDecodingCodecs = ["h264", "hevc", "vp9", "av1"] |
                .EnableDecodingColorDepth10Hevc = true |
                .EnableDecodingColorDepth10Vp9 = true |
                .AllowHevcEncoding = true
            '
            ;;
        *)
            printf '%s' "$current_json" | jq -c '
                .HardwareAccelerationType = "none" |
                .EnableHardwareEncoding = false
            '
            ;;
    esac
}

# Configure Jellyfin hardware transcoding via /System/Configuration/encoding.
configure_jellyfin_transcoding() {
    local token="${1:-}"
    local jellyfin_port="${2:-8096}"
    local gpu_mode="${GPU_TRANSCODING:-none}"
    gpu_mode="${gpu_mode,,}"

    if [ -z "$token" ] && [ -s "${INSTALL_DIR:-}/secrets/jellyfin_api_key.txt" ]; then
        token=$(cat "$INSTALL_DIR/secrets/jellyfin_api_key.txt" 2>/dev/null || echo "")
    fi
    if [ -z "$token" ]; then
        log_step_fail "Jellyfin: missing API token for hardware transcoding configuration"
        return 1
    fi

    local render_dev="/dev/dri/renderD128"
    if [ ! -c "$render_dev" ]; then
        local cand
        for cand in /dev/dri/renderD*; do
            if [ -c "$cand" ]; then
                render_dev="$cand"
                break
            fi
        done
    fi

    local caps_json="" vainfo_out=""
    case "$gpu_mode" in
        amd|vaapi|intel|qsv)
            if command -v docker >/dev/null 2>&1 || declare -F run_docker >/dev/null 2>&1; then
                vainfo_out=$(run_docker exec jellyfin /usr/lib/jellyfin-ffmpeg/vainfo --display drm --device "$render_dev" 2>/dev/null || true)
                caps_json=$(jellyfin_parse_vainfo_caps "$vainfo_out" 2>/dev/null || true)
            fi
            ;;
    esac

    local auth_hdr
    auth_hdr=$(_jf_auth_header "$token")
    if ! http_request GET "http://${API_HOST}:${jellyfin_port}/System/Configuration/encoding" -H "$auth_hdr" || [ -z "$HTTP_BODY" ]; then
        log_step_fail "Jellyfin: failed to read encoding configuration (HTTP ${HTTP_STATUS})"
        return 1
    fi

    local patched_cfg
    patched_cfg=$(jellyfin_build_encoding_patch_json "$HTTP_BODY" "$gpu_mode" "$render_dev" "$caps_json" 2>/dev/null || echo "")
    if [ -z "$patched_cfg" ] || [ "$patched_cfg" = "null" ]; then
        log_step_fail "Jellyfin: failed to build encoding configuration payload"
        return 1
    fi

    local caps_summary=""
    if [ -n "$caps_json" ]; then
        local dec_csv enc_csv=""
        dec_csv=$(printf '%s' "$caps_json" | jq -r '.decode | join(",")' 2>/dev/null || echo "")
        [ "$(printf '%s' "$caps_json" | jq -r '.hevc_enc' 2>/dev/null)" = "true" ] && enc_csv="hevc"
        [ "$(printf '%s' "$caps_json" | jq -r '.av1_enc' 2>/dev/null)" = "true" ] && enc_csv="${enc_csv:+${enc_csv},}av1"
        caps_summary="; decode: ${dec_csv:-default}"
        [ -n "$enc_csv" ] && caps_summary+="; enc: ${enc_csv}"
    fi

    if http_request POST "http://${API_HOST}:${jellyfin_port}/System/Configuration/encoding" \
        -H "Content-Type: application/json" \
        -H "$auth_hdr" \
        -d "$patched_cfg"; then
        case "$gpu_mode" in
            amd|vaapi) log_step "Jellyfin: hardware transcoding configured (AMD VAAPI via ${render_dev}${caps_summary})" ;;
            intel|qsv) log_step "Jellyfin: hardware transcoding configured (Intel QSV via ${render_dev}${caps_summary})" ;;
            nvidia|nvenc) log_step "Jellyfin: hardware transcoding configured (NVIDIA NVENC)" ;;
            *) log_step "Jellyfin: hardware transcoding disabled (CPU software)" ;;
        esac
        return 0
    fi

    log_step_fail "Jellyfin: failed to apply hardware transcoding (HTTP ${HTTP_STATUS})"
    return 1
}

jellyfin_change_credentials() {
    local old_user="$1"
    local old_pass="$2"
    local new_user="$3"
    local new_pass="$4"
    local jellyfin_port="${5:-8096}"
    local label="${6:-Jellyfin}"

    if [ -z "$new_user" ] || [ -z "$new_pass" ]; then
        log_step_fail "${label}: new credentials missing"
        return 1
    fi

    local wizard_complete=""
    if http_request GET "http://${API_HOST}:${jellyfin_port}/System/Info/Public"; then
        wizard_complete=$(printf '%s' "$HTTP_BODY" | jq -r '.StartupWizardCompleted // ""' 2>/dev/null || echo "")
    fi
    if [ "$wizard_complete" != "True" ] && [ "$wizard_complete" != "true" ]; then
        if [ "$label" = "Jellyfin" ] && type configure_jellyfin >/dev/null 2>&1; then
            configure_jellyfin
            return $?
        fi
        log_step_fail "${label}: startup wizard is still open — finish first boot, then retry"
        return 1
    fi

    local auth_hdr_anon auth_payload auth_response=""
    auth_hdr_anon=$(_jf_auth_header)
    auth_payload=$(jq -nc --arg u "$old_user" --arg p "$old_pass" '{Username:$u,Pw:$p}')
    if http_request POST "http://${API_HOST}:${jellyfin_port}/Users/AuthenticateByName" \
        -H "Content-Type: application/json" -H "$auth_hdr_anon" -d "$auth_payload"; then
        auth_response="$HTTP_BODY"
    else
        auth_payload=$(jq -nc --arg u "$new_user" --arg p "$new_pass" '{Username:$u,Pw:$p}')
        if http_request POST "http://${API_HOST}:${jellyfin_port}/Users/AuthenticateByName" \
            -H "Content-Type: application/json" -H "$auth_hdr_anon" -d "$auth_payload"; then
            auth_response="$HTTP_BODY"
            local already_name
            already_name=$(printf '%s' "$auth_response" | jq -r '.User.Name // ""' 2>/dev/null || echo "")
            if [ "$already_name" = "$new_user" ]; then
                log_step "${label}: already using the new password"
                return 0
            fi
            old_pass="$new_pass"
        else
            log_step_fail "${label}: could not log in with the old password"
            return 1
        fi
    fi

    local access_token user_id
    access_token=$(printf '%s' "$auth_response" | jq -r '.AccessToken // ""' 2>/dev/null || echo "")
    user_id=$(printf '%s' "$auth_response" | jq -r '.User.Id // ""' 2>/dev/null || echo "")
    if [ -z "$access_token" ] || [ -z "$user_id" ]; then
        log_step_fail "${label}: login response missing token"
        return 1
    fi

    local auth_hdr
    auth_hdr=$(_jf_auth_header "$access_token")

    if [ "$old_pass" != "$new_pass" ]; then
        local pw_payload
        pw_payload=$(jq -nc --arg cur "$old_pass" --arg new "$new_pass" '{CurrentPw:$cur,NewPw:$new}')
        if ! http_request POST "http://${API_HOST}:${jellyfin_port}/Users/${user_id}/Password" \
            -H "Content-Type: application/json" -H "$auth_hdr" -d "$pw_payload"; then
            log_step_fail "${label}: failed to set password (HTTP ${HTTP_STATUS})"
            return 1
        fi
    fi

    if [ "$old_user" != "$new_user" ]; then
        local enc_name name_ok=0
        enc_name=$(urlencode "$new_user")
        if http_request POST "http://${API_HOST}:${jellyfin_port}/Users/${user_id}/Name?name=${enc_name}" -H "$auth_hdr"; then
            name_ok=1
        elif http_request GET "http://${API_HOST}:${jellyfin_port}/Users/${user_id}" -H "$auth_hdr" && [ -n "$HTTP_BODY" ]; then
            local patched
            patched=$(printf '%s' "$HTTP_BODY" | jq --arg n "$new_user" '.Name = $n' 2>/dev/null || echo "")
            if [ -n "$patched" ] && http_request POST "http://${API_HOST}:${jellyfin_port}/Users/${user_id}" \
                -H "Content-Type: application/json" -H "$auth_hdr" -d "$patched"; then
                name_ok=1
            fi
        fi
        if [ "$name_ok" -ne 1 ]; then
            log_step_fail "${label}: password updated, username change failed (HTTP ${HTTP_STATUS})"
            return 1
        fi
    fi

    log_step "${label}: set login (${new_user})"
    return 0
}

configure_jellyfin_notifications() {
    local jf_api_key
    jf_api_key=$(cat "$INSTALL_DIR/secrets/jellyfin_api_key.txt" 2>/dev/null || echo "")

    if [ -z "$jf_api_key" ]; then
        log_step_fail "Jellyfin notifications: API key not found — skipping"
        return 1
    fi

    local errors=0
    if ! add_jellyfin_refresh_notif "Radarr" "7878" "$RADARR_API_KEY"; then
        errors=$((errors + 1))
    fi
    if ! add_jellyfin_refresh_notif "Sonarr" "8989" "$SONARR_API_KEY"; then
        errors=$((errors + 1))
    fi
    [ "$errors" -eq 0 ]
}

add_jellyfin_refresh_notif() {
    local app_name="$1"
    local port="$2"
    local apikey="$3"

    [ -z "$apikey" ] && return 0

    local notifications existing_id schema payload result
    notifications=$(api_get "$port" "/api/v3/notification" "$apikey" || echo "[]")
    existing_id=$(printf '%s' "$notifications" | jq -r '.[] | select(.implementation == "CustomScript" and .name == "Jellyfin Refresh") | .id // ""' 2>/dev/null | head -1 || echo "")

    schema=$(api_get "$port" "/api/v3/notification/schema" "$apikey" || echo "[]")
    payload=$(printf '%s' "$schema" | jq '
        [.[] | select(.implementation == "CustomScript")][0] |
        .fields = [.fields[] | if .name == "path" then .value = "/scripts/jellyfin-refresh.sh" else . end] |
        .onUpgrade = true | .name = "Jellyfin Refresh" | .tags = [] |
        if has("onImportComplete") then
            .onDownload = false | .onImportComplete = true
        else
            .onDownload = true
        end
    ' 2>/dev/null || echo "")

    if [ -z "$payload" ]; then
        log_step_fail "${app_name}: CustomScript notification schema not found"
        return 1
    fi

    if [ -f "$INSTALL_DIR/scripts/jellyfin-refresh.sh" ]; then
        chmod +x "$INSTALL_DIR/scripts/jellyfin-refresh.sh" 2>/dev/null || true
    fi

    if [ -n "$existing_id" ]; then
        payload=$(printf '%s' "$payload" | jq --argjson id "$existing_id" '.id = $id' 2>/dev/null || echo "$payload")
        result=$(api_put "$port" "/api/v3/notification/${existing_id}" "$apikey" "$payload" || echo "")
        if jq_json_has_key "$result" "id"; then
            log_step "${app_name}: updated Jellyfin Refresh script (scan on import complete)"
            return 0
        fi
    fi

    result=$(api_post_force "$port" "/api/v3/notification" "$apikey" "$payload" || echo "")
    if jq_json_has_key "$result" "id"; then
        log_step "${app_name}: added Jellyfin Refresh script (scan on import complete)"
        return 0
    fi
    local err_msg
    err_msg=$(printf '%s' "$result" | jq -r 'if type == "array" then .[0].errorMessage // empty else .errorMessage // empty end' 2>/dev/null || echo "")
    if [ -n "$err_msg" ]; then
        log_step_fail "${app_name}: failed to add Jellyfin Refresh script (${err_msg})"
    else
        log_step_fail "${app_name}: failed to add Jellyfin Refresh script"
    fi
    return 1
}
