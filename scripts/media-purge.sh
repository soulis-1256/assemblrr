#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Remove a title from *arr, library files, qBittorrent, and (if enabled) SABnzbd.
# Usage: media-purge.sh --movie-id N | --series-id N | --path P | --tmdb ID | --tvdb ID
#        media-purge.sh --series-id N --seasons 1,2
#        media-purge.sh --radarr-event | --sonarr-event | --qb-only --path P
#
# TV: --seasons (or a path under Season N) deletes only those seasons' files,
# unmonitors them, and only removes the series when nothing monitored/on-disk
# remains. qB matching then requires a season token and refuses packs that
# also name another season.
#
# Safety ladder for download cleanup (prefer under-delete over collateral damage):
#   1) *arr queue + history download IDs/hashes that still exist in qB / SABnzbd
#   2) Title + year match on item name / content path (Alpha Film (2016) ==
#      Alpha Film 2016 REPACK...; indexer prefixes allowed; next token after the
#      title must be that year). No-year keys still require a season/year/end
#      boundary so Sample Show does not hit Sample Show Extended.
#   3) Never bare short titles (len < 3). Refuse ambiguous multi-matches on
#      the name step. Season purge still refuses packs / other seasons.
# After a successful non-qb-only purge, best-effort Jellyfin /Library/Refresh.
set -euo pipefail

MEDIA_ROOT="${MEDIA_ROOT:-/data}"
API_HOST="${API_HOST:-127.0.0.1}"
RADARR_URL="${RADARR_URL:-http://${API_HOST}:7878}"
SONARR_URL="${SONARR_URL:-http://${API_HOST}:8989}"
JELLYFIN_URL="${JELLYFIN_URL:-http://jellyfin:8096}"
SABNZBD_URL="${SABNZBD_URL:-http://${API_HOST}:8085}"
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
QBIT_JAR=""
QBIT_BASE=""
_QBIT_LOGGED_IN=0

cleanup_purge() {
    if [ -n "${QBIT_JAR:-}" ] && [ -f "${QBIT_JAR:-}" ]; then
        rm -f "$QBIT_JAR"
    fi
}
trap cleanup_purge EXIT INT TERM

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

# "1,02 3" -> unique integers as lines. Empty / junk -> nothing.
parse_season_list() {
    local raw="${1:-}"
    [ -n "$raw" ] || return 0
    echo "$raw" | tr ',; ' '\n' | sed '/^$/d' | awk '
        /^[0-9]+$/ { v=int($0); print v }
    ' | sort -n | uniq
}

# Path under .../Season N/... or .../Specials/... -> season number. Else empty.
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

discover_sabnzbd_api_key() {
    if [ -n "${SABNZBD_API_KEY:-}" ]; then
        echo "$SABNZBD_API_KEY"
        return 0
    fi
    local f
    for f in \
        "${CONFIG_DIR:+$CONFIG_DIR/sabnzbd/sabnzbd.ini}" \
        "/config/sabnzbd/sabnzbd.ini" \
        "${INSTALL_DIR:+$INSTALL_DIR/config/sabnzbd/sabnzbd.ini}"; do
        [ -n "${f:-}" ] && [ -f "$f" ] || continue
        local k
        k=$(sed -n 's/^[[:space:]]*api_key[[:space:]]*=[[:space:]]*//p' "$f" 2>/dev/null | head -1 | tr -d '\r')
        if [ -n "$k" ]; then
            echo "$k"
            return 0
        fi
    done
    return 1
}

qbit_login() {
    local user pass
    if [ -n "${1:-}" ]; then
        QBIT_JAR="$1"
        _QBIT_LOGGED_IN=0
    fi
    if [ "$_QBIT_LOGGED_IN" -eq 1 ] && [ -n "${QBIT_JAR:-}" ] && [ -f "$QBIT_JAR" ]; then
        return 0
    fi

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

    if [ -z "${QBIT_JAR:-}" ]; then
        QBIT_JAR=$(mktemp "${TMPDIR:-/tmp}/media-purge-qb.XXXXXX")
    fi
    curl -s --connect-timeout 8 -c "$QBIT_JAR" \
        -H "Referer: ${QBIT_BASE}/" \
        --data-urlencode "username=${user}" \
        --data-urlencode "password=${pass}" \
        "${QBIT_BASE}/api/v2/auth/login" >/dev/null || true
    if ! curl -s --connect-timeout 5 -b "$QBIT_JAR" -H "Referer: ${QBIT_BASE}/" \
        "${QBIT_BASE}/api/v2/app/version" 2>/dev/null | grep -q .; then
        die "qBittorrent login failed (${QBIT_BASE})"
    fi
    _QBIT_LOGGED_IN=1
    log "qB session ok (${QBIT_BASE})"
}

qbit_torrents_info() {
    qbit_login ""
    curl -s --connect-timeout 10 -b "$QBIT_JAR" -H "Referer: ${QBIT_BASE}/" \
        "${QBIT_BASE}/api/v2/torrents/info" 2>/dev/null || echo "[]"
}

qbit_delete_hashes() {
    local hashes=("$@")
    [ "${#hashes[@]}" -gt 0 ] || return 0
    qbit_login ""
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
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 15 \
        -b "$QBIT_JAR" -H "Referer: ${QBIT_BASE}/" \
        -d "hashes=${csv}&deleteFiles=true" \
        "${QBIT_BASE}/api/v2/torrents/delete" 2>/dev/null || echo "000")
    log "qB: torrents/delete HTTP ${code}"
    PURGE_TOUCHED=1
}

# Title + year matcher shared by name fallback and leftover-dir cleanup.
# Example: "Alpha Film (2016)" matches "Alpha Film 2016 REPACK..." and
# "indexer.example - Alpha Film 2016 ..." because title tokens appear
# consecutively and the next token is that year, while rejecting unrelated sequels
# ("Alpha Film Sequel Extended (2022)") or longer titles ("Brief Story Extended").
QB_TITLE_YEAR_JQ=$(cat <<'JQ'
        def norm:
          ascii_downcase
          | gsub("\\\\"; "/")
          | gsub("['’]"; "")
          | gsub("[^a-z0-9]+"; " ")
          | gsub(" +"; " ")
          | gsub("^ +| +$"; "");
        def tokens($text):
          [($text | norm) | split(" ")[] | select(length > 0)];
        def basename_of($text):
          ($text | gsub("\\\\"; "/") | gsub("/+$"; "") | split("/")
            | map(select(length > 0)) | .[-1] // "");
        def is_year: test("^[0-9]{4}$");
        def is_season_tok:
          test("^s[0-9]{1,2}(e[0-9]{1,3})?$") or . == "season" or . == "specials";
        def parse_folder($folder):
          ($folder // "") as $raw
          | ([$raw | ascii_downcase | scan("\\(([0-9]{4})\\)")
              | if type == "array" then .[0] else . end]
              | .[-1] // "") as $paren_year
          | (tokens($raw | gsub("\\([0-9]{4}\\)"; " "))) as $words
          | if $paren_year != "" then
              {title: $words, year: $paren_year}
            elif (($words | length) > 0) and ($words[-1] | is_year) then
              {title: $words[0:-1], year: $words[-1]}
            else
              {title: $words, year: ""}
            end;
        def drop_articles($words):
          if ($words | length) > 1 and ($words[0] == "the" or $words[0] == "a" or $words[0] == "an")
          then $words[1:]
          else $words
          end;
        def find_title_then($toks; $title; $need_year):
          ($title | length) as $n
          | if $n == 0 then false
            else
              any(range(0; ($toks | length) - $n + 1);
                . as $i
                | $toks[$i:$i+$n] == $title
                and (
                  ($toks[$i+$n] // "") as $next
                  | if $need_year != "" then
                      $next == $need_year
                    else
                      $next == "" or ($next | is_season_tok) or ($next | is_year)
                    end
                )
              )
            end;
        def title_year_hit($text; $folder):
          if ($folder | length) == 0 or (($folder | norm | length) < 3) then false
          else
            parse_folder($folder) as $fk
            | tokens($text) as $toks
            | tokens(basename_of($text)) as $base
            | ($fk.title | length) > 0
            and (
              ($text | norm) == ($folder | norm)
              or (basename_of($text) | norm) == ($folder | norm)
              or any([$fk.title, drop_articles($fk.title)][];
                   . as $cand
                   | ($cand | length) > 0
                   and (find_title_then($toks; $cand; $fk.year)
                        or find_title_then($base; $cand; $fk.year))
                 )
            )
          end;
        def has_year: test("\\([0-9]{4}\\)") or test("(^| )[0-9]{4}$");
JQ
)

# stdin: qB torrents JSON; arg1: JSON string array of folder keys (prefer Title (YYYY)).
qb_match_jq() {
    jq -r --argjson tokens "$1" "${QB_TITLE_YEAR_JQ}"'
        ($tokens | map(select(length >= 3)) | unique) as $all
        | ([$all[] | select(has_year)]) as $yeared
        | (if ($yeared | length) > 0 then $yeared else $all end) as $use
        | .[]
        | . as $row
        | select(
            any($use[];
              title_year_hit($row.name // ""; .)
              or title_year_hit($row.content_path // ""; .)
            )
          )
        | .hash
    '
}

# Season-scoped matcher: title+year (or no-year title boundary) plus season
# tokens (with strict non-alphanumeric left boundaries so dts5/ps4/x265 do not
# trigger false seasons). Handles Specials (season 0) too. Refuse packs that
# also name a season we are not deleting (S01.S02 / S01-03 / Season 1-3).
qb_match_season_jq() {
    jq -r --arg folder "$1" --argjson seasons "$2" "${QB_TITLE_YEAR_JQ}"'
        def expand_range($a; $b):
          if $a <= $b then [range($a; $b + 1)] else [range($b; $a + 1)] end;
        def seasons_in($text):
          ($text | ascii_downcase) as $t
          | def nums($re):
              [ $t | scan($re) | if type == "array" then .[0] else . end | tonumber ];
          def ranges($re):
              [ $t | scan($re) | if type == "array" then expand_range(.[0]|tonumber; .[1]|tonumber)[] else empty end ];
          (
            ranges("(?:^|[^a-z0-9])s0*([0-9]{1,2})[[:space:]]*[-–][[:space:]]*s?0*([0-9]{1,2})(?=$|[^0-9])")
            + ranges("(?:^|[^a-z0-9])seasons?[[:space:]]*0*([0-9]{1,2})[[:space:]]*[-–][[:space:]]*0*([0-9]{1,2})(?=$|[^0-9])")
            + nums("(?:^|[^a-z0-9])s0*([0-9]{1,2})(?=e[0-9]{1,3}|$|[^0-9])")
            + nums("(?:^|[^a-z0-9])seasons?[[:space:]]*0*([0-9]{1,2})(?=$|[^0-9])")
            + (if ($t | test("(?:^|[^a-z0-9])specials(?=$|[^a-z0-9])")) then [0] else [] end)
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
              title_year_hit($row.name // ""; $folder)
              or title_year_hit($row.content_path // ""; $folder)
            )
          )
        | .hash
    '
}

# Keep *arr queue/history hashes that still exist in qB. The hash is identity —
# do not also require a folder-key name match. stdin: qB info JSON. args: hashes.
qbit_filter_hashes_jq() {
    local hashes_json
    hashes_json=$(printf '%s\n' "$@" | jq -R . | jq -s -c 'map(ascii_downcase | gsub("^ +| +$"; "")) | map(select(length > 0)) | unique')
    jq -r --argjson want "$hashes_json" '
        .[]
        | select((.hash | ascii_downcase) as $h | (($want | index($h)) != null))
        | .hash
    '
}

qbit_delete_by_folder_key() {
    local folder_key="$1"
    [ -n "$folder_key" ] || { log "qB: no folder key"; return 0; }

    local info hashes hash_count tokens_json
    info=$(qbit_torrents_info)
    if [ -n "$info" ] && [ "$info" != "[]" ]; then
        tokens_json=$(jq -nc --arg k "$folder_key" '[$k]')
        log "qB: folder key: $folder_key"
        hashes=$(echo "$info" | qb_match_jq "$tokens_json" 2>/dev/null || true)

        if [ -z "${hashes// }" ]; then
            log "qB: no torrents matched folder key"
        else
            hash_count=$(echo "$hashes" | grep -c . || true)
            if [ "${hash_count:-0}" -gt 1 ]; then
                log "qB: WARNING ${hash_count} torrents matched folder key (refusing multi-delete). hashes=$(echo "$hashes" | tr '\n' ' ')"
            else
                # shellcheck disable=SC2086
                qbit_delete_hashes $hashes
            fi
        fi
    else
        log "qB: no torrents (will still remove leftover download dirs)"
    fi
    remove_orphan_torrent_dirs "$folder_key"
}

# Clean up completed/incomplete torrent & usenet dirs left behind on disk.
remove_orphan_torrent_dirs() {
    local folder_key="$1"
    local seasons_json="${2:-}"
    local torrents_root="${MEDIA_ROOT:-/data}/torrents"
    local usenet_root="${MEDIA_ROOT:-/data}/usenet"
    local -a dirs=()
    [ -n "$folder_key" ] || return 0

    shopt -s nullglob
    if [ -d "$torrents_root/tv" ] || [ -d "$torrents_root/movies" ]; then
        dirs+=(
            "$torrents_root/tv"/* "$torrents_root/movies"/*
            "$torrents_root/incomplete/tv"/* "$torrents_root/incomplete/movies"/*
        )
    fi
    if [ -d "$usenet_root/complete" ] || [ -d "$usenet_root/incomplete" ]; then
        dirs+=(
            "$usenet_root/complete/tv"/* "$usenet_root/complete/movies"/*
            "$usenet_root/incomplete/tv"/* "$usenet_root/incomplete/movies"/*
            "$usenet_root/incomplete"/*
        )
    fi
    shopt -u nullglob

    [ "${#dirs[@]}" -gt 0 ] || return 0
    local d base info tokens_json hashes
    tokens_json=$(jq -nc --arg k "$folder_key" '[$k]')
    for d in "${dirs[@]}"; do
        [ -d "$d" ] || continue
        base=$(basename_of "$d")
        case "$base" in
            tv|movies|incomplete|complete|""|.) continue ;;
        esac
        info=$(jq -nc --arg n "$base" --arg p "$d" '[{hash:"fs",name:$n,content_path:$p}]')
        if [ -n "$seasons_json" ] && [ "$seasons_json" != "[]" ]; then
            hashes=$(echo "$info" | qb_match_season_jq "$folder_key" "$seasons_json" 2>/dev/null || true)
        else
            hashes=$(echo "$info" | qb_match_jq "$tokens_json" 2>/dev/null || true)
        fi
        [ -n "${hashes// }" ] || continue
        log "removing leftover download dir: $d"
        if [ "$DRY_RUN" = "1" ]; then
            log "DRY_RUN: skip rm $d"
            continue
        fi
        rm -rf -- "$d" && PURGE_TOUCHED=1
    done
}

qbit_delete_by_folder_key_seasons() {
    local folder_key="$1"
    local seasons_json="$2"
    [ -n "$folder_key" ] || { log "qB: no folder key"; return 0; }
    [ -n "$seasons_json" ] && [ "$seasons_json" != "[]" ] || { log "qB: no seasons"; return 0; }

    local info hashes hash_count
    info=$(qbit_torrents_info)
    if [ -n "$info" ] && [ "$info" != "[]" ]; then
        log "qB: folder key: $folder_key seasons: $seasons_json"
        hashes=$(echo "$info" | qb_match_season_jq "$folder_key" "$seasons_json" 2>/dev/null || true)

        if [ -z "${hashes// }" ]; then
            log "qB: no torrents matched folder key + seasons"
        else
            hash_count=$(echo "$hashes" | grep -c . || true)
            log "qB: ${hash_count} torrent(s) matched folder key + seasons"
            # shellcheck disable=SC2086
            qbit_delete_hashes $hashes
        fi
    else
        log "qB: no torrents (will still remove leftover download dirs)"
    fi
    remove_orphan_torrent_dirs "$folder_key" "$seasons_json"
}

qbit_delete_by_tokens() {
    local folder="" t b
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
                media|movies|tv|torrents|usenet|data|incomplete|complete|"") continue ;;
            esac
            if [ "${#b}" -ge 10 ]; then
                folder="$b"
                break
            fi
        done
    fi
    qbit_delete_by_folder_key "$folder"
}

# Best-effort SABnzbd queue/history deletion for matching SABnzbd_nzo_* IDs.
sabnzbd_delete_nzo_ids() {
    local nzo_ids=("$@")
    [ "${#nzo_ids[@]}" -gt 0 ] || return 0
    local sab_key
    sab_key=$(discover_sabnzbd_api_key 2>/dev/null || true)
    [ -n "$sab_key" ] || return 0

    local id
    for id in "${nzo_ids[@]}"; do
        [ -n "$id" ] || continue
        log "SABnzbd: deleting download ${id}"
        if [ "$DRY_RUN" = "1" ]; then
            log "DRY_RUN: skip SABnzbd delete ${id}"
            continue
        fi
        curl -sf --connect-timeout 5 --max-time 15 \
            "${SABNZBD_URL%/}/api?mode=queue&name=delete&del_files=1&value=${id}&apikey=${sab_key}&output=json" >/dev/null 2>&1 || true
        curl -sf --connect-timeout 5 --max-time 15 \
            "${SABNZBD_URL%/}/api?mode=history&name=delete&del_files=1&value=${id}&apikey=${sab_key}&output=json" >/dev/null 2>&1 || true
        PURGE_TOUCHED=1
    done
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

arr_queue_hashes() {
    local base="$1" key="$2" kind="$3" id="$4"
    local endpoint raw
    if [ "$kind" = "movie" ]; then
        endpoint="/api/v3/queue?pageSize=250&movieId=${id}"
        raw=$(arr_get "$base" "$key" "$endpoint")
        echo "$raw" | jq -r --argjson id "$id" '
            if type == "array" then .[]
            elif type == "object" then .records[]?
            else empty end
            | select((.movieId // empty) == ($id|tonumber))
            | .downloadId // .data.torrentInfoHash // empty
        ' 2>/dev/null | tr 'A-F' 'a-f' | sort -u
    else
        endpoint="/api/v3/queue?pageSize=250&seriesId=${id}"
        raw=$(arr_get "$base" "$key" "$endpoint")
        echo "$raw" | jq -r --argjson id "$id" '
            if type == "array" then .[]
            elif type == "object" then .records[]?
            else empty end
            | select((.seriesId // empty) == ($id|tonumber))
            | .downloadId // .data.torrentInfoHash // empty
        ' 2>/dev/null | tr 'A-F' 'a-f' | sort -u
    fi
}

arr_queue_hashes_seasons() {
    local base="$1" key="$2" id="$3" seasons_json="$4"
    local raw
    raw=$(arr_get "$base" "$key" "/api/v3/queue?pageSize=250&seriesId=${id}")
    echo "$raw" | jq -r --argjson id "$id" --argjson seasons "$seasons_json" '
        if type == "array" then .[]
        elif type == "object" then .records[]?
        else empty end
        | select((.seriesId // empty) == ($id|tonumber))
        | . as $r
        | ($r.episode.seasonNumber // $r.seasonNumber // empty) as $sn
        | select(($sn != null) and (($seasons | index($sn)) != null))
        | $r.downloadId // $r.data.torrentInfoHash // empty
    ' 2>/dev/null | tr 'A-F' 'a-f' | sort -u
}

arr_history_hashes_seasons() {
    local base="$1" key="$2" id="$3" seasons_json="$4"
    local hist
    hist=$(arr_get "$base" "$key" "/api/v3/history?pageSize=250&seriesId=${id}")
    echo "$hist" | jq -r --argjson seasons "$seasons_json" '
        .records[]? as $r
        | ($r.episode.seasonNumber // $r.data.seasonNumber // empty) as $sn
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

# Remaining seasons from Sonarr series + episodefile JSON (includes specials / 0).
seasons_remaining_json() {
    local series="${1:-}"
    local files="${2:-}"
    local out
    [ -n "$series" ] || series='{}'
    [ -n "$files" ] || files='[]'
    out=$(jq -nc --argjson series "$series" --argjson files "$files" '
        ([ $files[]? | select(.seasonNumber != null) | .seasonNumber ] | unique) as $on_disk
        | ([ $series.seasons[]? | select(.monitored == true) | .seasonNumber ] | unique) as $mon
        | ($on_disk + $mon) | unique | sort
    ' 2>/dev/null) || out='[]'
    [ -n "$out" ] || out='[]'
    printf '%s\n' "$out"
}

seasons_list_covers_remaining() {
    local seasons_json="$1"
    local remain_json="$2"
    jq -en --argjson seasons "$seasons_json" --argjson remain "$remain_json" '
        ($remain | length) > 0
        and (($remain - $seasons) | length) == 0
    ' >/dev/null 2>&1
}

seasons_cover_remaining() {
    local key="$1" id="$2" seasons_json="$3"
    local series files remain
    series=$(arr_get "$SONARR_URL" "$key" "/api/v3/series/${id}")
    files=$(arr_get "$SONARR_URL" "$key" "/api/v3/episodefile?seriesId=${id}")
    remain=$(seasons_remaining_json "$series" "${files:-[]}")
    seasons_list_covers_remaining "$seasons_json" "$remain"
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

arr_id_for_path() {
    local base="$1" key="$2" kind="$3" path="$4"
    local b json
    b=$(basename_of "$path")
    case "$b" in
        movies|tv|media|torrents|usenet|incomplete|complete|data|""|.) return 0 ;;
    esac
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
    local folder hlist=() qb_ids=() nzo_ids=() filtered=() info h

    folder=$(folder_key_from "$path" "$title")
    log "download purge kind=${kind} id=${id} folder_key=${folder:-<none>} seasons=${seasons_json:-<all>}"

    if [ -n "$seasons_json" ] && [ "$seasons_json" != "[]" ]; then
        while IFS= read -r h; do
            [ -n "$h" ] && hlist+=("$h")
        done < <(arr_queue_hashes_seasons "$base_url" "$key" "$id" "$seasons_json")
        while IFS= read -r h; do
            [ -n "$h" ] && hlist+=("$h")
        done < <(arr_history_hashes_seasons "$base_url" "$key" "$id" "$seasons_json")
    else
        while IFS= read -r h; do
            [ -n "$h" ] && hlist+=("$h")
        done < <(arr_queue_hashes "$base_url" "$key" "$kind" "$id")
        while IFS= read -r h; do
            [ -n "$h" ] && hlist+=("$h")
        done < <(arr_history_hashes "$base_url" "$key" "$kind" "$id")
    fi

    if [ "${#hlist[@]}" -gt 0 ]; then
        mapfile -t hlist < <(printf '%s\n' "${hlist[@]}" | awk 'NF && !seen[$0]++')
        for h in "${hlist[@]}"; do
            case "$h" in
                sabnzbd_nzo_*) nzo_ids+=("SABnzbd_nzo_${h#sabnzbd_nzo_}") ;;
                *) qb_ids+=("$h") ;;
            esac
        done
    fi

    if [ "${#nzo_ids[@]}" -gt 0 ]; then
        sabnzbd_delete_nzo_ids "${nzo_ids[@]}"
    fi

    if [ "${#qb_ids[@]}" -gt 0 ]; then
        log "${kind} queue/history qB candidates: ${qb_ids[*]}"
        info=$(qbit_torrents_info)
        while IFS= read -r h; do
            [ -n "$h" ] && filtered+=("$h")
        done < <(echo "$info" | qbit_filter_hashes_jq "${qb_ids[@]}" 2>/dev/null || true)

        if [ "${#filtered[@]}" -gt 0 ]; then
            log "qB: queue/history hashes in qB (${#filtered[@]}): ${filtered[*]}"
            qbit_delete_hashes "${filtered[@]}"
            remove_orphan_torrent_dirs "$folder" "$seasons_json"
            return 0
        fi
        log "qB: queue/history hashes not in qB; trying title+year match"
    else
        log "no qB queue/history hashes for ${kind} ${id}"
    fi

    if [ -n "$folder" ]; then
        if [ -n "$seasons_json" ] && [ "$seasons_json" != "[]" ]; then
            qbit_delete_by_folder_key_seasons "$folder" "$seasons_json"
        else
            qbit_delete_by_folder_key "$folder"
        fi
    else
        log "qB: skip name fallback (no safe folder key)"
    fi
}

purge_qb_for_movie() {
    purge_qb movie "$RADARR_URL" "$1" "$2" "$3" "$4"
}

purge_qb_for_series() {
    purge_qb series "$SONARR_URL" "$1" "$2" "$3" "$4" "${5:-}"
}

# Best-effort Jellyfin library refresh so deletes do not leave ghost items.
notify_jellyfin() {
    if [ "$SKIP_JELLYFIN" = "1" ] || [ "$DRY_RUN" = "1" ]; then
        return 0
    fi
    if [ "$PURGE_TOUCHED" != "1" ]; then
        return 0
    fi
    case "${MEDIA_SERVICE:-jellyfin}" in
        jellyfin|"") ;;
        *) log "media server ${MEDIA_SERVICE}: skip library refresh"; return 0 ;;
    esac

    local key="" auth_hdr tasks scan_state code
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

    auth_hdr="Authorization: MediaBrowser Client=\"assemblrr\", Device=\"media-purge\", DeviceId=\"assemblrr-purge\", Version=\"1.0\", Token=\"${key}\""

    # Never cancel an active RefreshLibrary scan in Jellyfin 12
    tasks=$(curl -sS --connect-timeout 5 --max-time 10 \
        -H "$auth_hdr" \
        "${JELLYFIN_URL%/}/ScheduledTasks" 2>/dev/null || echo "")
    scan_state=$(printf '%s' "$tasks" | jq -r \
        '([.[]? | select(.Key == "RefreshLibrary") | .State] | first) // "Idle"' \
        2>/dev/null || echo "Idle")
    case "$scan_state" in
        Running|Cancelling)
            log "Jellyfin: scan already ${scan_state}, skipping /Library/Refresh"
            return 0
            ;;
    esac

    code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 8 \
        -X POST -H "$auth_hdr" "${JELLYFIN_URL%/}/Library/Refresh" 2>/dev/null || echo "000")
    if [ "$code" -ge 200 ] && [ "$code" -lt 300 ]; then
        log "Jellyfin: library refresh triggered (HTTP ${code})"
    else
        log "Jellyfin: library refresh failed (HTTP ${code})"
    fi
}

run_movie_purge() {
    local mid="$1"
    [ -n "$mid" ] || die "--movie-id required"
    [ -n "$RADARR_API_KEY" ] || die "Radarr API key missing"
    local movie title path
    movie=$(arr_get "$RADARR_URL" "$RADARR_API_KEY" "/api/v3/movie/${mid}")
    title=$(echo "$movie" | jq -r '.title // empty')
    path=$(echo "$movie" | jq -r '.path // empty')
    purge_qb_for_movie "$RADARR_API_KEY" "$mid" "$title" "$path"
    if [ "$QB_ONLY" != "1" ]; then
        arr_delete_movie "$RADARR_API_KEY" "$mid"
    fi
}

run_series_purge() {
    local sid="$1"
    [ -n "$sid" ] || die "--series-id required"
    [ -n "$SONARR_API_KEY" ] || die "Sonarr API key missing"
    local series title path season_lines seasons_json
    series=$(arr_get "$SONARR_URL" "$SONARR_API_KEY" "/api/v3/series/${sid}")
    title=$(echo "$series" | jq -r '.title // empty')
    path=$(echo "$series" | jq -r '.path // empty')
    season_lines=$(parse_season_list "$SEASONS")
    if [ -n "$season_lines" ]; then
        seasons_json=$(seasons_json_from_list "$season_lines")
        log "series ${sid} season-scoped ${seasons_json}"
        purge_qb_for_series "$SONARR_API_KEY" "$sid" "$title" "$path" "$seasons_json"
        if [ "$QB_ONLY" != "1" ]; then
            if seasons_cover_remaining "$SONARR_API_KEY" "$sid" "$seasons_json"; then
                log "requested seasons cover remaining library; deleting series"
                arr_delete_series "$SONARR_API_KEY" "$sid"
            else
                arr_delete_series_seasons "$SONARR_API_KEY" "$sid" "$seasons_json"
            fi
        fi
    else
        purge_qb_for_series "$SONARR_API_KEY" "$sid" "$title" "$path"
        if [ "$QB_ONLY" != "1" ]; then
            arr_delete_series "$SONARR_API_KEY" "$sid"
        fi
    fi
}

# --- sourced by unit tests: stop here ---
if [ "${MEDIA_PURGE_SOURCE_ONLY:-0}" = "1" ]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || exit 0
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
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
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
        run_movie_purge "$MOVIE_ID"
        ;;
    series)
        run_series_purge "$SERIES_ID"
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
        run_movie_purge "$mid"
        ;;
    tvdb)
        [ -n "$TVDB_ID" ] || die "--tvdb required"
        [ -n "$SONARR_API_KEY" ] || die "Sonarr API key missing"
        series_json=$(arr_get "$SONARR_URL" "$SONARR_API_KEY" "/api/v3/series")
        sid=$(echo "$series_json" | jq -r --argjson t "$TVDB_ID" '.[] | select(.tvdbId == $t) | .id' | head -1)
        [ -n "$sid" ] || die "no Sonarr series tvdbId=${TVDB_ID}"
        run_series_purge "$sid"
        ;;
    *)
        die "specify --movie-id, --series-id, --path, --tmdb, --tvdb, --radarr-event, or --sonarr-event"
        ;;
esac

if [ "$QB_ONLY" != "1" ]; then
    notify_jellyfin
fi
log "done"
