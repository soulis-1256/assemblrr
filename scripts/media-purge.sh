#!/bin/bash
# Remove a title from *arr, library files, and qBittorrent.
# Usage: media-purge.sh --movie-id N | --series-id N | --path P | --tmdb ID | --tvdb ID
#        media-purge.sh --radarr-event | --sonarr-event | --qb-only --path P
set -euo pipefail

MEDIA_ROOT="${MEDIA_ROOT:-/data}"
API_HOST="${API_HOST:-127.0.0.1}"
RADARR_URL="${RADARR_URL:-http://${API_HOST}:7878}"
SONARR_URL="${SONARR_URL:-http://${API_HOST}:8989}"
CONFIG_DIR="${CONFIG_DIR:-}"
DRY_RUN="${DRY_RUN:-0}"
QB_ONLY=0
MODE=""
MOVIE_ID=""
SERIES_ID=""
PATH_ARG=""
TMDB_ID=""
TVDB_ID=""

log() { echo "media-purge: $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

read_secret_file() {
    local f="$1"
    [ -f "$f" ] || return 1
    tr -d '\r\n' <"$f"
}

basename_of() {
    local p="$1"
    p="${p%/}"
    echo "${p##*/}"
}

discover_api_key() {
    local svc="$1"
    local env_key="${2:-}"
    if [ -n "${env_key}" ]; then
        echo "$env_key"
        return 0
    fi
    local f
    for f in \
        "${CONFIG_DIR:+$CONFIG_DIR/$svc/config.xml}" \
        "/config/$svc/config.xml" \
        "${INSTALL_DIR:+$INSTALL_DIR/config/$svc/config.xml}"; do
        [ -n "${f:-}" ] && [ -f "$f" ] || continue
        local k
        k=$(sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p' "$f" 2>/dev/null | head -1)
        if [ -n "$k" ]; then
            echo "$k"
            return 0
        fi
    done
    return 1
}

qbit_login() {
    local user pass jar
    jar="${1:-/tmp/media-purge-qb.cookies}"
    user="${AUTH_USERNAME:-}"
    pass="${AUTH_PASSWORD:-}"
    [ -z "$user" ] && user=$(read_secret_file "${AUTH_USERNAME_FILE:-/run/secrets/auth_username.txt}" 2>/dev/null || true)
    [ -z "$pass" ] && pass=$(read_secret_file "${AUTH_PASSWORD_FILE:-/run/secrets/auth_password.txt}" 2>/dev/null || true)
    [ -n "$user" ] && [ -n "$pass" ] || die "qBittorrent credentials missing"

    if [ -n "${QBITTORRENT_URL:-}" ]; then
        QBIT_BASE="$QBITTORRENT_URL"
    else
        QBIT_BASE=""
        local try
        for try in "http://gluetun:8081" "http://qbittorrent:8081" "http://${API_HOST}:8081" "http://127.0.0.1:8081"; do
            if curl -s --connect-timeout 2 -o /dev/null -w "%{http_code}" "${try}/" 2>/dev/null | grep -qE '^[2345]'; then
                QBIT_BASE="$try"
                break
            fi
        done
        [ -n "$QBIT_BASE" ] || QBIT_BASE="http://${API_HOST}:8081"
    fi

    QBIT_JAR="$jar"
    curl -s --connect-timeout 8 -c "$QBIT_JAR" \
        -H "Referer: ${QBIT_BASE}/" \
        -d "username=${user}&password=${pass}" \
        "${QBIT_BASE}/api/v2/auth/login" >/dev/null || true
    if ! curl -s --connect-timeout 5 -b "$QBIT_JAR" -H "Referer: ${QBIT_BASE}/" \
        "${QBIT_BASE}/api/v2/app/version" 2>/dev/null | grep -q .; then
        die "qBittorrent login failed (${QBIT_BASE})"
    fi
    log "qB session ok (${QBIT_BASE})"
}

qbit_delete_hashes() {
    local hashes=("$@")
    [ "${#hashes[@]}" -gt 0 ] || return 0
    qbit_login
    local csv="" h
    for h in "${hashes[@]}"; do
        h=$(echo "$h" | tr 'A-F' 'a-f' | tr -d '[:space:]')
        [ -n "$h" ] || continue
        [ -n "$csv" ] && csv="${csv}|${h}" || csv="$h"
    done
    [ -n "$csv" ] || return 0
    log "qB: deleting hashes with files: $csv"
    if [ "$DRY_RUN" = "1" ]; then
        log "DRY_RUN: skip qB delete"
        return 0
    fi
    curl -s --connect-timeout 15 -b "$QBIT_JAR" -H "Referer: ${QBIT_BASE}/" \
        -d "hashes=${csv}&deleteFiles=true" \
        "${QBIT_BASE}/api/v2/torrents/delete" >/dev/null || true
}

qbit_delete_by_tokens() {
    local tokens=("$@")
    local cleaned=() t
    for t in "${tokens[@]}"; do
        [ -n "$t" ] || continue
        t=$(echo "$t" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        case "$t" in
            media|movies|tv|torrents|data|incomplete|/data|/data/*movies|/data/*tv) continue ;;
        esac
        local b
        b=$(basename_of "$t")
        if [ "${#b}" -ge 10 ]; then
            cleaned+=("$b")
        fi
    done
    if [ "${#cleaned[@]}" -eq 0 ]; then
        log "qB: no match tokens"
        return 0
    fi

    qbit_login
    local info
    info=$(curl -s --connect-timeout 10 -b "$QBIT_JAR" -H "Referer: ${QBIT_BASE}/" \
        "${QBIT_BASE}/api/v2/torrents/info" 2>/dev/null || echo "[]")
    [ -n "$info" ] && [ "$info" != "[]" ] || { log "qB: no torrents"; return 0; }

    local tokens_json hashes
    tokens_json=$(printf '%s\n' "${cleaned[@]}" | jq -R . | jq -s -c .)
    log "qB: tokens: $(echo "$tokens_json" | jq -r 'join(" | ")')"

    hashes=$(echo "$info" | jq -r --argjson tokens "$tokens_json" '
        def norm: ascii_downcase;
        def hit($text):
          ($text | norm | gsub("\\\\"; "/")) as $t
          | any(
              $tokens[] | select(length >= 10);
              (. | norm) as $tok
              | (
                  ($t | contains("/" + $tok))
                  or ($t | startswith($tok))
                  or ($t | contains($tok + " ["))
                  or ($t | contains($tok + "/"))
                )
            );
        .[]
        | select(hit(.name // "") or hit(.content_path // ""))
        | .hash
    ' 2>/dev/null || true)

    if [ -z "${hashes// }" ]; then
        log "qB: no torrents matched tokens"
        return 0
    fi
    # shellcheck disable=SC2086
    qbit_delete_hashes $hashes
}

arr_get() {
    local base="$1" key="$2" path="$3"
    curl -s --connect-timeout 10 -H "X-Api-Key: ${key}" "${base}${path}" 2>/dev/null || true
}

arr_history_hashes() {
    local base="$1" key="$2" kind="$3" id="$4"
    local endpoint hist
    if [ "$kind" = "movie" ]; then
        endpoint="/api/v3/history/movie?movieId=${id}"
        hist=$(arr_get "$base" "$key" "$endpoint")
        echo "$hist" | jq -r '
            .. | objects
            | .downloadId? // .data.torrentInfoHash? // empty
        ' 2>/dev/null | tr 'A-F' 'a-f' | sort -u
    else
        endpoint="/api/v3/history?pageSize=100&seriesId=${id}"
        hist=$(arr_get "$base" "$key" "$endpoint")
        echo "$hist" | jq -r '
            .records[]? | .downloadId // .data.torrentInfoHash // empty
        ' 2>/dev/null | tr 'A-F' 'a-f' | sort -u
    fi
}

arr_delete_movie() {
    local key="$1" id="$2"
    log "Radarr: DELETE movie id=${id} (deleteFiles=true)"
    if [ "$DRY_RUN" = "1" ]; then log "DRY_RUN"; return 0; fi
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 15 -X DELETE \
        -H "X-Api-Key: ${key}" \
        "${RADARR_URL}/api/v3/movie/${id}?deleteFiles=true&addImportExclusion=false" 2>/dev/null || echo "000")
    log "Radarr: HTTP ${code}"
}

arr_delete_series() {
    local key="$1" id="$2"
    log "Sonarr: DELETE series id=${id} (deleteFiles=true)"
    if [ "$DRY_RUN" = "1" ]; then log "DRY_RUN"; return 0; fi
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 15 -X DELETE \
        -H "X-Api-Key: ${key}" \
        "${SONARR_URL}/api/v3/series/${id}?deleteFiles=true&addImportListExclusion=false" 2>/dev/null || echo "000")
    log "Sonarr: HTTP ${code}"
}

purge_qb_for_movie() {
    local key="$1" id="$2" title="$3" path="$4"
    local hashes hlist=()
    while IFS= read -r h; do
        [ -n "$h" ] && hlist+=("$h")
    done < <(arr_history_hashes "$RADARR_URL" "$key" movie "$id")
    if [ "${#hlist[@]}" -gt 0 ]; then
        log "Radarr history hashes for movie ${id}: ${hlist[*]}"
        qbit_delete_hashes "${hlist[@]}"
    else
        log "no history hashes for movie ${id}; token fallback"
        qbit_delete_by_tokens "$title" "$path" "$(basename_of "$path")"
    fi
}

purge_qb_for_series() {
    local key="$1" id="$2" title="$3" path="$4"
    local hlist=()
    while IFS= read -r h; do
        [ -n "$h" ] && hlist+=("$h")
    done < <(arr_history_hashes "$SONARR_URL" "$key" series "$id")
    if [ "${#hlist[@]}" -gt 0 ]; then
        log "Sonarr history hashes for series ${id}: ${hlist[*]}"
        qbit_delete_hashes "${hlist[@]}"
    else
        log "no history hashes for series ${id}; token fallback"
        qbit_delete_by_tokens "$title" "$path" "$(basename_of "$path")"
    fi
}

# --- args ---
while [ $# -gt 0 ]; do
    case "$1" in
        --movie-id) MOVIE_ID="$2"; MODE=movie; shift 2 ;;
        --series-id) SERIES_ID="$2"; MODE=series; shift 2 ;;
        --path) PATH_ARG="$2"; MODE="${MODE:-path}"; shift 2 ;;
        --tmdb) TMDB_ID="$2"; MODE=tmdb; shift 2 ;;
        --tvdb) TVDB_ID="$2"; MODE=tvdb; shift 2 ;;
        --radarr-event) MODE=radarr-event; shift ;;
        --sonarr-event) MODE=sonarr-event; shift ;;
        --qb-only) QB_ONLY=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) die "unknown arg: $1" ;;
    esac
done

RADARR_API_KEY=$(discover_api_key radarr "${RADARR_API_KEY:-}") || RADARR_API_KEY=""
SONARR_API_KEY=$(discover_api_key sonarr "${SONARR_API_KEY:-}") || SONARR_API_KEY=""

case "$MODE" in
    radarr-event)
        et="${radarr_eventtype:-}"
        log "radarr event type=${et}"
        case "$et" in
            Test) log "Test ok"; exit 0 ;;
            MovieDelete|MovieFileDelete) ;;
            *) log "ignore ${et}"; exit 0 ;;
        esac
        mid="${radarr_movie_id:-}"
        title="${radarr_movie_title:-}"
        path="${radarr_movie_path:-}"
        if [ -n "$mid" ] && [ -n "$RADARR_API_KEY" ]; then
            purge_qb_for_movie "$RADARR_API_KEY" "$mid" "$title" "$path"
        else
            qbit_delete_by_tokens "$title" "$path" "$(basename_of "$path")" \
                "${radarr_moviefile_path:-}" "$(basename_of "${radarr_moviefile_path:-}")"
        fi
        exit 0
        ;;
    sonarr-event)
        et="${sonarr_eventtype:-}"
        log "sonarr event type=${et}"
        case "$et" in
            Test) log "Test ok"; exit 0 ;;
            SeriesDelete|EpisodeFileDelete) ;;
            *) log "ignore ${et}"; exit 0 ;;
        esac
        sid="${sonarr_series_id:-}"
        title="${sonarr_series_title:-}"
        path="${sonarr_series_path:-}"
        if [ -n "$sid" ] && [ -n "$SONARR_API_KEY" ]; then
            purge_qb_for_series "$SONARR_API_KEY" "$sid" "$title" "$path"
        else
            qbit_delete_by_tokens "$title" "$path" "$(basename_of "$path")"
        fi
        exit 0
        ;;
    movie)
        [ -n "$MOVIE_ID" ] || die "--movie-id required"
        [ -n "$RADARR_API_KEY" ] || die "Radarr API key missing"
        movie=$(arr_get "$RADARR_URL" "$RADARR_API_KEY" "/api/v3/movie/${MOVIE_ID}")
        title=$(echo "$movie" | jq -r '.title // empty')
        path=$(echo "$movie" | jq -r '.path // empty')
        # qB first (history still available), then *arr delete
        purge_qb_for_movie "$RADARR_API_KEY" "$MOVIE_ID" "$title" "$path"
        if [ "$QB_ONLY" != "1" ]; then
            arr_delete_movie "$RADARR_API_KEY" "$MOVIE_ID"
        fi
        ;;
    series)
        [ -n "$SERIES_ID" ] || die "--series-id required"
        [ -n "$SONARR_API_KEY" ] || die "Sonarr API key missing"
        series=$(arr_get "$SONARR_URL" "$SONARR_API_KEY" "/api/v3/series/${SERIES_ID}")
        title=$(echo "$series" | jq -r '.title // empty')
        path=$(echo "$series" | jq -r '.path // empty')
        purge_qb_for_series "$SONARR_API_KEY" "$SERIES_ID" "$title" "$path"
        if [ "$QB_ONLY" != "1" ]; then
            arr_delete_series "$SONARR_API_KEY" "$SERIES_ID"
        fi
        ;;
    path)
        [ -n "$PATH_ARG" ] || die "--path required"
        path="$PATH_ARG"
        base=$(basename_of "$path")
        log "purge by path=${path}"

        if [ "$QB_ONLY" != "1" ] && [ -n "$RADARR_API_KEY" ]; then
            movies=$(arr_get "$RADARR_URL" "$RADARR_API_KEY" "/api/v3/movie")
            mid=$(echo "$movies" | jq -r --arg p "$path" --arg b "$base" '
                .[] | select(
                  (.path // "") == $p
                  or ((.path // "") | endswith("/" + $b))
                  or ((.path // "") | endswith($b))
                ) | .id' 2>/dev/null | head -1)
            if [ -n "$mid" ]; then
                movie=$(arr_get "$RADARR_URL" "$RADARR_API_KEY" "/api/v3/movie/${mid}")
                title=$(echo "$movie" | jq -r '.title // empty')
                mpath=$(echo "$movie" | jq -r '.path // empty')
                purge_qb_for_movie "$RADARR_API_KEY" "$mid" "$title" "$mpath"
                arr_delete_movie "$RADARR_API_KEY" "$mid"
                exit 0
            fi
        fi

        if [ "$QB_ONLY" != "1" ] && [ -n "$SONARR_API_KEY" ]; then
            series_json=$(arr_get "$SONARR_URL" "$SONARR_API_KEY" "/api/v3/series")
            sid=$(echo "$series_json" | jq -r --arg p "$path" --arg b "$base" '
                .[] | select(
                  (.path // "") == $p
                  or ((.path // "") | endswith("/" + $b))
                  or ((.path // "") | endswith($b))
                ) | .id' 2>/dev/null | head -1)
            if [ -n "$sid" ]; then
                series=$(arr_get "$SONARR_URL" "$SONARR_API_KEY" "/api/v3/series/${sid}")
                title=$(echo "$series" | jq -r '.title // empty')
                spath=$(echo "$series" | jq -r '.path // empty')
                purge_qb_for_series "$SONARR_API_KEY" "$sid" "$title" "$spath"
                arr_delete_series "$SONARR_API_KEY" "$sid"
                exit 0
            fi
        fi

        log "no *arr row; token-only qB cleanup"
        qbit_delete_by_tokens "$base" "$path"
        ;;
    tmdb)
        [ -n "$TMDB_ID" ] || die "--tmdb required"
        [ -n "$RADARR_API_KEY" ] || die "Radarr API key missing"
        movies=$(arr_get "$RADARR_URL" "$RADARR_API_KEY" "/api/v3/movie")
        mid=$(echo "$movies" | jq -r --argjson t "$TMDB_ID" '.[] | select(.tmdbId == $t) | .id' | head -1)
        [ -n "$mid" ] || die "no Radarr movie tmdbId=${TMDB_ID}"
        exec "$0" --movie-id "$mid"
        ;;
    tvdb)
        [ -n "$TVDB_ID" ] || die "--tvdb required"
        [ -n "$SONARR_API_KEY" ] || die "Sonarr API key missing"
        series_json=$(arr_get "$SONARR_URL" "$SONARR_API_KEY" "/api/v3/series")
        sid=$(echo "$series_json" | jq -r --argjson t "$TVDB_ID" '.[] | select(.tvdbId == $t) | .id' | head -1)
        [ -n "$sid" ] || die "no Sonarr series tvdbId=${TVDB_ID}"
        exec "$0" --series-id "$sid"
        ;;
    *)
        die "specify --movie-id, --series-id, --path, --tmdb, --tvdb, --radarr-event, or --sonarr-event"
        ;;
esac

log "done"
