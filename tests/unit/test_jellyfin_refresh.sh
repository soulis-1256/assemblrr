#!/bin/bash
# jellyfin-refresh helpers + *arr notification payload flags
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../helpers.sh"

JF_REFRESH_SOURCE_ONLY=1
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/jellyfin-refresh.sh"

test_suite "jf_refresh_scan_state"
assert_eq "Running" \
    "$(jf_refresh_scan_state '[{"Key":"RefreshLibrary","State":"Running"}]')" \
    "running scan"
assert_eq "Idle" \
    "$(jf_refresh_scan_state '[{"Key":"RefreshLibrary","State":"Idle"}]')" \
    "idle scan"
assert_eq "Cancelling" \
    "$(jf_refresh_scan_state '[{"Key":"RefreshLibrary","State":"Cancelling"}]')" \
    "cancelling scan"
assert_eq "Idle" \
    "$(jf_refresh_scan_state '[]')" \
    "missing scan task is idle"
assert_eq "Idle" \
    "$(jf_refresh_scan_state '')" \
    "empty JSON is idle"

test_suite "jf_refresh_scan_busy"
assert_true "running is busy" "jf_refresh_scan_busy Running"
assert_true "cancelling is busy" "jf_refresh_scan_busy Cancelling"
assert_false "idle is not busy" "jf_refresh_scan_busy Idle"
assert_false "empty is not busy" "jf_refresh_scan_busy ''"

test_suite "jf_refresh_is_test_event"
radarr_eventtype=""
sonarr_eventtype=""
assert_false "no event" "jf_refresh_is_test_event"
radarr_eventtype="Test"
assert_true "radarr test" "jf_refresh_is_test_event"
radarr_eventtype=""
sonarr_eventtype="Download"
assert_false "sonarr download" "jf_refresh_is_test_event"
sonarr_eventtype="Test"
assert_true "sonarr test" "jf_refresh_is_test_event"
sonarr_eventtype=""

test_suite "jf_refresh_dir_has_video"
_jf_tmp=$(mktemp -d)
assert_false "missing dir" "jf_refresh_dir_has_video /no/such/loki"
assert_false "empty dir" "jf_refresh_dir_has_video $_jf_tmp"
mkdir -p "$_jf_tmp/Season 1"
: >"$_jf_tmp/Season 1/notes.txt"
assert_false "only txt" "jf_refresh_dir_has_video $_jf_tmp"
: >"$_jf_tmp/Season 1/Show - S01E01.mkv"
assert_true "has mkv" "jf_refresh_dir_has_video $_jf_tmp"
rm -rf "$_jf_tmp"

test_suite "jf_refresh_empty_series_ids"
assert_eq "aa11" \
    "$(jf_refresh_empty_series_ids '{"Items":[{"Id":"aa11","Path":"/data/media/tv/Loki"}]}')" \
    "extracts series id"

test_suite "jellyfin refresh notif payload"
_sonarr_schema='[{"implementation":"CustomScript","fields":[{"name":"path","value":""}],"onDownload":false,"onUpgrade":false,"onImportComplete":false}]'
_radarr_schema='[{"implementation":"CustomScript","fields":[{"name":"path","value":""}],"onDownload":false,"onUpgrade":false}]'
_notif_jq='
    [.[] | select(.implementation == "CustomScript")][0] |
    .fields = [.fields[] | if .name == "path" then .value = "/scripts/jellyfin-refresh.sh" else . end] |
    .onUpgrade = true | .name = "Jellyfin Refresh" | .tags = [] |
    if has("onImportComplete") then
        .onDownload = false | .onImportComplete = true
    else
        .onDownload = true
    end
'
_sonarr=$(echo "$_sonarr_schema" | jq "$_notif_jq")
_radarr=$(echo "$_radarr_schema" | jq "$_notif_jq")
assert_eq "false" "$(echo "$_sonarr" | jq -r .onDownload)" "sonarr onDownload off"
assert_eq "true" "$(echo "$_sonarr" | jq -r .onImportComplete)" "sonarr onImportComplete on"
assert_eq "true" "$(echo "$_sonarr" | jq -r .onUpgrade)" "sonarr onUpgrade on"
assert_eq "true" "$(echo "$_radarr" | jq -r .onDownload)" "radarr onDownload on"
assert_eq "null" "$(echo "$_radarr" | jq -r .onImportComplete)" "radarr has no onImportComplete"

# Keep the filter above in sync with lib/jellyfin.sh
assert_contains "$(cat "$REPO_ROOT/lib/jellyfin.sh")" 'has("onImportComplete")' \
    "jellyfin.sh uses onImportComplete when the *arr schema has it"
assert_contains "$(cat "$REPO_ROOT/lib/jellyfin.sh")" '.onImportComplete = true' \
    "jellyfin.sh enables onImportComplete for Sonarr"

test_summary
