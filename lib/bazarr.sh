#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# assemblrr Bazarr configuration — sourced by config.sh / config_edit.sh
# Requires: lib/core.sh, lib/api.sh, lib/languages.sh

if [ -n "${_ASSEMBLRR_BAZARR_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_BAZARR_SOURCED=1

_bazarr_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/languages.sh
[ -f "$_bazarr_dir/languages.sh" ] && source "$_bazarr_dir/languages.sh"

BAZARR_PORT=6767

_bazarr_config_file() {
    local candidates=(
        "$INSTALL_DIR/config/bazarr/config/config.yaml"
        "$INSTALL_DIR/config/bazarr/config/config.ini"
        "$INSTALL_DIR/config/bazarr/config.yaml"
        "$INSTALL_DIR/config/bazarr/config.ini"
    )
    local f
    for f in "${candidates[@]}"; do
        if [ -f "$f" ]; then
            echo "$f"
            return 0
        fi
    done
    return 1
}

_bazarr_extract_apikey() {
    local cfg="$1"
    local key=""
    case "$cfg" in
        *.yaml|*.yml)
            if command -v yq >/dev/null 2>&1; then
                key=$(yq -r '.auth.apikey // empty' "$cfg" 2>/dev/null || true)
            fi
            if [ -z "$key" ]; then
                key=$(awk '
                    /^auth:[[:space:]]*$/ { in_auth=1; next }
                    in_auth && /^[^[:space:]]/ { in_auth=0 }
                    in_auth && /^[[:space:]]+apikey:[[:space:]]*/ {
                        sub(/^[[:space:]]+apikey:[[:space:]]*/, "")
                        gsub(/["\047]/, "")
                        print
                        exit
                    }
                ' "$cfg" 2>/dev/null | head -1 | tr -d '\r')
            fi
            ;;
        *.ini)
            key=$(sed -n 's/^[[:space:]]*apikey[[:space:]]*=[[:space:]]*//p' "$cfg" 2>/dev/null | head -1 | tr -d '\r')
            ;;
    esac
    echo "$key"
}

read_bazarr_api_key() {
    local max_wait=180 wait_time=0 cfg key

    while [ $wait_time -lt $max_wait ]; do
        if cfg=$(_bazarr_config_file 2>/dev/null); then
            key=$(_bazarr_extract_apikey "$cfg")
            if [ -n "$key" ] && [ "$key" != "null" ]; then
                [ "$wait_time" -gt 0 ] && echo >&2
                echo "$key"
                return 0
            fi
        fi
        wait_inline "Waiting for Bazarr to initialize" "$wait_time"
        sleep 3
        wait_time=$((wait_time + 3))
    done
    echo >&2
    log_step_fail "Bazarr: config.yaml/ini ApiKey missing after ${max_wait}s"
    return 1
}

_bazarr_api_ready() {
    local apikey="$1"
    http_request GET "http://${API_HOST}:${BAZARR_PORT}/api/system/status" -H "X-API-KEY: ${apikey}"
}

wait_for_bazarr() {
    local apikey="$1"
    local max_wait="${API_READY_TIMEOUT_SECONDS:-120}"
    if wait_until "Waiting for Bazarr API" "$max_wait" 3 _bazarr_api_ready "$apikey"; then
        return 0
    fi
    log_step_fail "Bazarr: API not ready after ${max_wait}s"
    return 1
}

# POST multipart settings safely using --form-string (no @/< file-upload injection).
_bazarr_post_form() {
    local apikey="$1"
    shift
    http_request POST "http://${API_HOST}:${BAZARR_PORT}/api/system/settings" \
        -H "X-API-KEY: ${apikey}" "$@" || true
    printf '%s' "$HTTP_STATUS"
}

_bazarr_lang_code2() {
    iso639_to_code2 "${1:-en}"
}

_bazarr_code2_list() {
    local -a out=()
    local c mapped x seen
    for c in "$@"; do
        mapped=$(_bazarr_lang_code2 "$c")
        [ -z "$mapped" ] && continue
        seen=0
        for x in "${out[@]+"${out[@]}"}"; do
            [ "$x" = "$mapped" ] && seen=1 && break
        done
        [ "$seen" -eq 0 ] && out+=("$mapped")
    done
    if [ ${#out[@]} -eq 0 ]; then
        out=(en)
    fi
    printf '%s\n' "${out[@]}"
}

# TRaSH 90/80 assumes hash-rich English catalogs. Non-English OpenSubtitles.com
# hits score lower (~55-74); drop min scores to 70/50 when non-English languages exist.
_bazarr_min_scores() {
    local series=90 movie=80 c mapped
    for c in "$@"; do
        mapped=$(_bazarr_lang_code2 "$c")
        if [ "$mapped" != "en" ]; then
            series=70
            movie=50
            break
        fi
    done
    echo "$series $movie"
}

_bazarr_languages_profile_json() {
    local langs_json
    langs_json=$(_bazarr_code2_list "$@" | jq -R . | jq -sc .)
    jq -nc --argjson langs "$langs_json" '[
      {
        profileId: 1,
        name: "Default",
        cutoff: null,
        items: ($langs | to_entries | map({
          id: (.key + 1),
          language: .value,
          audio_exclude: "False",
          audio_only_include: "False",
          hi: "False",
          forced: "False"
        })),
        mustContain: [],
        mustNotContain: [],
        originalFormat: false,
        tag: null
      }
    ]'
}

# Fetch Jellyfin movie/TV library names + ids using standard Jellyfin 12 auth header.
_bazarr_jellyfin_libraries() {
    local jf_key="$1"
    local folders="[]"
    if http_request GET "http://${API_HOST}:8096/Library/VirtualFolders" \
        -H "Authorization: MediaBrowser Client=\"assemblrr\", Device=\"assemblrr\", DeviceId=\"assemblrr-cli\", Version=\"1.0\", Token=\"${jf_key}\""; then
        folders="$HTTP_BODY"
    fi

    BAZARR_JF_MOVIE_NAMES=()
    BAZARR_JF_MOVIE_IDS=()
    BAZARR_JF_SERIES_NAMES=()
    BAZARR_JF_SERIES_IDS=()

    local name id ctype
    while IFS=$'\t' read -r name id ctype; do
        [ -z "$name" ] && continue
        case "$ctype" in
            movies)
                BAZARR_JF_MOVIE_NAMES+=("$name")
                BAZARR_JF_MOVIE_IDS+=("$id")
                ;;
            tvshows)
                BAZARR_JF_SERIES_NAMES+=("$name")
                BAZARR_JF_SERIES_IDS+=("$id")
                ;;
        esac
    done < <(printf '%s' "$folders" | jq -r '.[] | select(.CollectionType=="movies" or .CollectionType=="tvshows") | "\(.Name)\t\(.ItemId // .Guid // "")\t\(.CollectionType)"' 2>/dev/null || true)
}

configure_bazarr() {
    local bazarr_key="" os_user="" os_pass=""
    local form_args=() http_code
    local providers=()
    local profiles_json
    local has_sonarr=0 has_radarr=0
    local jf_key="" jellyfin_refresh=0

    if ! bazarr_key=$(read_bazarr_api_key); then
        return 1
    fi
    if ! wait_for_bazarr "$bazarr_key"; then
        return 1
    fi

    local -a stored_langs=() lang_code2s=()
    while IFS= read -r lang_code2; do
        [ -n "$lang_code2" ] && stored_langs+=("$lang_code2")
    done < <(_subtitle_stored_lang_codes)
    if [ ${#stored_langs[@]} -eq 0 ]; then
        stored_langs=("${SUBTITLE_LANGUAGE:-en}")
    fi
    while IFS= read -r lang_code2; do
        [ -n "$lang_code2" ] && lang_code2s+=("$lang_code2")
    done < <(_bazarr_code2_list "${stored_langs[@]}")

    [ -n "${SONARR_API_KEY:-}" ] && has_sonarr=1
    [ -n "${RADARR_API_KEY:-}" ] && has_radarr=1

    if [ "$has_sonarr" -eq 0 ] && [ "$has_radarr" -eq 0 ]; then
        log_step_fail "Bazarr: neither Sonarr nor Radarr API keys available — skipping"
        return 1
    fi

    if [ -s "$INSTALL_DIR/secrets/opensubtitles_username.txt" ] && [ -s "$INSTALL_DIR/secrets/opensubtitles_password.txt" ]; then
        os_user=$(cat "$INSTALL_DIR/secrets/opensubtitles_username.txt" 2>/dev/null || echo "")
        os_pass=$(cat "$INSTALL_DIR/secrets/opensubtitles_password.txt" 2>/dev/null || echo "")
    fi

    providers=()
    if [ "${FZF_SELECT_STATUS:-}" = "confirmed" ]; then
        if [ "${#SELECTED_SUBTITLE_PROVIDERS[@]}" -gt 0 ]; then
            providers=("${SELECTED_SUBTITLE_PROVIDERS[@]}")
        fi
    else
        if [ -n "${SELECTED_SUBTITLE_PROVIDERS+x}" ] && [ "${#SELECTED_SUBTITLE_PROVIDERS[@]}" -gt 0 ]; then
            providers=("${SELECTED_SUBTITLE_PROVIDERS[@]}")
        fi
        if [ -n "$os_user" ] && [ -n "$os_pass" ]; then
            local has_os=0 p
            for p in "${providers[@]+"${providers[@]}"}"; do
                [ "$p" = "opensubtitlescom" ] && has_os=1 && break
            done
            [ "$has_os" -eq 0 ] && providers+=(opensubtitlescom)
        fi
        if [ "${#providers[@]}" -eq 0 ]; then
            local current_p=""
            if http_request GET "http://${API_HOST}:${BAZARR_PORT}/api/system/settings" -H "X-API-KEY: ${bazarr_key}"; then
                current_p=$(printf '%s' "$HTTP_BODY" | jq -r '.general.enabled_providers[]? // empty' 2>/dev/null || true)
            fi
            if [ -n "$current_p" ]; then
                while IFS= read -r p; do
                    [ -n "$p" ] && providers+=("$p")
                done <<< "$current_p"
                log_step "Bazarr: keeping existing providers ($(IFS=,; echo "${providers[*]}"))"
            else
                log_step "Bazarr: no subtitle providers selected (configure later in Bazarr UI)"
            fi
        fi
    fi

    local min_series=90 min_movie=80
    read -r min_series min_movie < <(_bazarr_min_scores "${stored_langs[@]}")

    form_args=(
        --form-string "settings-general-use_sonarr=$([ "$has_sonarr" -eq 1 ] && echo true || echo false)"
        --form-string "settings-general-use_radarr=$([ "$has_radarr" -eq 1 ] && echo true || echo false)"
        --form-string "settings-general-minimum_score=${min_series}"
        --form-string "settings-general-minimum_score_movie=${min_movie}"
        --form-string "settings-general-subfolder=current"
        --form-string "settings-general-upgrade_subs=true"
        --form-string "settings-general-days_to_upgrade_subs=7"
        --form-string "settings-general-use_embedded_subs=true"
        --form-string "settings-general-serie_default_enabled=true"
        --form-string "settings-general-serie_default_profile=1"
        --form-string "settings-general-movie_default_enabled=true"
        --form-string "settings-general-movie_default_profile=1"
        --form-string "settings-subsync-use_subsync=true"
        --form-string "settings-subsync-use_subsync_threshold=true"
        --form-string "settings-subsync-subsync_threshold=96"
        --form-string "settings-subsync-use_subsync_movie_threshold=true"
        --form-string "settings-subsync-subsync_movie_threshold=86"
    )

    local p
    for p in "${providers[@]+"${providers[@]}"}"; do
        form_args+=(--form-string "settings-general-enabled_providers=${p}")
    done

    if [ "$has_sonarr" -eq 1 ]; then
        form_args+=(
            --form-string "settings-sonarr-ip=sonarr"
            --form-string "settings-sonarr-port=8989"
            --form-string "settings-sonarr-base_url=/"
            --form-string "settings-sonarr-ssl=false"
            --form-string "settings-sonarr-apikey=${SONARR_API_KEY}"
            --form-string "settings-sonarr-only_monitored=true"
        )
    fi

    if [ "$has_radarr" -eq 1 ]; then
        form_args+=(
            --form-string "settings-radarr-ip=radarr"
            --form-string "settings-radarr-port=7878"
            --form-string "settings-radarr-base_url=/"
            --form-string "settings-radarr-ssl=false"
            --form-string "settings-radarr-apikey=${RADARR_API_KEY}"
            --form-string "settings-radarr-only_monitored=true"
        )
    fi

    if [ -n "$os_user" ] && [ -n "$os_pass" ]; then
        form_args+=(
            --form-string "settings-opensubtitlescom-username=${os_user}"
            --form-string "settings-opensubtitlescom-password=${os_pass}"
            --form-string "settings-opensubtitlescom-use_hash=true"
            --form-string "settings-opensubtitlescom-include_ai_translated=false"
            --form-string "settings-opensubtitlescom-include_machine_translated=false"
        )
    fi

    local auth_type=""
    if http_request GET "http://${API_HOST}:${BAZARR_PORT}/api/system/settings" -H "X-API-KEY: ${bazarr_key}"; then
        auth_type=$(printf '%s' "$HTTP_BODY" | jq -r '.auth.type // empty' 2>/dev/null || true)
    fi
    if { [ -z "$auth_type" ] || [ "$auth_type" = "null" ] || [ "$auth_type" = "None" ]; } \
        && [ -n "${AUTH_USERNAME:-}" ] && [ -n "${AUTH_PASSWORD:-}" ]; then
        form_args+=(
            --form-string "settings-auth-type=form"
            --form-string "settings-auth-username=${AUTH_USERNAME}"
            --form-string "settings-auth-password=${AUTH_PASSWORD}"
        )
    fi

    if [ "${MEDIA_SERVICE:-jellyfin}" = "jellyfin" ]; then
        jf_key=$(cat "$INSTALL_DIR/secrets/jellyfin_api_key.txt" 2>/dev/null || echo "")
        if [ -n "$jf_key" ]; then
            _bazarr_jellyfin_libraries "$jf_key"
            form_args+=(
                --form-string "settings-general-use_jellyfin=true"
                --form-string "settings-jellyfin-url=http://jellyfin:8096"
                --form-string "settings-jellyfin-apikey=${jf_key}"
                --form-string "settings-jellyfin-update_movie_library=true"
                --form-string "settings-jellyfin-update_series_library=true"
                --form-string "settings-jellyfin-refresh_method=immediate"
            )
            local n
            for n in "${BAZARR_JF_MOVIE_NAMES[@]+"${BAZARR_JF_MOVIE_NAMES[@]}"}"; do
                [ -n "$n" ] && form_args+=(--form-string "settings-jellyfin-movie_library=${n}")
            done
            for n in "${BAZARR_JF_MOVIE_IDS[@]+"${BAZARR_JF_MOVIE_IDS[@]}"}"; do
                [ -n "$n" ] && form_args+=(--form-string "settings-jellyfin-movie_library_ids=${n}")
            done
            for n in "${BAZARR_JF_SERIES_NAMES[@]+"${BAZARR_JF_SERIES_NAMES[@]}"}"; do
                [ -n "$n" ] && form_args+=(--form-string "settings-jellyfin-series_library=${n}")
            done
            for n in "${BAZARR_JF_SERIES_IDS[@]+"${BAZARR_JF_SERIES_IDS[@]}"}"; do
                [ -n "$n" ] && form_args+=(--form-string "settings-jellyfin-series_library_ids=${n}")
            done
            jellyfin_refresh=1
        else
            _cfg_log_info "Bazarr: Jellyfin API key not found — skipping JF refresh integration"
        fi
    fi

    profiles_json=$(_bazarr_languages_profile_json "${stored_langs[@]}")
    local enabled
    for enabled in "${lang_code2s[@]}"; do
        form_args+=(--form-string "languages-enabled=${enabled}")
    done
    if [ "${#lang_code2s[@]}" -gt 1 ]; then
        form_args+=(--form-string "settings-general-single_language=false")
    fi
    form_args+=(--form-string "languages-profiles=${profiles_json}")

    http_code=$(_bazarr_post_form "$bazarr_key" "${form_args[@]}")
    if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
        local provider_list
        provider_list=$(IFS=,; echo "${providers[*]}")
        log_step "Bazarr: configured (lang=$(IFS=,; echo "${lang_code2s[*]}"), score S/M=${min_series}/${min_movie}, sync=on, providers=${provider_list})"
        if [ -n "$os_user" ]; then
            log_step "Bazarr: OpenSubtitles.com credentials applied"
        fi
        if [ "$jellyfin_refresh" -eq 1 ]; then
            log_step "Bazarr: Jellyfin refresh enabled"
        fi
    else
        local body="${HTTP_BODY:0:200}"
        log_step_fail "Bazarr: settings POST failed (HTTP ${http_code}${body:+: $body})"
        return 1
    fi

    write_secret_file "$INSTALL_DIR/secrets/bazarr_api_key.txt" "$bazarr_key"

    if [ "$has_sonarr" -eq 1 ]; then
        http_request POST "http://${API_HOST}:${BAZARR_PORT}/api/system/tasks" -H "X-API-KEY: ${bazarr_key}" \
            --form-string "taskid=update_series" || true
        http_request POST "http://${API_HOST}:${BAZARR_PORT}/api/system/tasks" -H "X-API-KEY: ${bazarr_key}" \
            --form-string "taskid=wanted_search_missing_subtitles_series" || true
    fi
    if [ "$has_radarr" -eq 1 ]; then
        http_request POST "http://${API_HOST}:${BAZARR_PORT}/api/system/tasks" -H "X-API-KEY: ${bazarr_key}" \
            --form-string "taskid=update_movies" || true
        http_request POST "http://${API_HOST}:${BAZARR_PORT}/api/system/tasks" -H "X-API-KEY: ${bazarr_key}" \
            --form-string "taskid=wanted_search_missing_subtitles_movies" || true
    fi

    return 0
}

trigger_bazarr_library_sync() {
    local cfg="" bazarr_key=""
    if cfg=$(_bazarr_config_file 2>/dev/null); then
        bazarr_key=$(_bazarr_extract_apikey "$cfg")
    fi
    if [ -z "$bazarr_key" ] && [ -f "$INSTALL_DIR/secrets/bazarr_api_key.txt" ]; then
        bazarr_key=$(cat "$INSTALL_DIR/secrets/bazarr_api_key.txt" 2>/dev/null || echo "")
    fi
    [ -n "$bazarr_key" ] || return 0

    http_request POST "http://${API_HOST}:${BAZARR_PORT}/api/system/tasks" -H "X-API-KEY: ${bazarr_key}" \
        --form-string "taskid=update_movies" || true
    http_request POST "http://${API_HOST}:${BAZARR_PORT}/api/system/tasks" -H "X-API-KEY: ${bazarr_key}" \
        --form-string "taskid=update_series" || true
    log_step "Bazarr: triggered library sync with Sonarr/Radarr"
    return 0
}

bazarr_set_auth() {
    local bazarr_key=""
    if [ -z "${AUTH_USERNAME:-}" ] || [ -z "${AUTH_PASSWORD:-}" ]; then
        log_step_fail "Bazarr: new credentials missing"
        return 1
    fi
    if ! bazarr_key=$(read_bazarr_api_key); then
        return 1
    fi
    if ! wait_for_bazarr "$bazarr_key"; then
        return 1
    fi

    local http_code
    http_code=$(_bazarr_post_form "$bazarr_key" \
        --form-string "settings-auth-type=form" \
        --form-string "settings-auth-username=${AUTH_USERNAME}" \
        --form-string "settings-auth-password=${AUTH_PASSWORD}")
    if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
        log_step "Bazarr: set login (${AUTH_USERNAME})"
        return 0
    fi
    local body="${HTTP_BODY:0:200}"
    log_step_fail "Bazarr: failed to set login (HTTP ${http_code}${body:+: $body})"
    return 1
}
