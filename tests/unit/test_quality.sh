#!/bin/bash
# Unit tests for the single quality-tier model (no live stack)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../helpers.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/quality.sh"

profiles='[
  {"id":1,"name":"Any"},
  {"id":7,"name":"assemblrr 1080p Bluray + WEB"},
  {"id":8,"name":"assemblrr 4K Bluray + WEB"},
  {"id":9,"name":"assemblrr 1080p WEB"},
  {"id":10,"name":"assemblrr 4K WEB"},
  {"id":5,"name":"Ultra-HD"},
  {"id":4,"name":"HD-1080p"}
]'

test_suite "quality_tier prefers QUALITY_TIER"
QUALITY_TIER=uhd SEERR_IS_4K=false SEERR_DEFAULT_PROFILE=4
assert_eq "uhd" "$(quality_tier)" "QUALITY_TIER=uhd wins"
QUALITY_TIER=hd
assert_eq "hd" "$(quality_tier)" "QUALITY_TIER=hd"
QUALITY_TIER=any
assert_eq "any" "$(quality_tier)" "QUALITY_TIER=any"

test_suite "quality_tier legacy fallbacks"
unset QUALITY_TIER
SEERR_IS_4K=true SEERR_DEFAULT_PROFILE=1
assert_eq "uhd" "$(quality_tier)" "SEERR_IS_4K=true → uhd"
SEERR_IS_4K=false SEERR_DEFAULT_PROFILE=4
assert_eq "hd" "$(quality_tier)" "old stock id 4 → hd"
SEERR_IS_4K=false SEERR_DEFAULT_PROFILE=5
assert_eq "hd" "$(quality_tier)" "old stock id 5 without is4k → hd (id is leftover)"
SEERR_IS_4K=false SEERR_DEFAULT_PROFILE=1
assert_eq "any" "$(quality_tier)" "stock id 1 → any"
unset SEERR_IS_4K SEERR_DEFAULT_PROFILE
assert_eq "any" "$(quality_tier)" "empty config → any"

test_suite "quality_source defaults to bluray"
unset QUALITY_SOURCE
assert_eq "bluray" "$(quality_source)" "missing QUALITY_SOURCE → bluray"
QUALITY_SOURCE=web
assert_eq "web" "$(quality_source)" "QUALITY_SOURCE=web"
QUALITY_SOURCE=bluray
assert_eq "bluray" "$(quality_source)" "QUALITY_SOURCE=bluray"
QUALITY_SOURCE=nope
assert_eq "bluray" "$(quality_source)" "invalid QUALITY_SOURCE → bluray"
unset QUALITY_SOURCE

test_suite "quality_profile_names follow the same tier"
QUALITY_TIER=uhd
assert_eq "assemblrr 4K Bluray + WEB|Ultra-HD" "$(quality_profile_names radarr)" "4k movies (legacy/bluray)"
assert_eq "assemblrr 4K WEB|Ultra-HD" "$(quality_profile_names sonarr)" "4k tv"
QUALITY_TIER=hd
assert_eq "assemblrr 1080p Bluray + WEB|HD-1080p" "$(quality_profile_names radarr)" "1080p movies (legacy/bluray)"
assert_eq "assemblrr 1080p WEB|HD-1080p" "$(quality_profile_names sonarr)" "1080p tv"
QUALITY_TIER=any
assert_eq "Any|" "$(quality_profile_names radarr)" "any movies"
assert_eq "Any|" "$(quality_profile_names sonarr)" "any tv"

test_suite "quality_profile_names WEB movie source"
QUALITY_TIER=uhd QUALITY_SOURCE=web
assert_eq "assemblrr 4K WEB|Ultra-HD" "$(quality_profile_names radarr)" "4k web movies"
assert_eq "assemblrr 4K WEB|Ultra-HD" "$(quality_profile_names sonarr)" "4k web tv still WEB"
QUALITY_TIER=hd QUALITY_SOURCE=web
assert_eq "assemblrr 1080p WEB|HD-1080p" "$(quality_profile_names radarr)" "1080p web movies"
assert_eq "assemblrr 1080p WEB|HD-1080p" "$(quality_profile_names sonarr)" "1080p web tv still WEB"
QUALITY_TIER=any QUALITY_SOURCE=web
assert_eq "Any|" "$(quality_profile_names radarr)" "any ignores movie source"
unset QUALITY_SOURCE

test_suite "quality_seerr_is_4k / quality_wants_named_profile"
QUALITY_TIER=uhd
assert_eq "true" "$(quality_seerr_is_4k)" "uhd is 4K"
assert_success "uhd wants named profile" quality_wants_named_profile
QUALITY_TIER=hd
assert_eq "false" "$(quality_seerr_is_4k)" "hd is not 4K"
assert_success "hd wants named profile" quality_wants_named_profile
QUALITY_TIER=any
assert_eq "false" "$(quality_seerr_is_4k)" "any is not 4K"
assert_failure "any does not want named profile" quality_wants_named_profile

test_suite "arr_match_quality_profile"
assert_eq "8:assemblrr 4K Bluray + WEB" \
    "$(echo "$profiles" | arr_match_quality_profile "assemblrr 4K Bluray + WEB" "Ultra-HD")" \
    "exact assemblrr name"
assert_eq "5:Ultra-HD" \
    "$(echo "$profiles" | arr_match_quality_profile "missing UHD" "Ultra-HD")" \
    "stock fallback"
assert_eq "1:Any" \
    "$(echo "$profiles" | arr_match_quality_profile "Any" "")" \
    "Any without lookup"
assert_eq "1:Any" \
    "$(echo "$profiles" | arr_match_quality_profile "nope" "also-nope")" \
    "missing → Any"

test_suite "prompt asks in express and covers all three apps"
prompt=$(sed -n '/^configure_quality_profile()/,/^}/p' "$REPO_ROOT/lib/prompts.sh")
assert_not_contains "$prompt" "SETUP_MODE" "express does not skip the question"
assert_contains "$prompt" "Radarr, Sonarr, and Seerr" "question names all three"
assert_contains "$prompt" "4K WEB" "lists the 4K TV profile"
assert_contains "$prompt" "1080p WEB" "lists the 1080p TV profile"
assert_contains "$prompt" "QUALITY_SOURCE" "asks movie source"
assert_contains "$prompt" "WEB only" "offers WEB-only movies"
assert_contains "$prompt" "Bluray + WEB" "offers Bluray + WEB movies"
assert_contains "$prompt" "source_choice:-2" "Bluray + WEB is the default"
assert_not_contains "$prompt" 'seerr_default_profile="5"' "does not store stock profile ids"

test_suite "recyclarr movie WEB packs are variants of Bluray + WEB"
root="$REPO_ROOT/templates/recyclarr"
assert_contains "$(cat "$root/recyclarr.yml")" "radarr-1080p-web.yml" "root includes 1080p WEB pack"
assert_contains "$(cat "$root/recyclarr.yml")" "radarr-4k-web.yml" "root includes 4K WEB pack"
hd_web=$(cat "$root/includes/radarr-1080p-web.yml")
uhd_web=$(cat "$root/includes/radarr-4k-web.yml")
assert_contains "$hd_web" "d1d67249d3890e49bc12e275d989a7e9" "1080p WEB reuses HD Bluray + WEB trash_id"
assert_contains "$hd_web" "name: assemblrr 1080p WEB" "1080p WEB profile name"
assert_contains "$hd_web" "until_quality: WEB 1080p" "1080p cutoff is WEB"
assert_contains "$hd_web" "enabled: false" "1080p disables Blu-ray"
assert_contains "$uhd_web" "64fb5f9858489bdac2af690e27c8f42f" "2160p WEB reuses UHD Bluray + WEB trash_id"
assert_contains "$uhd_web" "name: assemblrr 4K WEB" "4K WEB profile name"
assert_contains "$uhd_web" "until_quality: WEB 2160p" "2160p cutoff is WEB"
soft=$(cat "$root/includes/radarr-soft-cfs.yml")
assert_contains "$soft" "assemblrr 1080p Bluray + WEB" "soft CFs score 1080p Bluray + WEB"
assert_not_contains "$soft" "assemblrr 1080p WEB" "bluray soft CFs do not name 1080p WEB"
assert_contains "$hd_web" "assemblrr 1080p WEB" "1080p WEB pack scores itself"
assert_contains "$uhd_web" "assemblrr 4K WEB" "4K WEB pack scores itself"

test_suite "configure_recyclarr syncs every movie pack"
recyc=$(sed -n '/^configure_recyclarr()/,/^}/p' "$REPO_ROOT/lib/seerr.sh")
assert_not_contains "$recyc" "grep -vE" "does not drop HD or WEB movie packs"
assert_contains "$(cat "$REPO_ROOT/templates/recyclarr/recyclarr.yml")" "radarr-1080p-bluray.yml" "root still includes 1080p Bluray + WEB"
assert_contains "$(cat "$REPO_ROOT/templates/recyclarr/recyclarr.yml")" "radarr-1080p-web.yml" "root still includes 1080p WEB"

test_suite "sonarr and seerr follow the same flag"
assert_contains "$(sed -n '/^lookup_sonarr_profile()/,/^}/p' "$REPO_ROOT/lib/arr.sh")" \
    "lookup_arr_quality_profile" "sonarr uses shared lookup"
assert_not_contains "$(cat "$REPO_ROOT/lib/arr.sh")" \
    "movies 4K choice does not change this" "old TV hardcode is gone"
sonarr_connect=$(grep -n 'seerr_connect_service "sonarr"' -A2 "$REPO_ROOT/lib/seerr.sh")
assert_not_contains "$sonarr_connect" '"false"' "seerr sonarr is4k is not hardcoded false"
assert_contains "$(cat "$REPO_ROOT/lib/seerr.sh")" 'is_4k=$(quality_seerr_is_4k)' \
    "seerr derives is4k from the tier"

test_summary
