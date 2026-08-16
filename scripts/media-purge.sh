#!/bin/bash
# Remove a title from *arr, library files, and qBittorrent.
# Usage: media-purge.sh --movie-id N | --series-id N | --path P | --tmdb ID | --tvdb ID
#        media-purge.sh --series-id N --seasons 1,2
#        media-purge.sh --radarr-event | --sonarr-event | --qb-only --path P
#        media-purge.sh --match-self-test
#
# TV: --seasons (or a path under Season N) deletes only those seasons' files,
# unmonitors them, and only removes the series when nothing monitored/on-disk
# remains. qB matching then requires a season token and refuses packs that
# also name another season.
#
# Safety ladder for qB cleanup (prefer under-delete over collateral damage):
#   1) *arr history download hashes that still exist in qB and match the folder key
#   2) Exact library-folder key match on torrent name/content_path (Title (YYYY))
#   3) Never bare short titles when a year-bearing folder exists
#   4) Refuse ambiguous multi-matches on the folder-key step
# After a successful non-qb-only purge, best-effort Jellyfin /Library/Refresh.
set -euo pipefail

MEDIA_ROOT="${MEDIA_ROOT:-/data}"
API_HOST="${API_HOST:-127.0.0.1}"
RADARR_URL="${RADARR_URL:-http://${API_HOST}:7878}"
SONARR_URL="${SONARR_URL:-http://${API_HOST}:8989}"
JELLYFIN_URL="${JELLYFIN_URL:-http://jellyfin:8096}"
CONFIG_DIR="${CONFIG_DIR:-}"
DRY_RUN="${DRY_RUN:-0}"
QB_ONLY=0
SKIP_JELLYFIN="${SKIP_JELLYFIN:-0}"
MODE=""
MOVIE_ID=""
SERIES_ID=""
PATH_ARG=""
TMDB_ID=""
TVDB_ID=""
# Comma/space-separated season numbers. Empty = whole series (title-level).
SEASONS=""
# Set when we actually removed something worth notifying the media server about.
PURGE_TOUCHED=0

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

# Library folder key: prefer "Title (YYYY)" basename from *arr path.
folder_key_from() {
    local path="${1:-}" title="${2:-}"
    local b
    if [ -n "$path" ]; then
        b=$(basename_of "$path")
        if [ "${#b}" -ge 3 ] && [ "$b" != "movies" ] && [ "$b" != "tv" ] && [ "$b" != "media" ]; then
            echo "$b"
            return 0
        fi
    fi
    # Title alone only if it already carries a year (avoids sequel prefix traps).
    if [ -n "$title" ] && echo "$title" | grep -qE '\([0-9]{4}\)'; then
        echo "$title"
        return 0
    fi
    echo ""
}

# "1,02 3" → unique integers as lines. Empty / junk → nothing.
parse_season_list() {
    local raw="${1:-}"
    [ -n "$raw" ] || return 0
    echo "$raw" | tr ',; ' '\n' | sed '/^$/d' | awk '
        /^[0-9]+$/ { v=int($0); print v }
    ' | sort -n | uniq
}

# Path under .../Season N/... or .../Specials/... → season number. Else empty.
path_season_number() {
    local p="${1:-}"
    local n
    n=$(printf '%s' "$p" | sed -nE 's|.*/[Ss]eason[[:space:]]*0*([0-9]+)(/.*)?$|\1|p')
    if [ -z "$n" ]; then
        n=$(printf '%s' "$p" | sed -nE 's|.*/[Ss]eason[[:space:]]*0*([0-9]+)/.*|\1|p')
    fi
    if [ -z "$n" ]; then
        case "$p" in
            */[Ss]pecials|*/[Ss]pecials/*) echo 0; return 0 ;;
        esac
        return 0
    fi
    echo $((10#$n))
}

# Series library folder from a path that may include Season N / file.
path_series_folder() {
    local p="${1:-}"
    case "$p" in
        */media/tv/*)
            echo "$p" | sed -E 's|(.*/media/tv/[^/]+).*|\1|'
            ;;
        *)
            echo "$p"
            ;;
    esac
}

seasons_json_from_list() {
    local lines="$1"
    if [ -z "${lines// }" ]; then
        echo "[]"
        return 0
    fi
    echo "$lines" | jq -R . | jq -s -c 'map(tonumber)'
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

qbit_torrents_info() {
    qbit_login
    curl -s --connect-timeout 10 -b "$QBIT_JAR" -H "Referer: ${QBIT_BASE}/" \
        "${QBIT_BASE}/api/v2/torrents/info" 2>/dev/null || echo "[]"
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
    PURGE_TOUCHED=1
}

# Folder-key matcher: exact / boundary-safe match only.
# stdin: qB torrents JSON; arg1: JSON string array of folder keys (prefer Title (YYYY)).
qb_match_jq() {
    jq -r --argjson tokens "$1" '
        def norm:
          ascii_downcase
          | gsub("\\\\"; "/")
          | gsub("[._]+"; " ")
          | gsub(" +"; " ")
          | gsub("^ +| +$"; "");
        def has_year: test("\\([0-9]{4}\\)");
        def basename_norm:
          gsub("/+$"; "") | split("/") | map(select(length > 0)) | .[-1] // "" | norm;
        # After token, only end / " (YYYY" / " [" / " - " / " /" / ".YYYY" — not more title words.
        def boundary_ok($t; $tok):
          ($tok | length) as $m
          | ($t | length) as $n
          | if $n < $m then false
            elif $n == $m then true
            else ($t[$m:] | test("^($| \\([0-9]{4}\\)| \\[| - | /|\\.[0-9]{4})"))
            end;
        def folder_hit($text; $tok):
          ($text | norm) as $t
          | ($tok | norm) as $k
          | if ($k | length) < 3 then false
            else
              ($t | basename_norm) as $base
              | (
                  ($base == $k)
                  or ($t == $k)
                  or ($t | endswith("/" + $k))
                  or ($t | contains("/" + $k + "/"))
                  or (($base | startswith($k)) and boundary_ok($base; $k))
                  or (($t | startswith($k)) and boundary_ok($t; $k))
                )
            end;
        ($tokens | map(norm) | map(select(length >= 3)) | unique) as $all
        | ([$all[] | select(has_year)]) as $yeared
        | (if ($yeared | length) > 0 then $yeared else $all end) as $use
        | .[]
        | . as $row
        | select(
            any($use[];
              folder_hit($row.name // ""; .)
              or folder_hit($row.content_path // ""; .)
            )
          )
        | .hash
    '
}

# Season-scoped matcher: require at least one requested season token in the
# name/path, refuse if the torrent also names a season we are not deleting
# (including S01-03 / Season 1-3 ranges), and require the same folder-key
# rules as title-level (short keys skipped). Torrents with no parseable
# season are skipped (under-delete).
qb_match_season_jq() {
    jq -r --arg folder "$1" --argjson seasons "$2" '
        def norm:
          ascii_downcase
          | gsub("\\\\"; "/")
          | gsub("[._]+"; " ")
          | gsub(" +"; " ")
          | gsub("^ +| +$"; "");
        def basename_norm:
          gsub("/+$"; "") | split("/") | map(select(length > 0)) | .[-1] // "" | norm;
        def boundary_ok($t; $tok):
          ($tok | length) as $m
          | ($t | length) as $n
          | if $n < $m then false
            elif $n == $m then true
            else ($t[$m:] | test("^($| \\([0-9]{4}\\)| \\[| - | /|\\.[0-9]{4}| s[0-9]| season |[-.]s[0-9])"))
            end;
        def folder_hit($text; $tok):
          ($text | norm) as $t
          | ($tok | norm) as $k
          | if ($k | length) < 3 then false
            else
              ($t | basename_norm) as $base
              | (
                  ($base == $k)
                  or ($t == $k)
                  or ($t | endswith("/" + $k))
                  or ($t | contains("/" + $k + "/"))
                  or (($base | startswith($k)) and boundary_ok($base; $k))
                  or (($t | startswith($k)) and boundary_ok($t; $k))
                )
            end;
        def expand_range($a; $b):
          if $a <= $b then [range($a; $b + 1)] else [range($b; $a + 1)] end;
        def seasons_in($text):
          ($text | ascii_downcase) as $t
          | def nums($re):
              [ $t | scan($re) | if type == "array" then .[0] else . end | tonumber ];
          def ranges($re):
              [ $t | scan($re) | if type == "array" then expand_range(.[0]|tonumber; .[1]|tonumber)[] else empty end ];
          (
            ranges("s0*([0-9]{1,2})[[:space:]]*[-–][[:space:]]*s?0*([0-9]{1,2})")
            + ranges("season[s]?[[:space:]]*0*([0-9]{1,2})[[:space:]]*[-–][[:space:]]*0*([0-9]{1,2})")
            + nums("s([0-9]{1,2})")
            + nums("season[[:space:]]*0*([0-9]{1,2})")
          ) | unique;
        def in_wanted($n): ($seasons | index($n)) != null;
        .[]
        | . as $row
        | (($row.name // "") + " " + ($row.content_path // "")) as $blob
        | (seasons_in($blob)) as $found
        | select(
            ($found | length) > 0
            and (any($found[]; in_wanted(.)))
            and (all($found[]; in_wanted(.)))
            and (
              folder_hit($row.name // ""; $folder)
              or folder_hit($row.content_path // ""; $folder)
            )
          )
        | .hash
    '
}

# Keep history hashes that (a) still exist in qB and (b) match folder key when known.
# stdin: qB info JSON. args: folder_key, then candidate hashes.
qbit_filter_hashes_jq() {
    local folder_key="$1"
    shift
    local hashes_json
    # Lowercase/trim only — do not strip non-hex (breaks tests and rare non-standard ids).
    hashes_json=$(printf '%s\n' "$@" | jq -R . | jq -s -c 'map(ascii_downcase | gsub("^ +| +$"; "")) | map(select(length > 0)) | unique')
    jq -r --argjson want "$hashes_json" --arg folder "$folder_key" '
        def norm:
          ascii_downcase
          | gsub("\\\\"; "/")
          | gsub("[._]+"; " ")
          | gsub(" +"; " ")
          | gsub("^ +| +$"; "");
        def basename_norm:
          gsub("/+$"; "") | split("/") | map(select(length > 0)) | .[-1] // "" | norm;
        def boundary_ok($t; $tok):
          ($tok | length) as $m
          | ($t | length) as $n
          | if $n < $m then false
            elif $n == $m then true
            else ($t[$m:] | test("^($| \\([0-9]{4}\\)| \\[| - | /|\\.[0-9]{4})"))
            end;
        def folder_hit($text; $tok):
          ($tok | length) == 0 or (
            ($text | norm) as $t
            | ($tok | norm) as $k
            | ($t | basename_norm) as $base
            | (
                ($base == $k)
                or ($t | endswith("/" + $k))
                or ($t | contains("/" + $k + "/"))
                or (($base | startswith($k)) and boundary_ok($base; $k))
              )
          );
        # index==0 is falsy in jq — must compare to null explicitly
        [ .[] | select((.hash | ascii_downcase) as $h | (($want | index($h)) != null)) ] as $live
        | if ($folder | length) == 0 then
            $live[] | .hash
          else
            ($live
              | map(select(
                  folder_hit(.name // ""; $folder)
                  or folder_hit(.content_path // ""; $folder)
                ))
            ) as $matched
            | if ($matched | length) > 0 then $matched[] | .hash
              else empty
              end
          end
    '
}

qbit_delete_by_folder_key() {
    local folder_key="$1"
    [ -n "$folder_key" ] || { log "qB: no folder key"; return 0; }

    local info hashes hash_count tokens_json
    info=$(qbit_torrents_info)
    [ -n "$info" ] && [ "$info" != "[]" ] || { log "qB: no torrents"; return 0; }

    tokens_json=$(jq -nc --arg k "$folder_key" '[$k]')
    log "qB: folder key: $folder_key"
    hashes=$(echo "$info" | qb_match_jq "$tokens_json" 2>/dev/null || true)

    if [ -z "${hashes// }" ]; then
        log "qB: no torrents matched folder key"
        return 0
    fi
    hash_count=$(echo "$hashes" | grep -c . || true)
    if [ "${hash_count:-0}" -gt 1 ]; then
        log "qB: WARNING ${hash_count} torrents matched folder key (refusing multi-delete). hashes=$(echo "$hashes" | tr '\n' ' ')"
        return 0
    fi
    # shellcheck disable=SC2086
    qbit_delete_hashes $hashes
}

qbit_delete_by_folder_key_seasons() {
    local folder_key="$1"
    local seasons_json="$2"
    [ -n "$folder_key" ] || { log "qB: no folder key"; return 0; }
    [ -n "$seasons_json" ] && [ "$seasons_json" != "[]" ] || { log "qB: no seasons"; return 0; }

    local info hashes hash_count
    info=$(qbit_torrents_info)
    [ -n "$info" ] && [ "$info" != "[]" ] || { log "qB: no torrents"; return 0; }

    log "qB: folder key: $folder_key seasons: $seasons_json"
    hashes=$(echo "$info" | qb_match_season_jq "$folder_key" "$seasons_json" 2>/dev/null || true)

    if [ -z "${hashes// }" ]; then
        log "qB: no torrents matched folder key + seasons"
        return 0
    fi
    hash_count=$(echo "$hashes" | grep -c . || true)
    log "qB: ${hash_count} torrent(s) matched folder key + seasons"
    # shellcheck disable=SC2086
    qbit_delete_hashes $hashes
}

# Back-compat name used by older call sites / mental model.
qbit_delete_by_tokens() {
    local folder=""
    local t b
    for t in "$@"; do
        [ -n "$t" ] || continue
        b=$(basename_of "$t")
        if echo "$b" | grep -qE '\([0-9]{4}\)'; then
            folder="$b"
            break
        fi
    done
    if [ -z "$folder" ]; then
        for t in "$@"; do
            [ -n "$t" ] || continue
            b=$(basename_of "$t")
            case "$b" in
                media|movies|tv|torrents|data|incomplete|"") continue ;;
            esac
            if [ "${#b}" -ge 10 ]; then
                folder="$b"
                break
            fi
        done
    fi
    qbit_delete_by_folder_key "$folder"
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
        endpoint="/api/v3/history?pageSize=250&seriesId=${id}"
        hist=$(arr_get "$base" "$key" "$endpoint")
        echo "$hist" | jq -r '
            .records[]? | .downloadId // .data.torrentInfoHash // empty
        ' 2>/dev/null | tr 'A-F' 'a-f' | sort -u
    fi
}

# Same as series history, but only grab/import rows whose episode season is in $5 (lines of ints).
arr_history_hashes_seasons() {
    local base="$1" key="$2" id="$3" seasons_json="$4"
    local hist
    hist=$(arr_get "$base" "$key" "/api/v3/history?pageSize=250&seriesId=${id}")
    echo "$hist" | jq -r --argjson seasons "$seasons_json" '
        .records[]? as $r
        | (
            $r.episode.seasonNumber
            // $r.data.seasonNumber
            // empty
          ) as $sn
        | select(($sn != null) and (($seasons | index($sn)) != null))
        | $r.downloadId // $r.data.torrentInfoHash // empty
    ' 2>/dev/null | tr 'A-F' 'a-f' | sort -u
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
    if [ "$code" = "200" ] || [ "$code" = "204" ]; then
        PURGE_TOUCHED=1
    fi
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
    if [ "$code" = "200" ] || [ "$code" = "204" ]; then
        PURGE_TOUCHED=1
    fi
}

# True when this season list covers every remaining on-disk / monitored season
# (specials/0 ignored unless listed). Used to decide series delete vs season.
seasons_cover_remaining() {
    local key="$1" id="$2" seasons_json="$3"
    local series files
    series=$(arr_get "$SONARR_URL" "$key" "/api/v3/series/${id}")
    files=$(arr_get "$SONARR_URL" "$key" "/api/v3/episodefile?seriesId=${id}")
    echo "$series" | jq -e --argjson seasons "$seasons_json" --argjson files "${files:-[]}" '
        ([ $files[]? | .seasonNumber ] | unique) as $on_disk
        | ([ .seasons[]? | select(.monitored == true) | .seasonNumber ]) as $mon
        | (($on_disk + $mon) | unique | map(select(. != 0 or ($seasons | index(0)) != null))) as $remain
        | ($remain | length) > 0
        and (all($remain[]; ($seasons | index(.)) != null))
    ' >/dev/null 2>&1
}

arr_unmonitor_seasons() {
    local key="$1" id="$2" seasons_json="$3"
    local series updated code
    series=$(arr_get "$SONARR_URL" "$key" "/api/v3/series/${id}")
    [ -n "$series" ] && [ "$series" != "null" ] || return 0
    updated=$(echo "$series" | jq --argjson seasons "$seasons_json" '
        .seasons = [ .seasons[] | if ($seasons | index(.seasonNumber)) != null
            then .monitored = false else . end ]
    ')
    [ -n "$updated" ] || return 0
    if [ "$DRY_RUN" = "1" ]; then log "DRY_RUN: skip unmonitor"; return 0; fi
    code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 15 -X PUT \
        -H "X-Api-Key: ${key}" -H "Content-Type: application/json" \
        -d "$updated" \
        "${SONARR_URL}/api/v3/series/${id}" 2>/dev/null || echo "000")
    log "Sonarr: unmonitor seasons ${seasons_json} HTTP ${code}"

    # Also flip per-episode monitored so missing-search will not re-grab.
    local eps ids
    eps=$(arr_get "$SONARR_URL" "$key" "/api/v3/episode?seriesId=${id}")
    ids=$(echo "$eps" | jq -c --argjson seasons "$seasons_json" \
        '[ .[] | select(($seasons | index(.seasonNumber)) != null) | .id ]')
    if [ -n "$ids" ] && [ "$ids" != "[]" ]; then
        curl -s -o /dev/null --connect-timeout 15 -X PUT \
            -H "X-Api-Key: ${key}" -H "Content-Type: application/json" \
            -d "{\"episodeIds\":${ids},\"monitored\":false}" \
            "${SONARR_URL}/api/v3/episode/monitor" >/dev/null || true
    fi
}

arr_delete_series_seasons() {
    local key="$1" id="$2" seasons_json="$3"
    local files fid code
    log "Sonarr: delete episode files for series ${id} seasons ${seasons_json}"
    files=$(arr_get "$SONARR_URL" "$key" "/api/v3/episodefile?seriesId=${id}")
    while IFS= read -r fid; do
        [ -n "$fid" ] || continue
        if [ "$DRY_RUN" = "1" ]; then
            log "DRY_RUN: skip episodefile ${fid}"
            continue
        fi
        code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 15 -X DELETE \
            -H "X-Api-Key: ${key}" \
            "${SONARR_URL}/api/v3/episodefile/${fid}" 2>/dev/null || echo "000")
        log "Sonarr: DELETE episodefile ${fid} HTTP ${code}"
        if [ "$code" = "200" ] || [ "$code" = "204" ]; then
            PURGE_TOUCHED=1
        fi
    done < <(echo "$files" | jq -r --argjson seasons "$seasons_json" \
        '.[] | select(($seasons | index(.seasonNumber)) != null) | .id')
    arr_unmonitor_seasons "$key" "$id" "$seasons_json"
}

# Exact *arr path match only (no bare endswith of short basenames).
arr_id_for_path() {
    local base="$1" key="$2" kind="$3" path="$4"
    local b json
    b=$(basename_of "$path")
    if [ "$kind" = "movie" ]; then
        json=$(arr_get "$base" "$key" "/api/v3/movie")
        echo "$json" | jq -r --arg p "$path" --arg b "$b" '
            .[] | select(
              (.path // "") == $p
              or ((.path // "") == ($p | sub("/$"; "")))
              or ((.path // "") | endswith("/" + $b))
            ) | .id
        ' 2>/dev/null | head -1
    else
        json=$(arr_get "$base" "$key" "/api/v3/series")
        echo "$json" | jq -r --arg p "$path" --arg b "$b" '
            .[] | select(
              (.path // "") == $p
              or ((.path // "") == ($p | sub("/$"; "")))
              or ((.path // "") | endswith("/" + $b))
            ) | .id
        ' 2>/dev/null | head -1
    fi
}

purge_qb() {
    local kind="$1" base_url="$2" key="$3" id="$4" title="$5" path="$6"
    local seasons_json="${7:-}"
    local folder hlist=() filtered=() info h

    folder=$(folder_key_from "$path" "$title")
    log "qB purge kind=${kind} id=${id} folder_key=${folder:-<none>} seasons=${seasons_json:-<all>}"

    if [ -n "$seasons_json" ] && [ "$seasons_json" != "[]" ]; then
        while IFS= read -r h; do
            [ -n "$h" ] && hlist+=("$h")
        done < <(arr_history_hashes_seasons "$base_url" "$key" "$id" "$seasons_json")
    else
        while IFS= read -r h; do
            [ -n "$h" ] && hlist+=("$h")
        done < <(arr_history_hashes "$base_url" "$key" "$kind" "$id")
    fi

    if [ "${#hlist[@]}" -gt 0 ]; then
        log "${kind} history candidates: ${hlist[*]}"
        info=$(qbit_torrents_info)
        while IFS= read -r h; do
            [ -n "$h" ] && filtered+=("$h")
        done < <(echo "$info" | qbit_filter_hashes_jq "$folder" "${hlist[@]}" 2>/dev/null || true)

        if [ "${#filtered[@]}" -gt 0 ]; then
            # Season-scoped: drop hashes whose torrent names another season.
            if [ -n "$seasons_json" ] && [ "$seasons_json" != "[]" ]; then
                local kept=()
                local season_hits
                season_hits=$(echo "$info" | qb_match_season_jq "$folder" "$seasons_json" 2>/dev/null || true)
                for h in "${filtered[@]}"; do
                    if echo "$season_hits" | grep -qx "$h"; then
                        kept+=("$h")
                    else
                        log "qB: drop history hash $h (other season or no season token)"
                    fi
                done
                if [ "${#kept[@]}" -gt 0 ]; then
                    log "qB: history hashes validated (${#kept[@]}): ${kept[*]}"
                    qbit_delete_hashes "${kept[@]}"
                    return 0
                fi
            else
                log "qB: history hashes validated (${#filtered[@]}): ${filtered[*]}"
                qbit_delete_hashes "${filtered[@]}"
                return 0
            fi
        fi
        log "qB: history hashes not in qB or failed folder check; trying folder key"
    else
        log "no history hashes for ${kind} ${id}"
    fi

    if [ -n "$folder" ]; then
        if [ -n "$seasons_json" ] && [ "$seasons_json" != "[]" ]; then
            qbit_delete_by_folder_key_seasons "$folder" "$seasons_json"
        else
            qbit_delete_by_folder_key "$folder"
        fi
    else
        log "qB: skip token fallback (no safe folder key)"
    fi
}

purge_qb_for_movie() {
    purge_qb movie "$RADARR_URL" "$1" "$2" "$3" "$4"
}

purge_qb_for_series() {
    purge_qb series "$SONARR_URL" "$1" "$2" "$3" "$4" "${5:-}"
}

# Best-effort library refresh so deletes do not leave ghost items.
notify_jellyfin() {
    if [ "$SKIP_JELLYFIN" = "1" ] || [ "$DRY_RUN" = "1" ]; then
        return 0
    fi
    if [ "$PURGE_TOUCHED" != "1" ]; then
        return 0
    fi
    # Only meaningful for Jellyfin (and Emby-compatible token header).
    case "${MEDIA_SERVICE:-jellyfin}" in
        jellyfin|emby|"") ;;
        *) log "media server ${MEDIA_SERVICE}: skip library refresh"; return 0 ;;
    esac

    local key="" url code
    if [ -n "${JELLYFIN_API_KEY:-}" ]; then
        key="$JELLYFIN_API_KEY"
    elif [ -f "${JELLYFIN_API_KEY_FILE:-/run/secrets/jellyfin_api_key.txt}" ]; then
        key=$(read_secret_file "${JELLYFIN_API_KEY_FILE:-/run/secrets/jellyfin_api_key.txt}" 2>/dev/null || true)
    elif [ -n "${CONFIG_DIR:-}" ] && [ -f "${CONFIG_DIR}/../secrets/jellyfin_api_key.txt" ]; then
        key=$(read_secret_file "${CONFIG_DIR}/../secrets/jellyfin_api_key.txt" 2>/dev/null || true)
    elif [ -n "${INSTALL_DIR:-}" ] && [ -f "${INSTALL_DIR}/secrets/jellyfin_api_key.txt" ]; then
        key=$(read_secret_file "${INSTALL_DIR}/secrets/jellyfin_api_key.txt" 2>/dev/null || true)
    fi
    if [ -z "$key" ]; then
        log "Jellyfin: no API key; skip library refresh"
        return 0
    fi

    url="${JELLYFIN_URL%/}/Library/Refresh"
    code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 8 \
        -X POST -H "X-Emby-Token: ${key}" "$url" 2>/dev/null || echo "000")
    if [ "$code" -ge 200 ] && [ "$code" -lt 300 ]; then
        log "Jellyfin: library refresh triggered (HTTP ${code})"
    else
        log "Jellyfin: library refresh failed (HTTP ${code})"
    fi
}

# Offline matcher self-test (no Docker / qB): media-purge.sh --match-self-test
if [ "${1:-}" = "--match-self-test" ]; then
    failures=0
    check() {
        local want="$1" name="$2" tokens="$3" torrents="$4"
        local got
        got=$(echo "$torrents" | qb_match_jq "$tokens" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
        if [ "$got" = "$want" ]; then
            echo "  PASS: $name"
        else
            echo "  FAIL: $name (want='$want' got='$got')"
            failures=$((failures + 1))
        fi
    }
    check_filter() {
        local want="$1" name="$2" folder="$3" torrents="$4"
        shift 4
        local got
        got=$(echo "$torrents" | qbit_filter_hashes_jq "$folder" "$@" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
        if [ "$got" = "$want" ]; then
            echo "  PASS: $name"
        else
            echo "  FAIL: $name (want='$want' got='$got')"
            failures=$((failures + 1))
        fi
    }
    echo "=== media-purge qB match self-test ==="
    # Synthetic titles only — prove match rules, not real catalog entries.
    check "hash_a" "year folder hits only first film" \
        '["Alpha Film (2016)"]' \
        '[{"hash":"hash_a","name":"Alpha Film (2016) [GRP]","content_path":"/data/torrents/movies/Alpha Film (2016)"},{"hash":"hash_b","name":"Alpha Film Sequel Extended (2022)","content_path":"/data/torrents/movies/Alpha Film Sequel Extended (2022)"}]'
    check "" "bare short title does not hit longer sequel name" \
        '["Alpha Film"]' \
        '[{"hash":"hash_b","name":"Alpha Film Sequel Extended (2022)","content_path":"/data/torrents/movies/Alpha Film Sequel Extended (2022)"}]'
    check "hash_a" "bare short title hits exact name only" \
        '["Alpha Film"]' \
        '[{"hash":"hash_a","name":"Alpha Film","content_path":"/data/torrents/movies/Alpha Film"},{"hash":"hash_b","name":"Alpha Film Sequel Extended","content_path":"/data/torrents/movies/Alpha Film Sequel Extended"}]'
    check "hash_y" "year preferred when bare+year present" \
        '["Sample Title","Sample Title (2008)"]' \
        '[{"hash":"hash_y","name":"Sample Title (2008) [e2e]","content_path":"/data/torrents/movies/Sample Title (2008) [e2e]"},{"hash":"hash_z","name":"Sample Title Adventures","content_path":"/data/torrents/movies/Sample Title Adventures"}]'
    check "hash_m1" "bare title does not hit same-prefix sequel" \
        '["Beta Movie"]' \
        '[{"hash":"hash_m1","name":"Beta Movie","content_path":"/data/torrents/movies/Beta Movie"},{"hash":"hash_m2","name":"Beta Movie Reloaded","content_path":"/data/torrents/movies/Beta Movie Reloaded"}]'
    check_filter "hash_a" "history filter keeps folder-matched hash only" \
        "Alpha Film (2016)" \
        '[{"hash":"hash_a","name":"Alpha Film (2016)","content_path":"/data/torrents/movies/Alpha Film (2016)"},{"hash":"hash_b","name":"Alpha Film Sequel Extended (2022)","content_path":"/data/torrents/movies/Alpha Film Sequel Extended (2022)"}]' \
        hash_a hash_b
    check_filter "" "history filter drops all when none match folder" \
        "Alpha Film (2016)" \
        '[{"hash":"hash_b","name":"Alpha Film Sequel Extended (2022)","content_path":"/data/torrents/movies/Alpha Film Sequel Extended (2022)"}]' \
        hash_b
    check_season() {
        local want="$1" name="$2" folder="$3" seasons="$4" torrents="$5"
        local got
        got=$(echo "$torrents" | qb_match_season_jq "$folder" "$seasons" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
        if [ "$got" = "$want" ]; then
            echo "  PASS: $name"
        else
            echo "  FAIL: $name (want='$want' got='$got')"
            failures=$((failures + 1))
        fi
    }
    check_season "hash_s1" "S01 pack matches season 1 only" \
        "Loki" '[1]' \
        '[{"hash":"hash_s1","name":"Loki.S01.COMPLETE.1080p","content_path":"/data/torrents/tv/Loki.S01.COMPLETE.1080p"},{"hash":"hash_s2","name":"Loki.S02.COMPLETE.1080p","content_path":"/data/torrents/tv/Loki.S02.COMPLETE.1080p"}]'
    check_season "" "S02 pack is not deleted with season 1" \
        "Loki" '[1]' \
        '[{"hash":"hash_s2","name":"Loki.S02.COMPLETE.1080p.DSNP.WEB-DL","content_path":"/data/torrents/tv/Loki.S02.COMPLETE.1080p.DSNP.WEB-DL"}]'
    check_season "" "multi-season pack refused when deleting S01 only" \
        "Loki" '[1]' \
        '[{"hash":"hash_both","name":"Loki.S01.S02.COMPLETE","content_path":"/data/torrents/tv/Loki.S01.S02.COMPLETE"}]'
    check_season "" "no season token is skipped (under-delete)" \
        "Loki" '[1]' \
        '[{"hash":"hash_bare","name":"Loki","content_path":"/data/torrents/tv/Loki"}]'
    check_season "" "other show S01 is not matched" \
        "Loki" '[1]' \
        '[{"hash":"hash_x","name":"Other Show.S01.COMPLETE","content_path":"/data/torrents/tv/Other Show.S01.COMPLETE"}]'
    check_season "" "S01-03 range pack refused when deleting S01 only" \
        "Loki" '[1]' \
        '[{"hash":"hash_r","name":"Loki.S01-03.COMPLETE","content_path":"/data/torrents/tv/Loki.S01-03.COMPLETE"}]'
    check_season "" "Season 1-3 range pack refused when deleting S01 only" \
        "Loki" '[1]' \
        '[{"hash":"hash_r2","name":"Loki Season 1-3","content_path":"/data/torrents/tv/Loki Season 1-3"}]'
    check_season "" "short folder key does not match any S01 torrent" \
        "Oz" '[1]' \
        '[{"hash":"hash_oz","name":"Other.S01.COMPLETE","content_path":"/data/torrents/tv/Other.S01.COMPLETE"}]'
    check_season "" "Lost S01 does not match Lost in Space S01" \
        "Lost" '[1]' \
        '[{"hash":"hash_lis","name":"Lost in Space.S01.COMPLETE","content_path":"/data/torrents/tv/Lost in Space.S01.COMPLETE"}]'
    check_season "hash_e1 hash_e2" "multiple S01E0x torrents all match" \
        "Loki" '[1]' \
        '[{"hash":"hash_e1","name":"Loki.S01E01","content_path":"/data/torrents/tv/Loki.S01E01"},{"hash":"hash_e2","name":"Loki.S01E02","content_path":"/data/torrents/tv/Loki.S01E02"}]'
    if [ "$failures" -gt 0 ]; then
        echo "match-self-test: FAILED ($failures)"
        exit 1
    fi
    echo "match-self-test: OK"
    exit 0
fi

# --- args ---
while [ $# -gt 0 ]; do
    case "$1" in
        --movie-id) MOVIE_ID="$2"; MODE=movie; shift 2 ;;
        --series-id) SERIES_ID="$2"; MODE=series; shift 2 ;;
        --path) PATH_ARG="$2"; MODE="${MODE:-path}"; shift 2 ;;
        --tmdb) TMDB_ID="$2"; MODE=tmdb; shift 2 ;;
        --tvdb) TVDB_ID="$2"; MODE=tvdb; shift 2 ;;
        --seasons) SEASONS="$2"; shift 2 ;;
        --radarr-event) MODE=radarr-event; shift ;;
        --sonarr-event) MODE=sonarr-event; shift ;;
        --qb-only) QB_ONLY=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --skip-jellyfin) SKIP_JELLYFIN=1; shift ;;
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
            # Movie-level only: file deletes are partial and must not wipe whole qB items by title.
            MovieDelete) ;;
            MovieFileDelete)
                log "ignore MovieFileDelete (movie-level purge only)"
                exit 0
                ;;
            *) log "ignore ${et}"; exit 0 ;;
        esac
        mid="${radarr_movie_id:-}"
        title="${radarr_movie_title:-}"
        path="${radarr_movie_path:-}"
        if [ -n "$mid" ] && [ -n "$RADARR_API_KEY" ]; then
            purge_qb_for_movie "$RADARR_API_KEY" "$mid" "$title" "$path"
        else
            qbit_delete_by_folder_key "$(folder_key_from "$path" "$title")"
        fi
        # Files already removed by Radarr; still refresh Jellyfin.
        PURGE_TOUCHED=1
        notify_jellyfin
        exit 0
        ;;
    sonarr-event)
        et="${sonarr_eventtype:-}"
        log "sonarr event type=${et}"
        case "$et" in
            Test) log "Test ok"; exit 0 ;;
            SeriesDelete) ;;
            EpisodeFileDelete)
                log "ignore EpisodeFileDelete (series-level purge only)"
                exit 0
                ;;
            *) log "ignore ${et}"; exit 0 ;;
        esac
        sid="${sonarr_series_id:-}"
        title="${sonarr_series_title:-}"
        path="${sonarr_series_path:-}"
        if [ -n "$sid" ] && [ -n "$SONARR_API_KEY" ]; then
            purge_qb_for_series "$SONARR_API_KEY" "$sid" "$title" "$path"
        else
            qbit_delete_by_folder_key "$(folder_key_from "$path" "$title")"
        fi
        PURGE_TOUCHED=1
        notify_jellyfin
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
        season_lines=$(parse_season_list "$SEASONS")
        if [ -n "$season_lines" ]; then
            seasons_json=$(seasons_json_from_list "$season_lines")
            log "series ${SERIES_ID} season-scoped ${seasons_json}"
            purge_qb_for_series "$SONARR_API_KEY" "$SERIES_ID" "$title" "$path" "$seasons_json"
            if [ "$QB_ONLY" != "1" ]; then
                if seasons_cover_remaining "$SONARR_API_KEY" "$SERIES_ID" "$seasons_json"; then
                    log "requested seasons cover remaining library; deleting series"
                    arr_delete_series "$SONARR_API_KEY" "$SERIES_ID"
                else
                    arr_delete_series_seasons "$SONARR_API_KEY" "$SERIES_ID" "$seasons_json"
                fi
            fi
        else
            purge_qb_for_series "$SONARR_API_KEY" "$SERIES_ID" "$title" "$path"
            if [ "$QB_ONLY" != "1" ]; then
                arr_delete_series "$SONARR_API_KEY" "$SERIES_ID"
            fi
        fi
        ;;
    path)
        [ -n "$PATH_ARG" ] || die "--path required"
        path="$PATH_ARG"
        base=$(basename_of "$path")
        log "purge by path=${path}"

        if [ "$QB_ONLY" != "1" ] && [ -n "$RADARR_API_KEY" ]; then
            mid=$(arr_id_for_path "$RADARR_URL" "$RADARR_API_KEY" movie "$path")
            if [ -n "$mid" ]; then
                movie=$(arr_get "$RADARR_URL" "$RADARR_API_KEY" "/api/v3/movie/${mid}")
                title=$(echo "$movie" | jq -r '.title // empty')
                mpath=$(echo "$movie" | jq -r '.path // empty')
                purge_qb_for_movie "$RADARR_API_KEY" "$mid" "$title" "$mpath"
                arr_delete_movie "$RADARR_API_KEY" "$mid"
                notify_jellyfin
                log "done"
                exit 0
            fi
        fi

        if [ "$QB_ONLY" != "1" ] && [ -n "$SONARR_API_KEY" ]; then
            series_folder=$(path_series_folder "$path")
            sid=$(arr_id_for_path "$SONARR_URL" "$SONARR_API_KEY" series "$series_folder")
            [ -n "$sid" ] || sid=$(arr_id_for_path "$SONARR_URL" "$SONARR_API_KEY" series "$path")
            if [ -n "$sid" ]; then
                series=$(arr_get "$SONARR_URL" "$SONARR_API_KEY" "/api/v3/series/${sid}")
                title=$(echo "$series" | jq -r '.title // empty')
                spath=$(echo "$series" | jq -r '.path // empty')
                inferred=$(path_season_number "$path")
                season_lines=$(parse_season_list "${SEASONS:-$inferred}")
                if [ -n "$season_lines" ]; then
                    seasons_json=$(seasons_json_from_list "$season_lines")
                    log "path series ${sid} season-scoped ${seasons_json}"
                    purge_qb_for_series "$SONARR_API_KEY" "$sid" "$title" "$spath" "$seasons_json"
                    if seasons_cover_remaining "$SONARR_API_KEY" "$sid" "$seasons_json"; then
                        log "requested seasons cover remaining library; deleting series"
                        arr_delete_series "$SONARR_API_KEY" "$sid"
                    else
                        arr_delete_series_seasons "$SONARR_API_KEY" "$sid" "$seasons_json"
                    fi
                else
                    purge_qb_for_series "$SONARR_API_KEY" "$sid" "$title" "$spath"
                    arr_delete_series "$SONARR_API_KEY" "$sid"
                fi
                notify_jellyfin
                log "done"
                exit 0
            fi
        fi

        log "no *arr row; folder-key qB cleanup only"
        series_folder=$(path_series_folder "$path")
        inferred=$(path_season_number "$path")
        season_lines=$(parse_season_list "${SEASONS:-$inferred}")
        if [ -n "$season_lines" ]; then
            qbit_delete_by_folder_key_seasons "$(folder_key_from "$series_folder" "$base")" \
                "$(seasons_json_from_list "$season_lines")"
        else
            qbit_delete_by_folder_key "$(folder_key_from "$series_folder" "$base")"
        fi
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
        if [ -n "$SEASONS" ]; then
            exec "$0" --series-id "$sid" --seasons "$SEASONS"
        fi
        exec "$0" --series-id "$sid"
        ;;
    *)
        die "specify --movie-id, --series-id, --path, --tmdb, --tvdb, --radarr-event, or --sonarr-event"
        ;;
esac

if [ "$QB_ONLY" != "1" ]; then
    notify_jellyfin
fi
log "done"
