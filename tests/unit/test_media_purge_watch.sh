#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# media-purge-watch ignore / video / folder-key / hold helpers (synthetic titles only)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../helpers.sh"

PURGE_WATCH_SOURCE_ONLY=1
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/media-purge-watch.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

test_suite "purge_watch_is_ignored"
assert_true "write test" "purge_watch_is_ignored /data/media/movies/radarr_write_test.txt"
assert_true "sonarr write test" "purge_watch_is_ignored /data/media/tv/sonarr_write_test.txt"
assert_true "partial" "purge_watch_is_ignored /data/media/movies/SampleTitle/file.mkv.part"
assert_true "nfs" "purge_watch_is_ignored /data/media/movies/.nfs123"
assert_false "real mkv" "purge_watch_is_ignored '/data/media/movies/Sample Movie (2012)/movie.mkv'"

test_suite "purge_watch_is_video & folder_has_video parity"
assert_true "mkv" "purge_watch_is_video /data/media/movies/x/a.mkv"
assert_true "MP4 case" "purge_watch_is_video /data/media/movies/x/A.MP4"
assert_true "wmv video" "purge_watch_is_video /data/media/movies/x/a.wmv"
assert_true "mpg video" "purge_watch_is_video /data/media/movies/x/a.mpg"
assert_false "txt" "purge_watch_is_video /data/media/movies/x/note.txt"
assert_false "nfo" "purge_watch_is_video /data/media/movies/x/movie.nfo"
assert_false "srt" "purge_watch_is_video /data/media/movies/x/movie.en.srt"
_vdir="$tmp/wmv-check"
mkdir -p "$_vdir"
: > "$_vdir/sample.wmv"
assert_true "folder_has_video detects wmv too" "purge_watch_folder_has_video '$_vdir'"

test_suite "purge_watch_library_folder & kind"
assert_eq "/data/media/movies/Sample Movie (2012)" \
    "$(purge_watch_library_folder '/data/media/movies/Sample Movie (2012)/file.mkv')" \
    "movie title dir"
assert_eq "movie" \
    "$(purge_watch_library_kind '/data/media/movies/Sample Movie (2012)/file.mkv')" \
    "movie kind"
assert_eq "/data/media/tv/Show Name" \
    "$(purge_watch_library_folder '/data/media/tv/Show Name/Season 01/ep.mkv')" \
    "series title dir"
assert_eq "tv" \
    "$(purge_watch_library_kind '/data/media/tv/Show Name')" \
    "tv kind at title folder root"
assert_eq "" "$(purge_watch_library_folder /data/torrents/movies/x.mkv)" "torrents path ignored"

test_suite "purge_watch_folder_busy"
busy="$tmp/busy-title"
mkdir -p "$busy"
assert_false "empty folder is not busy" "purge_watch_folder_busy '$busy'"
: > "$busy/copying.mkv.part"
assert_true "partial file is busy" "purge_watch_folder_busy '$busy'"
rm -f "$busy/copying.mkv.part"
: > "$busy/movie.mkv"
assert_true "video is busy" "purge_watch_folder_busy '$busy'"

test_suite "purge_watch_json_has_upgrade_delete"
_now=1760000600
_recent_iso=$(date -u -d "@$((_now - 60))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || python3 -c "import datetime; print(datetime.datetime.fromtimestamp($_now - 60, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")
_old_iso=$(date -u -d "@$((_now - 3600))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || python3 -c "import datetime; print(datetime.datetime.fromtimestamp($_now - 3600, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")
upg_nodate='{"records":[{"eventType":"movieFileDeleted","data":{"reason":"Upgrade"}}]}'
upg_recent="{\"records\":[{\"date\":\"${_recent_iso}\",\"eventType\":\"movieFileDeleted\",\"data\":{\"reason\":\"Upgrade\"}}]}"
upg_stale="{\"records\":[{\"date\":\"${_old_iso}\",\"eventType\":\"movieFileDeleted\",\"data\":{\"reason\":\"Upgrade\"}}]}"
manual='{"records":[{"eventType":"movieFileDeleted","data":{"reason":"Manual"}}]}'
assert_success "upgrade delete without date is a hold" purge_watch_json_has_upgrade_delete "$upg_nodate" "$_now" 600
assert_success "recent upgrade delete is a hold" purge_watch_json_has_upgrade_delete "$upg_recent" "$_now" 600
assert_failure "stale upgrade delete (1h ago) does not hold forever" purge_watch_json_has_upgrade_delete "$upg_stale" "$_now" 600
assert_failure "manual delete is not a hold" purge_watch_json_has_upgrade_delete "$manual" "$_now" 600

test_suite "purge_watch_queue_mentions_id"
q='{"records":[{"movieId":12},{"movieId":99}]}'
assert_success "queued movie is a hold" purge_watch_queue_mentions_id "$q" movieId 12
assert_failure "other movie is not queued" purge_watch_queue_mentions_id "$q" movieId 3

test_suite "purge_watch_season_number"
assert_eq "2" "$(purge_watch_season_number '/data/media/tv/Show Name/Season 2/ep.mkv')" "Season 2 file"
assert_eq "1" "$(purge_watch_season_number '/data/media/tv/Show Name/Season 01/ep.mkv')" "Season 01 file"
assert_eq "0" "$(purge_watch_season_number '/data/media/tv/Show Name/Specials/ep.mkv')" "Specials"
assert_eq "" "$(purge_watch_season_number '/data/media/tv/Show Name/ep.mkv')" "no season folder"
assert_eq "" "$(purge_watch_season_number '/data/media/movies/Title (2012)/movie.mkv')" "movie path"

test_suite "purge_watch recycle and title-folder events"
assert_true "recycle path ignored" \
    "purge_watch_is_ignored '/data/media/.recycle/Sample Show'"
assert_true "recycle file ignored" \
    "purge_watch_is_ignored '/data/media/.recycle/Sample Show/Season 2/ep.mkv'"
assert_true "tv title folder" \
    "purge_watch_is_title_folder '/data/media/tv/Sample Show'"
assert_true "movie title folder" \
    "purge_watch_is_title_folder '/data/media/movies/Title (2012)'"
assert_false "episode path is not the title folder" \
    "purge_watch_is_title_folder '/data/media/tv/Sample Show/Season 2/ep.mkv'"

test_suite "purge_watch whole-TV-show hold uses Sonarr, not Radarr"
assert_contains "$(sed -n '/^purge_watch_arr_hold()/,/^}/p' "$REPO_ROOT/scripts/media-purge-watch.sh")" \
    'purge_watch_library_kind' "hold infers TV vs movie from library path when season is empty"
assert_not_contains "$(cat "$REPO_ROOT/scripts/media-purge-watch.sh")" \
    'chmod +x' "no chmod +x on read-only script mount"

test_summary
