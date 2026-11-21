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

test_summary
