#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Unit tests for media-purge matcher, season scoping, and download dir cleanup (synthetic titles only).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../helpers.sh"

MEDIA_PURGE_SOURCE_ONLY=1
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/media-purge.sh"

check_match() {
    local want="$1" name="$2" tokens="$3" torrents="$4"
    local got
    got=$(echo "$torrents" | qb_match_jq "$tokens" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    assert_eq "$want" "$got" "$name"
}

check_filter() {
    local want="$1" name="$2" torrents="$3"
    shift 3
    local got
    got=$(echo "$torrents" | qbit_filter_hashes_jq "$@" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    assert_eq "$want" "$got" "$name"
}

check_season() {
    local want="$1" name="$2" folder="$3" seasons="$4" torrents="$5"
    local got
    got=$(echo "$torrents" | qb_match_season_jq "$folder" "$seasons" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    assert_eq "$want" "$got" "$name"
}

check_cover() {
    local want="$1" name="$2" seasons="$3" series="$4" files="$5"
    local remain got
    remain=$(seasons_remaining_json "$series" "$files")
    if seasons_list_covers_remaining "$seasons" "$remain"; then
        got="cover"
    else
        got="partial"
    fi
    assert_eq "$want" "$got" "$name"
}

test_suite "media-purge qB title+year match (synthetic titles)"
check_match "hash_a" "year folder hits only first film" \
    '["Alpha Film (2016)"]' \
    '[{"hash":"hash_a","name":"Alpha Film (2016) [GRP]","content_path":"/data/torrents/movies/Alpha Film (2016)"},{"hash":"hash_b","name":"Alpha Film Sequel Extended (2022)","content_path":"/data/torrents/movies/Alpha Film Sequel Extended (2022)"}]'
check_match "" "bare short title does not hit longer sequel name" \
    '["Alpha Film"]' \
    '[{"hash":"hash_b","name":"Alpha Film Sequel Extended (2022)","content_path":"/data/torrents/movies/Alpha Film Sequel Extended (2022)"}]'
check_match "hash_a" "bare short title hits exact name only" \
    '["Alpha Film"]' \
    '[{"hash":"hash_a","name":"Alpha Film","content_path":"/data/torrents/movies/Alpha Film"},{"hash":"hash_b","name":"Alpha Film Sequel Extended","content_path":"/data/torrents/movies/Alpha Film Sequel Extended"}]'
check_match "hash_y" "year preferred when bare+year present" \
    '["Sample Title","Sample Title (2008)"]' \
    '[{"hash":"hash_y","name":"Sample Title (2008) [e2e]","content_path":"/data/torrents/movies/Sample Title (2008) [e2e]"},{"hash":"hash_z","name":"Sample Title Adventures","content_path":"/data/torrents/movies/Sample Title Adventures"}]'
check_match "hash_m1" "bare title does not hit same-prefix sequel" \
    '["Beta Movie"]' \
    '[{"hash":"hash_m1","name":"Beta Movie","content_path":"/data/torrents/movies/Beta Movie"},{"hash":"hash_m2","name":"Beta Movie Reloaded","content_path":"/data/torrents/movies/Beta Movie Reloaded"}]'
check_match "hash_p1" "title+year hits release name with indexer prefix" \
    '["The Horizon (2012)"]' \
    '[{"hash":"hash_p1","name":"The Horizon 2012 REPACK 1080p DDP 5 1 x264-grp","content_path":"/data/torrents/incomplete/movies/indexer.example    -    The Horizon 2012 REPACK 1080p DDP 5 1 x264-grp"}]'
check_match "hash_p2" "title+year hits indexer-prefixed incomplete path" \
    '["The Horizon (2012)"]' \
    '[{"hash":"hash_p2","name":"indexer.example - The Horizon 2012 REPACK","content_path":"/data/torrents/incomplete/movies/indexer.example - The Horizon 2012 REPACK"}]'
check_match "" "title+year does not hit sequel with different year" \
    '["The Horizon (2012)"]' \
    '[{"hash":"hash_u","name":"Horizon Chapter Two 2015 1080p","content_path":"/data/torrents/movies/Horizon Chapter Two 2015 1080p"}]'
check_match "" "short title+year does not hit longer title sharing first word" \
    '["Nova (2017)"]' \
    '[{"hash":"hash_n","name":"Nova Comes at Night 2017 1080p","content_path":"/data/torrents/movies/Nova Comes at Night 2017"}]'
check_match "hash_it" "short title+year hits exact short title release" \
    '["Nova (2017)"]' \
    '[{"hash":"hash_it","name":"Nova 2017 1080p REMUX","content_path":"/data/torrents/movies/Nova 2017 1080p REMUX"}]'
check_match "hash_bb" "article-stripped title still needs the year next" \
    '["The Horizon (2012)"]' \
    '[{"hash":"hash_bb","name":"Horizon 2012 1080p","content_path":"/data/torrents/movies/Horizon 2012 1080p"}]'

test_suite "media-purge qbit_filter_hashes_jq"
check_filter "hash_a" "history filter keeps live hash even when name is a release" \
    '[{"hash":"hash_a","name":"The Horizon 2012 REPACK","content_path":"/data/torrents/incomplete/movies/The Horizon 2012 REPACK"},{"hash":"hash_b","name":"Other Title","content_path":"/data/torrents/movies/Other"}]' \
    hash_a
check_filter "hash_a" "history filter keeps every live candidate hash" \
    '[{"hash":"hash_a","name":"Alpha Film Sequel Extended (2022)","content_path":"/data/torrents/movies/Alpha Film Sequel Extended (2022)"}]' \
    hash_a hash_b
check_filter "" "history filter drops hashes not in qB" \
    '[{"hash":"hash_b","name":"Other","content_path":"/x"}]' \
    hash_a

test_suite "media-purge season-scoped matcher + boundary safety"
check_season "hash_s1" "S01 pack matches season 1 only" \
    "Sample Show" '[1]' \
    '[{"hash":"hash_s1","name":"Sample.Show.S01.COMPLETE.1080p","content_path":"/data/torrents/tv/Sample.Show.S01.COMPLETE.1080p"},{"hash":"hash_s2","name":"Sample.Show.S02.COMPLETE.1080p","content_path":"/data/torrents/tv/Sample.Show.S02.COMPLETE.1080p"}]'
check_season "" "S02 pack is not deleted with season 1" \
    "Sample Show" '[1]' \
    '[{"hash":"hash_s2","name":"Sample.Show.S02.COMPLETE.1080p.WEB-DL","content_path":"/data/torrents/tv/Sample.Show.S02.COMPLETE.1080p.WEB-DL"}]'
check_season "" "multi-season pack refused when deleting S01 only" \
    "Sample Show" '[1]' \
    '[{"hash":"hash_both","name":"Sample.Show.S01.S02.COMPLETE","content_path":"/data/torrents/tv/Sample.Show.S01.S02.COMPLETE"}]'
check_season "" "no season token is skipped (under-delete)" \
    "Sample Show" '[1]' \
    '[{"hash":"hash_bare","name":"Sample Show","content_path":"/data/torrents/tv/Sample Show"}]'
check_season "" "other show S01 is not matched" \
    "Sample Show" '[1]' \
    '[{"hash":"hash_x","name":"Other Show.S01.COMPLETE","content_path":"/data/torrents/tv/Other Show.S01.COMPLETE"}]'
check_season "" "S01-03 range pack refused when deleting S01 only" \
    "Sample Show" '[1]' \
    '[{"hash":"hash_r","name":"Sample.Show.S01-03.COMPLETE","content_path":"/data/torrents/tv/Sample.Show.S01-03.COMPLETE"}]'
check_season "" "Season 1-3 range pack refused when deleting S01 only" \
    "Sample Show" '[1]' \
    '[{"hash":"hash_r2","name":"Sample Show Season 1-3","content_path":"/data/torrents/tv/Sample Show Season 1-3"}]'
check_season "" "short folder key does not match unrelated S01 torrent" \
    "Oz" '[1]' \
    '[{"hash":"hash_oz","name":"Other.S01.COMPLETE","content_path":"/data/torrents/tv/Other.S01.COMPLETE"}]'
check_season "" "Echo does not match Echo in Space S01" \
    "Echo" '[1]' \
    '[{"hash":"hash_lis","name":"Echo in Space.S01.COMPLETE","content_path":"/data/torrents/tv/Echo in Space.S01.COMPLETE"}]'
check_season "hash_e1 hash_e2" "multiple S01E0x torrents all match" \
    "Sample Show" '[1]' \
    '[{"hash":"hash_e1","name":"Sample.Show.S01E01","content_path":"/data/torrents/tv/Sample.Show.S01E01"},{"hash":"hash_e2","name":"Sample.Show.S01E02","content_path":"/data/torrents/tv/Sample.Show.S01E02"}]'
check_match "hash_s2" "title-level Sample Show matches S02 complete pack" \
    '["Sample Show"]' \
    '[{"hash":"hash_s2","name":"Sample.Show.S02.COMPLETE.1080p.WEB-DL","content_path":"/data/torrents/tv/Sample.Show.S02.COMPLETE.1080p.WEB-DL"}]'
check_match "" "title-level Echo does not match Echo in Space pack" \
    '["Echo"]' \
    '[{"hash":"hash_lis","name":"Echo in Space.S01.COMPLETE","content_path":"/data/torrents/tv/Echo in Space.S01.COMPLETE"}]'
check_season "hash_dts" "dts5 / ps4 / x265 do not invent bogus seasons 5/4/26" \
    "Sample Show" '[1]' \
    '[{"hash":"hash_dts","name":"Sample.Show.S01.1080p.DTS5.1.x265-GRP","content_path":"/data/torrents/tv/Sample.Show.S01.1080p.DTS5.1.x265-GRP"}]'
check_season "hash_sp" "Specials pack matches season 0" \
    "Sample Show" '[0]' \
    '[{"hash":"hash_sp","name":"Sample.Show.Specials.1080p","content_path":"/data/torrents/tv/Sample.Show.Specials.1080p"}]'

test_suite "media-purge remaining-season cover"
_series_s01s02='{"seasons":[{"seasonNumber":1,"monitored":true},{"seasonNumber":2,"monitored":true}]}'
_files_s01s02='[{"seasonNumber":1},{"seasonNumber":2}]'
_series_s01_spec='{"seasons":[{"seasonNumber":0,"monitored":true},{"seasonNumber":1,"monitored":true}]}'
_files_s01_spec='[{"seasonNumber":0},{"seasonNumber":1}]'
_series_spec_only='{"seasons":[{"seasonNumber":0,"monitored":true}]}'
_files_spec_only='[{"seasonNumber":0}]'
check_cover "partial" "S01 request does not cover S01+S02" '[1]' "$_series_s01s02" "$_files_s01s02"
check_cover "cover" "S01+S02 request covers S01+S02" '[1,2]' "$_series_s01s02" "$_files_s01s02"
check_cover "partial" "S01 request does not cover S01+specials" '[1]' "$_series_s01_spec" "$_files_s01_spec"
check_cover "cover" "S01+specials request covers both" '[0,1]' "$_series_s01_spec" "$_files_s01_spec"
check_cover "partial" "S01 request does not cover specials-only leftover" '[1]' "$_series_spec_only" "$_files_spec_only"
check_cover "cover" "specials request covers specials-only leftover" '[0]' "$_series_spec_only" "$_files_spec_only"

test_suite "media-purge leftover torrent & usenet dirs + script hygiene"
MEDIA_ROOT=$(mktemp -d)
trap 'rm -rf "$MEDIA_ROOT"' EXIT
mkdir -p "$MEDIA_ROOT/torrents/tv/Sample.Show.S02.COMPLETE.1080p.WEB-DL" \
         "$MEDIA_ROOT/torrents/tv/Echo in Space.S01.COMPLETE" \
         "$MEDIA_ROOT/torrents/incomplete/movies/indexer.example - The Horizon 2012 REPACK" \
         "$MEDIA_ROOT/torrents/movies/Horizon Chapter Two 2015 1080p" \
         "$MEDIA_ROOT/usenet/complete/movies/The.Horizon.2012.1080p.WEB"
DRY_RUN=0
remove_orphan_torrent_dirs "Sample Show"
assert_false "Sample Show leftover pack dir removed" "[ -d '$MEDIA_ROOT/torrents/tv/Sample.Show.S02.COMPLETE.1080p.WEB-DL' ]"
assert_true "Echo in Space leftover left alone" "[ -d '$MEDIA_ROOT/torrents/tv/Echo in Space.S01.COMPLETE' ]"
remove_orphan_torrent_dirs "The Horizon (2012)"
assert_false "The Horizon incomplete torrent dir removed" "[ -d '$MEDIA_ROOT/torrents/incomplete/movies/indexer.example - The Horizon 2012 REPACK' ]"
assert_false "The Horizon usenet complete dir removed" "[ -d '$MEDIA_ROOT/usenet/complete/movies/The.Horizon.2012.1080p.WEB' ]"
assert_true "Horizon Chapter Two leftover left alone" "[ -d '$MEDIA_ROOT/torrents/movies/Horizon Chapter Two 2015 1080p' ]"

_mp_src=$(cat "$REPO_ROOT/scripts/media-purge.sh")
assert_not_contains "$_mp_src" 'exec "$0"' "--tmdb / --tvdb do not re-exec and drop --dry-run"
assert_contains "$_mp_src" 'Authorization: MediaBrowser' "notify_jellyfin uses MediaBrowser header"
assert_not_contains "$_mp_src" 'X-Emby-Token' "notify_jellyfin does not use legacy X-Emby-Token"

test_summary
