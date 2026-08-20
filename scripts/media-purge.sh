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
#   1) *arr queue + history download hashes that still exist in qB (hash is identity)
#   2) Title + year match on torrent name / content path (The Avengers (2012) ==
#      The Avengers 2012 REPACK…; indexer prefixes allowed; next token after the
#      title must be that year). No-year keys still require a season/year/end
#      boundary so Lost does not hit Lost in Space.
#   3) Never bare short titles (len < 3). Refuse ambiguous multi-matches on
#      the name step. Season purge still refuses packs / other seasons.
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
        --data-urlencode "username=${user}" \
        --data-urlencode "password=${pass}" \
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

# Title + year matcher shared by name fallback and leftover-dir cleanup.
# A movie key "The Avengers (2012)" hits "The Avengers 2012 REPACK…" and
# "www.UIndex.org - The Avengers 2012 …" because the title tokens appear
# consecutively and the next token is that year. It does not hit Age of Ultron
# (next token is not 2012) or "It Comes at Night" for It (2017).
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
# tokens. Refuse packs that also name a season we are not deleting
# (S01.S02 / S01-03 / Season 1-3). No season token → skip (under-delete).
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
              title_year_hit($row.name // ""; $folder)
              or title_year_hit($row.content_path // ""; $folder)
            )
          )
        | .hash
    '
}

# Keep *arr queue/history hashes that still exist in qB. The hash is identity —
# do not also require a folder-key name match (release names rarely look like
# "Title (YYYY)"). stdin: qB info JSON. args: candidate hashes.
qbit_filter_hashes_jq() {
    local hashes_json
    # Lowercase/trim only — do not strip non-hex (breaks tests and rare non-standard ids).
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

# *arr Completed Download Handling often removes the qB item but leaves
# torrents/tv|movies/<release>. Title-delete then finds no qB row.
remove_orphan_torrent_dirs() {
    local folder_key="$1"
    local seasons_json="${2:-}"
    local root="${MEDIA_ROOT:-/data}/torrents"
    local d base info tokens_json hashes
    [ -n "$folder_key" ] || return 0
    [ -d "$root/tv" ] || [ -d "$root/movies" ] || return 0

    tokens_json=$(jq -nc --arg k "$folder_key" '[$k]')
    shopt -s nullglob
    for d in "$root/tv"/* "$root/movies"/* \
             "$root/incomplete/tv"/* "$root/incomplete/movies"/*; do
        [ -d "$d" ] || continue
        base=$(basename_of "$d")
        case "$base" in
            tv|movies|incomplete|""|.) continue ;;
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
    shopt -u nullglob
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

# Active *arr queue download hashes (in-progress grabs). Hash is identity.
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
        | (
            $r.episode.seasonNumber
            // $r.seasonNumber
            // empty
          ) as $sn
        | select(($sn != null) and (($seasons | index($sn)) != null))
        | $r.downloadId // $r.data.torrentInfoHash // empty
    ' 2>/dev/null | tr 'A-F' 'a-f' | sort -u
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

# Remaining seasons from Sonarr series + episodefile JSON (includes specials / 0).
# Used to decide series delete vs season-scoped delete.
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

# True when this season list covers every remaining on-disk / monitored season
# (specials/0 count; deleting S01 must not wipe Specials).
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
    case "$b" in
        movies|tv|media|torrents|incomplete|data|""|.) return 0 ;;
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
    local folder hlist=() filtered=() info h

    folder=$(folder_key_from "$path" "$title")
    log "qB purge kind=${kind} id=${id} folder_key=${folder:-<none>} seasons=${seasons_json:-<all>}"

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
        # Unique, keep order
        hlist=($(printf '%s\n' "${hlist[@]}" | awk 'NF && !seen[$0]++'))
    fi

    if [ "${#hlist[@]}" -gt 0 ]; then
        log "${kind} queue/history candidates: ${hlist[*]}"
        info=$(qbit_torrents_info)
        while IFS= read -r h; do
            [ -n "$h" ] && filtered+=("$h")
        done < <(echo "$info" | qbit_filter_hashes_jq "${hlist[@]}" 2>/dev/null || true)

        if [ "${#filtered[@]}" -gt 0 ]; then
            log "qB: queue/history hashes in qB (${#filtered[@]}): ${filtered[*]}"
            qbit_delete_hashes "${filtered[@]}"
            remove_orphan_torrent_dirs "$folder" "$seasons_json"
        else
            log "qB: queue/history hashes not in qB; trying title+year match"
        fi
    else
        log "no queue/history hashes for ${kind} ${id}"
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
        local want="$1" name="$2" torrents="$3"
        shift 3
        local got
        got=$(echo "$torrents" | qbit_filter_hashes_jq "$@" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
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
    check_filter "hash_a" "history filter keeps live hash even when name is a release" \
        '[{"hash":"hash_a","name":"The Avengers 2012 REPACK BluRay","content_path":"/data/torrents/incomplete/movies/The Avengers 2012 REPACK BluRay"},{"hash":"hash_b","name":"Other Title","content_path":"/data/torrents/movies/Other"}]' \
        hash_a
    check_filter "hash_a" "history filter keeps every live candidate hash" \
        '[{"hash":"hash_a","name":"Alpha Film Sequel Extended (2022)","content_path":"/data/torrents/movies/Alpha Film Sequel Extended (2022)"}]' \
        hash_a hash_b
    check_filter "" "history filter drops hashes not in qB" \
        '[{"hash":"hash_b","name":"Other","content_path":"/x"}]' \
        hash_a
    check "hash_av" "title+year hits release name without parens" \
        '["The Avengers (2012)"]' \
        '[{"hash":"hash_av","name":"The Avengers 2012 REPACK BluRay 1080p DDP 5 1 x264-hallowed","content_path":"/data/torrents/incomplete/movies/www.UIndex.org    -    The Avengers 2012 REPACK BluRay 1080p DDP 5 1 x264-hallowed"}]'
    check "hash_av" "title+year hits indexer-prefixed incomplete path" \
        '["The Avengers (2012)"]' \
        '[{"hash":"hash_av","name":"www.UIndex.org - The Avengers 2012 REPACK","content_path":"/data/torrents/incomplete/movies/www.UIndex.org - The Avengers 2012 REPACK"}]'
    check "" "title+year does not hit Age of Ultron" \
        '["The Avengers (2012)"]' \
        '[{"hash":"hash_u","name":"Avengers Age of Ultron 2015 1080p","content_path":"/data/torrents/movies/Avengers Age of Ultron 2015 1080p"}]'
    check "" "short It (2017) does not hit It Comes at Night" \
        '["It (2017)"]' \
        '[{"hash":"hash_n","name":"It Comes at Night 2017 1080p","content_path":"/data/torrents/movies/It Comes at Night 2017"}]'
    check "hash_it" "It (2017) hits It 2017 release" \
        '["It (2017)"]' \
        '[{"hash":"hash_it","name":"It 2017 1080p BluRay","content_path":"/data/torrents/movies/It 2017 1080p BluRay"}]'
    check "hash_bb" "article-stripped title still needs the year next" \
        '["The Avengers (2012)"]' \
        '[{"hash":"hash_bb","name":"Avengers 2012 1080p","content_path":"/data/torrents/movies/Avengers 2012 1080p"}]'
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
    check "hash_s2" "title-level Loki matches S02 complete pack" \
        '["Loki"]' \
        '[{"hash":"hash_s2","name":"Loki.S02.COMPLETE.1080p.DSNP.WEB-DL","content_path":"/data/torrents/tv/Loki.S02.COMPLETE.1080p.DSNP.WEB-DL"}]'
    check "" "title-level Lost still does not match Lost in Space pack" \
        '["Lost"]' \
        '[{"hash":"hash_lis","name":"Lost in Space.S01.COMPLETE","content_path":"/data/torrents/tv/Lost in Space.S01.COMPLETE"}]'

    echo "=== media-purge remaining-season cover ==="
    cover_check() {
        local want="$1" name="$2" seasons="$3" series="$4" files="$5"
        local remain got
        remain=$(seasons_remaining_json "$series" "$files")
        if seasons_list_covers_remaining "$seasons" "$remain"; then
            got="cover"
        else
            got="partial"
        fi
        if [ "$got" = "$want" ]; then
            echo "  PASS: $name"
        else
            echo "  FAIL: $name (want='$want' got='$got' remain='$remain')"
            failures=$((failures + 1))
        fi
    }
    _series_s01s02='{"seasons":[{"seasonNumber":1,"monitored":true},{"seasonNumber":2,"monitored":true}]}'
    _files_s01s02='[{"seasonNumber":1},{"seasonNumber":2}]'
    _series_s01_spec='{"seasons":[{"seasonNumber":0,"monitored":true},{"seasonNumber":1,"monitored":true}]}'
    _files_s01_spec='[{"seasonNumber":0},{"seasonNumber":1}]'
    _series_spec_only='{"seasons":[{"seasonNumber":0,"monitored":true}]}'
    _files_spec_only='[{"seasonNumber":0}]'
    cover_check "partial" "S01 request does not cover S01+S02" \
        '[1]' "$_series_s01s02" "$_files_s01s02"
    cover_check "cover" "S01+S02 request covers S01+S02" \
        '[1,2]' "$_series_s01s02" "$_files_s01s02"
    cover_check "partial" "S01 request does not cover S01+specials" \
        '[1]' "$_series_s01_spec" "$_files_s01_spec"
    cover_check "cover" "S01+specials request covers both" \
        '[0,1]' "$_series_s01_spec" "$_files_s01_spec"
    cover_check "partial" "S01 request does not cover specials-only leftover" \
        '[1]' "$_series_spec_only" "$_files_spec_only"
    cover_check "cover" "specials request covers specials-only leftover" \
        '[0]' "$_series_spec_only" "$_files_spec_only"

    echo "=== media-purge leftover download dirs ==="
    _old_root="${MEDIA_ROOT:-}"
    MEDIA_ROOT=$(mktemp -d)
    mkdir -p "$MEDIA_ROOT/torrents/tv/Loki.S02.COMPLETE.1080p.DSNP.WEB-DL" \
             "$MEDIA_ROOT/torrents/tv/Lost in Space.S01.COMPLETE" \
             "$MEDIA_ROOT/torrents/incomplete/movies/www.UIndex.org - The Avengers 2012 REPACK BluRay" \
             "$MEDIA_ROOT/torrents/movies/Avengers Age of Ultron 2015 1080p"
    DRY_RUN=0
    remove_orphan_torrent_dirs "Loki"
    if [ ! -d "$MEDIA_ROOT/torrents/tv/Loki.S02.COMPLETE.1080p.DSNP.WEB-DL" ]; then
        echo "  PASS: Loki leftover pack dir removed"
    else
        echo "  FAIL: Loki leftover pack dir still present"
        failures=$((failures + 1))
    fi
    if [ -d "$MEDIA_ROOT/torrents/tv/Lost in Space.S01.COMPLETE" ]; then
        echo "  PASS: Lost in Space leftover left alone"
    else
        echo "  FAIL: Lost in Space leftover was removed"
        failures=$((failures + 1))
    fi
    remove_orphan_torrent_dirs "The Avengers (2012)"
    if [ ! -d "$MEDIA_ROOT/torrents/incomplete/movies/www.UIndex.org - The Avengers 2012 REPACK BluRay" ]; then
        echo "  PASS: Avengers incomplete leftover removed"
    else
        echo "  FAIL: Avengers incomplete leftover still present"
        failures=$((failures + 1))
    fi
    if [ -d "$MEDIA_ROOT/torrents/movies/Avengers Age of Ultron 2015 1080p" ]; then
        echo "  PASS: Age of Ultron leftover left alone"
    else
        echo "  FAIL: Age of Ultron leftover was removed"
        failures=$((failures + 1))
    fi
    rm -rf "$MEDIA_ROOT"
    MEDIA_ROOT="${_old_root}"

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
