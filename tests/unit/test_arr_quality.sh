#!/bin/bash
# Unit tests for *arr quality-profile apply helpers (no live stack)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../helpers.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/core.sh"
stub_log_error_no_exit
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/api.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/arr.sh"

test_suite "arr_quality_ids_needing_update"
items='[{"id":1,"qualityProfileId":1},{"id":2,"qualityProfileId":6},{"id":3,"qualityProfileId":1}]'
assert_eq '[2]' "$(echo "$items" | arr_quality_ids_needing_update 1 all)" "all: skip already-on-target"
assert_eq '[1,3]' "$(echo "$items" | arr_quality_ids_needing_update 6 all)" "all: ids not on target"
assert_eq '[1,3]' "$(echo "$items" | arr_quality_ids_needing_update 6 any-only)" "any-only: only profile 1"
assert_eq '[2]' "$(echo "$items" | arr_quality_ids_needing_update 1 from:6)" "from:6 only that id"
assert_eq '[]' "$(echo '[]' | arr_quality_ids_needing_update 6 all)" "empty library"

test_suite "arr_quality_profile_clone_json"
src='{"id":6,"name":"assemblrr WEB-1080p","upgradeAllowed":true,"cutoff":8}'
cloned=$(echo "$src" | arr_quality_profile_clone_json 1 "assemblrr WEB-1080p")
assert_eq "1" "$(echo "$cloned" | jq -r '.id')" "clone uses id 1"
assert_eq "assemblrr WEB-1080p" "$(echo "$cloned" | jq -r '.name')" "keeps name"
assert_eq "true" "$(echo "$cloned" | jq -r '.upgradeAllowed')" "keeps body"

test_suite "arr_rootfolder_with_default_profile"
folder='{"id":1,"path":"/data/media/movies","unmappedFolders":[{"name":"x"}],"defaultQualityProfileId":1}'
out=$(echo "$folder" | arr_rootfolder_with_default_profile 6)
assert_eq "6" "$(echo "$out" | jq -r '.defaultQualityProfileId')" "sets defaultQualityProfileId"
assert_eq "null" "$(echo "$out" | jq -r '.unmappedFolders')" "drops unmappedFolders"
assert_eq "/data/media/movies" "$(echo "$out" | jq -r '.path')" "keeps path"

test_suite "set_default_quality_profile applies, not just records"
src="$REPO_ROOT/lib/arr.sh"
apply=$(sed -n '/^set_default_quality_profile()/,/^}/p' "$src")
assert_true "sets root-folder default" "grep -q defaultQualityProfileId \"$src\""
assert_true "updates import lists" "grep -q '/api/v3/importlist/' \"$src\""
assert_true "promotes assemblrr profile to id 1" "grep -q 'arr_promote_quality_profile' \"$src\""
assert_true "writes qualityprofile/1" "grep -q '/api/v3/qualityprofile/1' \"$src\""
assert_not_contains "$apply" '"all"' "does not remap the whole library"
assert_not_contains "$apply" "any-only" "does not remap titles still on Any"
assert_contains "$apply" "quality_wants_named_profile" "named-profile check uses the tier"

test_suite "lookups share quality_profile_names"
assert_contains "$(sed -n '/^lookup_radarr_profile()/,/^}/p' "$src")" \
    "lookup_arr_quality_profile" "radarr lookup is the shared helper"
assert_contains "$(sed -n '/^lookup_sonarr_profile()/,/^}/p' "$src")" \
    "lookup_arr_quality_profile" "sonarr lookup is the shared helper"

test_summary
