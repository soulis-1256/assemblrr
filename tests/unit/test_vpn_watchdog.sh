#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Unit tests for scripts/vpn-watchdog.sh (cooldown & false-positive suppression)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../helpers.sh"

WATCHDOG_SOURCE_ONLY=1
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/vpn-watchdog.sh"

test_suite "watchdog_classify_torrent"
_props_broken='{"has_metadata":false,"nb_connections":0}'
_props_healthy='{"has_metadata":true,"nb_connections":4}'
_trk_broken='[{"status":4,"msg":"Operation not permitted"},{"status":4,"msg":"timed out"},{"status":4,"msg":"Host not found"}]'
_trk_healthy='[{"status":2,"msg":"OK"},{"status":4,"msg":"timed out"}]'
_trk_single_err='[{"status":4,"msg":"timed out"}]'

assert_eq "1 0" "$(watchdog_classify_torrent "$_props_broken" "$_trk_broken")" "broken metadata + 3 failed trackers"
assert_eq "0 1" "$(watchdog_classify_torrent "$_props_healthy" "$_trk_healthy")" "healthy connected + status 2 tracker"
assert_eq "0 0" "$(watchdog_classify_torrent "$_props_broken" "$_trk_single_err")" "single tracker error is not systemic routing break"

test_suite "watchdog_should_restart_vpn guards"
# Systemic failure, no working torrents, no prior restart -> restart
assert_success "global outage triggers restart" watchdog_should_restart_vpn 2 0 1000 0 300
# Single broken magnet while healthy torrents have active trackers/peers -> DO NOT restart
assert_failure "1 dead magnet + healthy torrent skips restart" watchdog_should_restart_vpn 1 3 1000 0 300
# Within cooldown (last restart 120s ago, cooldown 300s) -> DO NOT restart
assert_failure "cooldown prevents restart storm" watchdog_should_restart_vpn 2 0 1120 1000 300
# Cooldown elapsed (301s ago) -> restart allowed again
assert_success "cooldown elapsed allows restart" watchdog_should_restart_vpn 2 0 1301 1000 300

_wd_src=$(cat "$REPO_ROOT/scripts/vpn-watchdog.sh")
assert_not_contains "$_wd_src" 'api_get()' "renamed api_get to avoid collision"
assert_contains "$_wd_src" 'WATCHDOG_COOLDOWN_SEC' "cooldown wired"
assert_contains "$_wd_src" 'qbit_watchdog_cookie.txt' "uses persistent cookie jar across ticks"
# shellcheck disable=SC2016
assert_not_contains "$_wd_src" 'mktemp "${WATCHDOG_STATE_DIR%/}/qbit_watchdog_cookie' "does not allocate a fresh cookie jar every tick"
# shellcheck disable=SC2016
assert_contains "$_wd_src" 'if ! watchdog_cookie_has_sid "$COOKIE_JAR"' "reuses existing SID cookie before logging in"

_jar=$(mktemp)
printf '# Netscape HTTP Cookie File\n#HttpOnly_gluetun\tFALSE\t/\tFALSE\t1795288207\tQBT_SID_8081\tabc123\n' > "$_jar"
assert_success "accepts #HttpOnly_ QBT_SID_8081 cookie" watchdog_cookie_has_sid "$_jar"
printf '# Netscape HTTP Cookie File\ngluetun\tFALSE\t/\tFALSE\t1795288207\tSID\tlegacy123\n' > "$_jar"
assert_success "accepts legacy SID cookie" watchdog_cookie_has_sid "$_jar"
printf '# Netscape HTTP Cookie File\n# just a comment\ngluetun\tFALSE\t/\tFALSE\t1795288207\tOTHER\tval\n' > "$_jar"
assert_failure "rejects comment-only or unrelated cookie jar" watchdog_cookie_has_sid "$_jar"
rm -f "$_jar"

test_suite "watchdog_find_stalled_grabs identifies 0% 0-seed grabs past threshold"
_sample_torrents='[
  {"hash":"dead111","name":"StalledZero","state":"stalledDL","downloaded":0,"progress":0,"num_seeds":0,"dlspeed":0,"added_on":1000},
  {"hash":"meta222","name":"MetaZero","state":"metaDL","downloaded":0,"progress":0,"num_seeds":0,"dlspeed":0,"added_on":1050},
  {"hash":"fresh333","name":"FreshZero","state":"stalledDL","downloaded":0,"progress":0,"num_seeds":0,"dlspeed":0,"added_on":1150},
  {"hash":"part444","name":"PartialProgress","state":"stalledDL","downloaded":4096,"progress":0.05,"num_seeds":0,"dlspeed":0,"added_on":900},
  {"hash":"act555","name":"ActiveDownload","state":"downloading","downloaded":0,"progress":0,"num_seeds":3,"dlspeed":50000,"added_on":900}
]'
_stalled_out=$(watchdog_find_stalled_grabs "$_sample_torrents" 1250 180)
assert_contains "$_stalled_out" "dead111	StalledZero	250" "flags stalledDL at 0% with 0 seeds after 250s"
assert_contains "$_stalled_out" "meta222	MetaZero	200" "flags metaDL at 0% with 0 seeds after 200s"
assert_not_contains "$_stalled_out" "fresh333" "skips grab younger than threshold (100s < 180s)"
assert_not_contains "$_stalled_out" "part444" "skips torrent that already downloaded data"
assert_not_contains "$_stalled_out" "act555" "skips active downloading torrent with seeds"

test_suite "watchdog_find_corrupted_trackers strips zero-width chars once"
_corrupt_tr=$(printf '[{"url":"udp://192.0.2.1:6969/announ\\u200bce"},{"url":"udp://198.51.100.1:6969/ann\\u200bounce"},{"url":"udp://198.51.100.1:6969/announce"}]')
_clean_out=$(watchdog_find_corrupted_trackers "$_corrupt_tr")
assert_contains "$_clean_out" "udp://192.0.2.1:6969/announce" "emits cleaned tracker URL when not present yet"
assert_not_contains "$_clean_out" "198.51.100.1" "skips corrupted URL when clean counterpart already exists"

test_summary
