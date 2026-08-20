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
  {"id":7,"name":"assemblrr HD Bluray + WEB"},
  {"id":8,"name":"assemblrr UHD Bluray + WEB"},
  {"id":9,"name":"assemblrr WEB-1080p"},
  {"id":10,"name":"assemblrr WEB-2160p"},
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
assert_eq "assemblrr UHD Bluray + WEB|Ultra-HD" "$(quality_profile_names radarr)" "uhd movies (legacy/bluray)"
assert_eq "assemblrr WEB-2160p|Ultra-HD" "$(quality_profile_names sonarr)" "uhd tv"
QUALITY_TIER=hd
assert_eq "assemblrr HD Bluray + WEB|HD-1080p" "$(quality_profile_names radarr)" "hd movies (legacy/bluray)"
assert_eq "assemblrr WEB-1080p|HD-1080p" "$(quality_profile_names sonarr)" "hd tv"
QUALITY_TIER=any
assert_eq "Any|" "$(quality_profile_names radarr)" "any movies"
assert_eq "Any|" "$(quality_profile_names sonarr)" "any tv"

test_suite "quality_profile_names WEB movie source"
QUALITY_TIER=uhd QUALITY_SOURCE=web
assert_eq "assemblrr WEB-2160p|Ultra-HD" "$(quality_profile_names radarr)" "uhd web movies"
assert_eq "assemblrr WEB-2160p|Ultra-HD" "$(quality_profile_names sonarr)" "uhd web tv still WEB"
QUALITY_TIER=hd QUALITY_SOURCE=web
assert_eq "assemblrr WEB-1080p|HD-1080p" "$(quality_profile_names radarr)" "hd web movies"
assert_eq "assemblrr WEB-1080p|HD-1080p" "$(quality_profile_names sonarr)" "hd web tv still WEB"
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
assert_eq "8:assemblrr UHD Bluray + WEB" \
    "$(echo "$profiles" | arr_match_quality_profile "assemblrr UHD Bluray + WEB" "Ultra-HD")" \
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
assert_contains "$prompt" "WEB-2160p" "lists the 4K TV profile"
assert_contains "$prompt" "WEB-1080p" "lists the 1080p TV profile"
assert_contains "$prompt" "QUALITY_SOURCE" "asks movie source"
assert_contains "$prompt" "WEB only" "offers WEB-only movies"
assert_contains "$prompt" "Bluray + WEB" "offers Bluray + WEB movies"
assert_contains "$prompt" "source_choice:-2" "Bluray + WEB is the default"
assert_not_contains "$prompt" 'seerr_default_profile="5"' "does not store stock profile ids"

test_suite "recyclarr movie WEB packs are variants of Bluray + WEB"
root="$REPO_ROOT/templates/recyclarr"
assert_contains "$(cat "$root/recyclarr.yml")" "radarr-web-1080.yml" "root includes WEB-1080p pack"
assert_contains "$(cat "$root/recyclarr.yml")" "radarr-web-2160.yml" "root includes WEB-2160p pack"
hd_web=$(cat "$root/includes/radarr-web-1080.yml")
uhd_web=$(cat "$root/includes/radarr-web-2160.yml")
assert_contains "$hd_web" "d1d67249d3890e49bc12e275d989a7e9" "1080p WEB reuses HD Bluray + WEB trash_id"
assert_contains "$hd_web" "name: assemblrr WEB-1080p" "1080p WEB profile name"
assert_contains "$hd_web" "until_quality: WEB 1080p" "1080p cutoff is WEB"
assert_contains "$hd_web" "enabled: false" "1080p disables Blu-ray"
assert_contains "$uhd_web" "64fb5f9858489bdac2af690e27c8f42f" "2160p WEB reuses UHD Bluray + WEB trash_id"
assert_contains "$uhd_web" "name: assemblrr WEB-2160p" "2160p WEB profile name"
assert_contains "$uhd_web" "until_quality: WEB 2160p" "2160p cutoff is WEB"
soft=$(cat "$root/includes/radarr-soft-cfs.yml")
assert_contains "$soft" "assemblrr HD Bluray + WEB" "soft CFs score HD Bluray + WEB"
assert_not_contains "$soft" "assemblrr WEB-1080p" "bluray soft CFs do not name WEB-1080p"
assert_contains "$hd_web" "assemblrr WEB-1080p" "WEB-1080p pack scores itself"
assert_contains "$uhd_web" "assemblrr WEB-2160p" "WEB-2160p pack scores itself"

test_suite "configure_recyclarr syncs every movie pack"
recyc=$(sed -n '/^configure_recyclarr()/,/^}/p' "$REPO_ROOT/lib/seerr.sh")
assert_not_contains "$recyc" "grep -vE" "does not drop HD or WEB movie packs"
assert_contains "$(cat "$REPO_ROOT/templates/recyclarr/recyclarr.yml")" "radarr-hd.yml" "root still includes HD Bluray + WEB"
assert_contains "$(cat "$REPO_ROOT/templates/recyclarr/recyclarr.yml")" "radarr-web-1080.yml" "root still includes WEB-1080p"

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
