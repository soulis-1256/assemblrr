#!/bin/bash
# assemblrr Bazarr configuration — sourced by config.sh
# Provides: configure_bazarr
# Requires: lib/core.sh, lib/api.sh, INSTALL_DIR, API_HOST, RADARR_API_KEY, SONARR_API_KEY

set -euo pipefail

BAZARR_PORT=6767

# --- helpers ---

# Resolve Bazarr config.ini (linuxserver layout is usually config/config/config.ini)
_bazarr_config_ini() {
    local candidates=(
        "$INSTALL_DIR/config/bazarr/config/config.ini"
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

read_bazarr_api_key() {
    local max_wait=180
    local wait_time=0
    local ini key

    echo -n "Waiting for Bazarr to initialize" >&2
    while [ $wait_time -lt $max_wait ]; do
        if ini=$(_bazarr_config_ini 2>/dev/null); then
            key=$(sed -n 's/^[[:space:]]*apikey[[:space:]]*=[[:space:]]*//p' "$ini" 2>/dev/null | head -1 | tr -d '\r')
            if [ -n "$key" ]; then
                echo >&2
                echo "$key"
                return 0
            fi
        fi
        sleep 3
        wait_time=$((wait_time + 3))
        dot_inline
    done
    echo >&2
    log_step_fail "Bazarr: config.ini / ApiKey missing after ${max_wait}s"
    return 1
}

wait_for_bazarr() {
    local apikey="$1"
    local max_wait="${API_READY_TIMEOUT_SECONDS:-120}"
    local wait_time=0
    local code

    echo -n "Waiting for Bazarr API" >&2
    while [ $wait_time -lt $max_wait ]; do
        code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 \
            "http://${API_HOST}:${BAZARR_PORT}/api/system/status?apikey=${apikey}" 2>/dev/null || echo "000")
        if [ "$code" = "200" ]; then
            echo >&2
            return 0
        fi
        sleep 3
        wait_time=$((wait_time + 3))
        dot_inline
    done
    echo >&2
    log_step_fail "Bazarr: API not ready after ${max_wait}s"
    return 1
}

# POST multipart form settings to Bazarr (args are curl -F fragments after apikey)
_bazarr_post_form() {
    local apikey="$1"
    shift
    # Remaining args: -F "key=value" ...
    curl -s -o /tmp/bazarr-settings-body.txt -w "%{http_code}" --connect-timeout 15 \
        -X POST \
        "http://${API_HOST}:${BAZARR_PORT}/api/system/settings?apikey=${apikey}" \
        "$@" 2>/dev/null || echo "000"
}

# Map setup / ISO 639-1 or 639-2 codes → Bazarr language filter code2 (ISO 639-1)
_bazarr_lang_code2() {
    local code="${1:-en}"
    code=${code%%$'\t'*}
    code=${code// /}
    case "$code" in
        ""|"none"|"None") echo "en"; return ;;
        # Already 2-letter
        [a-z][a-z]) echo "$code"; return ;;
        # Common ISO 639-2/B (and some T) → 639-1 (setup has stored "eng" etc.)
        eng) echo "en" ;;
        gre|ell) echo "el" ;;
        deu|ger) echo "de" ;;
        fra|fre) echo "fr" ;;
        spa) echo "es" ;;
        ita) echo "it" ;;
        por) echo "pt" ;;
        nld|dut) echo "nl" ;;
        rus) echo "ru" ;;
        jpn) echo "ja" ;;
        zho|chi) echo "zh" ;;
        kor) echo "ko" ;;
        ara) echo "ar" ;;
        tur) echo "tr" ;;
        pol) echo "pl" ;;
        swe) echo "sv" ;;
        nor) echo "no" ;;
        dan) echo "da" ;;
        fin) echo "fi" ;;
        heb) echo "he" ;;
        hin) echo "hi" ;;
        *)
            # Unknown 3-letter: keep as-is (Bazarr may reject; better than inventing)
            echo "$code"
            ;;
    esac
}

# Fetch Jellyfin movie/TV library names + ids for Bazarr refresh (optional)
_bazarr_jellyfin_libraries() {
    local jf_key="$1"
    local folders
    folders=$(curl -s --connect-timeout 5 \
        -H "X-Emby-Token: ${jf_key}" \
        "http://${API_HOST}:8096/Library/VirtualFolders" 2>/dev/null || echo "[]")

    # Export via globals used by caller
    BAZARR_JF_MOVIE_NAMES=()
    BAZARR_JF_MOVIE_IDS=()
    BAZARR_JF_SERIES_NAMES=()
    BAZARR_JF_SERIES_IDS=()

    local line name id ctype
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
    done < <(echo "$folders" | jq -r '.[] | select(.CollectionType=="movies" or .CollectionType=="tvshows") | "\(.Name)\t\(.ItemId // .Guid // "")\t\(.CollectionType)"' 2>/dev/null || true)
}

configure_bazarr() {
    local bazarr_key=""
    local lang_code2
    local os_user="" os_pass=""
    local form_args=()
    local http_code
    local providers=()
    local profiles_json
    local has_sonarr=0 has_radarr=0
    local jf_key=""
    local jellyfin_refresh=0

    if ! bazarr_key=$(read_bazarr_api_key); then
        return 1
    fi
    if ! wait_for_bazarr "$bazarr_key"; then
        return 1
    fi

    lang_code2=$(_bazarr_lang_code2 "${SUBTITLE_LANGUAGE:-en}")

    if [ -n "${SONARR_API_KEY:-}" ]; then
        has_sonarr=1
    fi
    if [ -n "${RADARR_API_KEY:-}" ]; then
        has_radarr=1
    fi

    if [ "$has_sonarr" -eq 0 ] && [ "$has_radarr" -eq 0 ]; then
        log_step_fail "Bazarr: neither Sonarr nor Radarr API keys available — skipping"
        return 1
    fi

    # Optional OpenSubtitles.com credentials from secrets/
    if [ -s "$INSTALL_DIR/secrets/opensubtitles_username.txt" ] && [ -s "$INSTALL_DIR/secrets/opensubtitles_password.txt" ]; then
        os_user=$(cat "$INSTALL_DIR/secrets/opensubtitles_username.txt" 2>/dev/null || echo "")
        os_pass=$(cat "$INSTALL_DIR/secrets/opensubtitles_password.txt" 2>/dev/null || echo "")
    fi

    # Default free / no-account providers (+ OS.com when creds present)
    providers=(gestdown yifysubtitles tvsubtitles bsplayer embeddedsubtitles)
    if [ -n "$os_user" ] && [ -n "$os_pass" ]; then
        providers+=(opensubtitlescom)
    fi

    # --- Core integrations + TRaSH-style scoring ---
    form_args=(
        -F "settings-general-use_sonarr=$([ "$has_sonarr" -eq 1 ] && echo true || echo false)"
        -F "settings-general-use_radarr=$([ "$has_radarr" -eq 1 ] && echo true || echo false)"
        -F "settings-general-minimum_score=90"
        -F "settings-general-minimum_score_movie=80"
        -F "settings-general-subfolder=current"
        -F "settings-general-upgrade_subs=true"
        -F "settings-general-days_to_upgrade_subs=7"
        -F "settings-general-use_embedded_subs=true"
        -F "settings-general-serie_default_enabled=true"
        -F "settings-general-serie_default_profile=1"
        -F "settings-general-movie_default_enabled=true"
        -F "settings-general-movie_default_profile=1"
        -F "settings-subsync-use_subsync=true"
        -F "settings-subsync-use_subsync_threshold=true"
        -F "settings-subsync-subsync_threshold=96"
        -F "settings-subsync-use_subsync_movie_threshold=true"
        -F "settings-subsync-subsync_movie_threshold=86"
    )

    local p
    for p in "${providers[@]}"; do
        form_args+=(-F "settings-general-enabled_providers=${p}")
    done

    if [ "$has_sonarr" -eq 1 ]; then
        form_args+=(
            -F "settings-sonarr-ip=sonarr"
            -F "settings-sonarr-port=8989"
            -F "settings-sonarr-base_url=/"
            -F "settings-sonarr-ssl=false"
            -F "settings-sonarr-apikey=${SONARR_API_KEY}"
            -F "settings-sonarr-only_monitored=true"
        )
    fi

    if [ "$has_radarr" -eq 1 ]; then
        form_args+=(
            -F "settings-radarr-ip=radarr"
            -F "settings-radarr-port=7878"
            -F "settings-radarr-base_url=/"
            -F "settings-radarr-ssl=false"
            -F "settings-radarr-apikey=${RADARR_API_KEY}"
            -F "settings-radarr-only_monitored=true"
        )
    fi

    if [ -n "$os_user" ] && [ -n "$os_pass" ]; then
        form_args+=(
            -F "settings-opensubtitlescom-username=${os_user}"
            -F "settings-opensubtitlescom-password=${os_pass}"
            -F "settings-opensubtitlescom-use_hash=true"
            -F "settings-opensubtitlescom-include_ai_translated=false"
            -F "settings-opensubtitlescom-include_machine_translated=false"
        )
    fi

    # Jellyfin refresh after subtitle downloads
    if [ "${MEDIA_SERVICE:-}" = "jellyfin" ]; then
        jf_key=$(cat "$INSTALL_DIR/secrets/jellyfin_api_key.txt" 2>/dev/null || echo "")
        if [ -n "$jf_key" ]; then
            _bazarr_jellyfin_libraries "$jf_key"
            form_args+=(
                -F "settings-general-use_jellyfin=true"
                -F "settings-jellyfin-url=http://jellyfin:8096"
                -F "settings-jellyfin-apikey=${jf_key}"
                -F "settings-jellyfin-update_movie_library=true"
                -F "settings-jellyfin-update_series_library=true"
                -F "settings-jellyfin-refresh_method=immediate"
            )
            local n
            if [ "${#BAZARR_JF_MOVIE_NAMES[@]}" -gt 0 ]; then
                for n in "${BAZARR_JF_MOVIE_NAMES[@]}"; do
                    [ -n "$n" ] && form_args+=(-F "settings-jellyfin-movie_library=${n}")
                done
            fi
            if [ "${#BAZARR_JF_MOVIE_IDS[@]}" -gt 0 ]; then
                for n in "${BAZARR_JF_MOVIE_IDS[@]}"; do
                    [ -n "$n" ] && form_args+=(-F "settings-jellyfin-movie_library_ids=${n}")
                done
            fi
            if [ "${#BAZARR_JF_SERIES_NAMES[@]}" -gt 0 ]; then
                for n in "${BAZARR_JF_SERIES_NAMES[@]}"; do
                    [ -n "$n" ] && form_args+=(-F "settings-jellyfin-series_library=${n}")
                done
            fi
            if [ "${#BAZARR_JF_SERIES_IDS[@]}" -gt 0 ]; then
                for n in "${BAZARR_JF_SERIES_IDS[@]}"; do
                    [ -n "$n" ] && form_args+=(-F "settings-jellyfin-series_library_ids=${n}")
                done
            fi
            jellyfin_refresh=1
        else
            _cfg_log_info "Bazarr: Jellyfin API key not found — skipping JF refresh integration"
        fi
    fi

    # Language filter + single-language profile (id 1 = Default)
    # items: normal (non-HI) preferred language; always include
    profiles_json=$(jq -nc \
        --arg lang "$lang_code2" \
        '[{
            profileId: 1,
            name: "Default",
            cutoff: null,
            items: [{
                id: 1,
                language: $lang,
                audio_exclude: "False",
                audio_only_include: "False",
                hi: "False",
                forced: "False"
            }],
            mustContain: [],
            mustNotContain: [],
            originalFormat: false,
            tag: null
        }]')

    form_args+=(
        -F "languages-enabled=${lang_code2}"
        -F "languages-profiles=${profiles_json}"
    )

    http_code=$(_bazarr_post_form "$bazarr_key" "${form_args[@]}")
    if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
        local provider_list
        provider_list=$(IFS=,; echo "${providers[*]}")
        log_step "Bazarr: configured (lang=${lang_code2}, score S/M=90/80, sync=on, providers=${provider_list})"
        if [ -n "$os_user" ]; then
            log_step "Bazarr: OpenSubtitles.com credentials applied"
        fi
        if [ "$jellyfin_refresh" -eq 1 ]; then
            log_step "Bazarr: Jellyfin refresh enabled"
        fi
    else
        local body=""
        body=$(cat /tmp/bazarr-settings-body.txt 2>/dev/null | head -c 200 || true)
        log_step_fail "Bazarr: settings POST failed (HTTP ${http_code}${body:+: $body})"
        return 1
    fi

    # Persist key for operators / future tooling
    echo -n "$bazarr_key" > "$INSTALL_DIR/secrets/bazarr_api_key.txt"
    chmod 600 "$INSTALL_DIR/secrets/bazarr_api_key.txt" 2>/dev/null || true

    # Kick library sync tasks (best-effort; scheduler also runs on interval)
    if [ "$has_sonarr" -eq 1 ]; then
        curl -s -o /dev/null --connect-timeout 5 -X POST \
            -F "taskid=update_series" \
            "http://${API_HOST}:${BAZARR_PORT}/api/system/tasks?apikey=${bazarr_key}" 2>/dev/null || true
    fi
    if [ "$has_radarr" -eq 1 ]; then
        curl -s -o /dev/null --connect-timeout 5 -X POST \
            -F "taskid=update_movies" \
            "http://${API_HOST}:${BAZARR_PORT}/api/system/tasks?apikey=${bazarr_key}" 2>/dev/null || true
    fi

    return 0
}
