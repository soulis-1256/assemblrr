#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Unit tests for Jellyfin 12.4 Authorization: MediaBrowser migration
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../helpers.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/core.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/api.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/jellyfin.sh"

test_suite "Jellyfin 12.4 auth headers across all scripts"
for f in lib/jellyfin.sh lib/bazarr.sh scripts/jellyfin-refresh.sh scripts/media-purge.sh; do
    content=$(cat "$REPO_ROOT/$f")
    assert_contains "$content" 'Authorization: MediaBrowser' "$f uses MediaBrowser header"
    assert_not_contains "$content" 'X-Emby-Token' "$f has no X-Emby-Token"
    assert_not_contains "$content" 'X-Emby-Authorization' "$f has no X-Emby-Authorization"
done

test_suite "_jf_auth_header formatting"
hdr_tok=$(_jf_auth_header "tok-abc")
assert_contains "$hdr_tok" 'Client="assemblrr"' "includes Client"
assert_contains "$hdr_tok" 'DeviceId="assemblrr-cli"' "includes DeviceId"
assert_contains "$hdr_tok" 'Token="tok-abc"' "includes Token when provided"

hdr_notok=$(_jf_auth_header "")
assert_not_contains "$hdr_notok" 'Token=""' "omits empty Token cleanly"

test_suite "configure_jellyfin_libraries reuses existing assemblrr API key"
libs_fn=$(sed -n '/^configure_jellyfin_libraries()/,/^}/p' "$REPO_ROOT/lib/jellyfin.sh")
assert_contains "$libs_fn" 'select(.AppName == "assemblrr")' "queries /Auth/Keys for existing assemblrr key"
assert_contains "$libs_fn" '_jf_auth_header' "uses _jf_auth_header helper for MediaBrowser auth"

test_suite "Jellyfin pinned to 12.4 in compose/base.yaml"
assert_contains "$(cat "$REPO_ROOT/compose/base.yaml")" 'lscr.io/linuxserver/jellyfin:12.4ubu2604-ls60' "base.yaml pins Jellyfin 12.4"

test_suite "jellyfin_parse_vainfo_caps"
rdna4_vainfo=$(cat <<'EOF'
Trying display: drm
vainfo: Driver version: Mesa Gallium driver 26.0.8 for AMD Radeon RX 9060 XT
vainfo: Supported profile and entrypoints
      VAProfileH264ConstrainedBaseline:	VAEntrypointVLD
      VAProfileH264Main               :	VAEntrypointVLD
      VAProfileH264High               :	VAEntrypointVLD
      VAProfileH264High               :	VAEntrypointEncSlice
      VAProfileHEVCMain               :	VAEntrypointVLD
      VAProfileHEVCMain               :	VAEntrypointEncSlice
      VAProfileHEVCMain10             :	VAEntrypointVLD
      VAProfileVP9Profile0            :	VAEntrypointVLD
      VAProfileVP9Profile2            :	VAEntrypointVLD
      VAProfileAV1Profile0            :	VAEntrypointVLD
      VAProfileAV1Profile0            :	VAEntrypointEncSlice
EOF
)
rdna4_caps=$(jellyfin_parse_vainfo_caps "$rdna4_vainfo")
assert_eq "h264,hevc,vp9,av1" "$(printf '%s' "$rdna4_caps" | jq -r '.decode | join(",")')" "RDNA4 decode excludes MPEG2/VC1"
assert_eq "true" "$(printf '%s' "$rdna4_caps" | jq -r '.av1_enc')" "RDNA4 enables AV1 encode"
assert_eq "true" "$(printf '%s' "$rdna4_caps" | jq -r '.hevc_enc')" "RDNA4 enables HEVC encode"
assert_eq "true" "$(printf '%s' "$rdna4_caps" | jq -r '.hevc10 and .vp9_10')" "RDNA4 enables 10-bit HEVC & VP9"

legacy_vainfo=$(cat <<'EOF'
      VAProfileMPEG2Simple            :	VAEntrypointVLD
      VAProfileVC1Main                :	VAEntrypointVLD
      VAProfileH264High               :	VAEntrypointVLD
      VAProfileHEVCMain               :	VAEntrypointVLD
      VAProfileHEVCMain               :	VAEntrypointEncSliceLP
EOF
)
legacy_caps=$(jellyfin_parse_vainfo_caps "$legacy_vainfo")
assert_eq "h264,hevc,mpeg2video,vc1" "$(printf '%s' "$legacy_caps" | jq -r '.decode | join(",")')" "legacy GPU includes MPEG2/VC1 when reported"
assert_eq "false" "$(printf '%s' "$legacy_caps" | jq -r '.av1_enc')" "legacy GPU omits AV1 encode"
assert_eq "true" "$(printf '%s' "$legacy_caps" | jq -r '.hevc_enc')" "legacy LP slice enables HEVC encode"
assert_failure "empty vainfo fails gracefully" jellyfin_parse_vainfo_caps "no profiles"

test_suite "jellyfin_build_encoding_patch_json"
base_enc='{"EncodingThreadCount":-1,"HardwareAccelerationType":"none","EnableHardwareEncoding":false,"VaapiDevice":"/dev/dri/renderD129"}'

amd_probed=$(jellyfin_build_encoding_patch_json "$base_enc" "amd" "/dev/dri/renderD128" "$rdna4_caps")
assert_eq "vaapi" "$(printf '%s' "$amd_probed" | jq -r '.HardwareAccelerationType')" "amd -> vaapi"
assert_eq "/dev/dri/renderD128" "$(printf '%s' "$amd_probed" | jq -r '.VaapiDevice')" "sets VaapiDevice"
assert_eq "h264,hevc,vp9,av1" "$(printf '%s' "$amd_probed" | jq -r '.HardwareDecodingCodecs | join(",")')" "probed AMD omits MPEG2/VC1"
assert_eq "true" "$(printf '%s' "$amd_probed" | jq -r '.AllowAv1Encoding')" "probed RDNA4 enables AV1 encode"
assert_eq "-1" "$(printf '%s' "$amd_probed" | jq -r '.EncodingThreadCount')" "preserves unrelated fields"

amd_enc=$(jellyfin_build_encoding_patch_json "$base_enc" "amd" "/dev/dri/renderD128")
assert_eq "h264,hevc,vp9,av1" "$(printf '%s' "$amd_enc" | jq -r '.HardwareDecodingCodecs | join(",")')" "offline fallback defaults exclude MPEG2/VC1"
assert_eq "true" "$(printf '%s' "$amd_enc" | jq -r '.EnableHardwareEncoding')" "enables HW encoding"

intel_enc=$(jellyfin_build_encoding_patch_json "$base_enc" "intel" "/dev/dri/renderD128")
assert_eq "qsv" "$(printf '%s' "$intel_enc" | jq -r '.HardwareAccelerationType')" "intel -> qsv"
assert_eq "/dev/dri/renderD128" "$(printf '%s' "$intel_enc" | jq -r '.QsvDevice')" "sets QsvDevice"

nv_enc=$(jellyfin_build_encoding_patch_json "$base_enc" "nvidia" "/dev/dri/renderD128")
assert_eq "nvenc" "$(printf '%s' "$nv_enc" | jq -r '.HardwareAccelerationType')" "nvidia -> nvenc"
assert_eq "true" "$(printf '%s' "$nv_enc" | jq -r '.EnableHardwareEncoding')" "nvidia enables HW encoding"

none_enc=$(jellyfin_build_encoding_patch_json "$amd_enc" "none" "/dev/dri/renderD128")
assert_eq "none" "$(printf '%s' "$none_enc" | jq -r '.HardwareAccelerationType')" "none resets acceleration"
assert_eq "false" "$(printf '%s' "$none_enc" | jq -r '.EnableHardwareEncoding')" "none disables HW encoding"

test_summary
