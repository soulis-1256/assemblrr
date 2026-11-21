#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Offline unit tests for lib/usenet.sh + free mock_nntp.py / mock_newznab.py fixtures
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../helpers.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/core.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/api.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/usenet.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

test_suite "sabnzbd_enabled flag"
USENET_ENABLED=n
assert_false "disabled when n" sabnzbd_enabled
USENET_ENABLED=y
assert_true "enabled when y" sabnzbd_enabled
USENET_ENABLED=Y
assert_true "enabled when Y" sabnzbd_enabled

test_suite "sabnzbd_extract_api_key parses sabnzbd.ini"
ini="$tmp/sabnzbd.ini"
printf 'host = 0.0.0.0\r\napi_key = deadbeef123456\r\nnzb_key = abc\r\n' > "$ini"
assert_eq "deadbeef123456" "$(sabnzbd_extract_api_key "$ini")" "extracts key without CR"

test_suite "write_sabnzbd_config creates dirs & validates secret"
INSTALL_DIR="$tmp/install"
MEDIA_DIRECTORY="$tmp/media"
mkdir -p "$INSTALL_DIR/secrets" "$INSTALL_DIR/config"
write_secret_file "$INSTALL_DIR/secrets/usenet_password.txt" "secretpw"
write_sabnzbd_config
assert_true "creates config/sabnzbd" "[ -d '$INSTALL_DIR/config/sabnzbd' ]"

test_suite "arr_build_sabnzbd_payload generates valid Radarr & Sonarr payloads"
r_json=$(arr_build_sabnzbd_payload '[]' "sabkey-1" "movieCategory" "movies")
assert_eq "SABnzbd" "$(echo "$r_json" | jq -r '.name')" "client name SABnzbd"
assert_eq "Sabnzbd" "$(echo "$r_json" | jq -r '.implementation')" "implementation Sabnzbd"
assert_eq "sabnzbd" "$(echo "$r_json" | jq -r '.fields[] | select(.name=="host") | .value')" "host sabnzbd"
assert_eq "8080" "$(echo "$r_json" | jq -r '.fields[] | select(.name=="port") | .value')" "internal port 8080"
assert_eq "movies" "$(echo "$r_json" | jq -r '.fields[] | select(.name=="movieCategory") | .value')" "movieCategory=movies"

s_json=$(arr_build_sabnzbd_payload '[]' "sabkey-1" "tvCategory" "tv")
assert_eq "tv" "$(echo "$s_json" | jq -r '.fields[] | select(.name=="tvCategory") | .value')" "tvCategory=tv"

mock_schema='[{"implementation":"Sabnzbd","implementationName":"SABnzbd","configContract":"SabnzbdSettings","fields":[{"name":"host","value":""},{"name":"port","value":0},{"name":"useSsl","value":true},{"name":"urlBase","value":"/sab"},{"name":"apiKey","value":""},{"name":"movieCategory","value":""}]}]'
schema_json=$(arr_build_sabnzbd_payload "$mock_schema" "sabkey-2" "movieCategory" "movies")
assert_eq "sabkey-2" "$(echo "$schema_json" | jq -r '.fields[] | select(.name=="apiKey") | .value')" "injects apiKey from *arr schema"
assert_eq "false" "$(echo "$schema_json" | jq -r '.fields[] | select(.name=="useSsl") | .value')" "disables internal TLS on bridge network"

USENET_ENABLED=y
assert_success "0-arg arr_configure_sabnzbd handles missing API keys cleanly" \
    env -u RADARR_API_KEY -u SONARR_API_KEY bash -c 'source "$1/lib/core.sh"; source "$1/lib/api.sh"; source "$1/lib/usenet.sh"; USENET_ENABLED=y; INSTALL_DIR="$2"; arr_configure_sabnzbd' _ "$REPO_ROOT" "$tmp/install"

test_suite "Free mock_nntp.py + mock_newznab.py loopback protocol check"
if command -v python3 >/dev/null 2>&1; then
    if python3 - "$REPO_ROOT" <<'PY'
import sys, socket, urllib.request, xml.etree.ElementTree as ET
from pathlib import Path

repo = Path(sys.argv[1])
sys.path.insert(0, str(repo / "tests" / "fixtures"))
import mock_nntp
import mock_newznab

nntp = mock_nntp.start_background("127.0.0.1", 0, username="u1", password="p1")
newznab = mock_newznab.start_background("127.0.0.1", 0)
try:
    nntp_port = nntp.server_address[1]
    nzb_port = newznab.server_address[1]

    # 1) Newznab caps & NZB fetch
    caps = urllib.request.urlopen(f"http://127.0.0.1:{nzb_port}/api?t=caps", timeout=3).read().decode()
    assert "<caps>" in caps and "movie-search" in caps
    nzb_xml = urllib.request.urlopen(f"http://127.0.0.1:{nzb_port}/api?t=get&id=sample-1", timeout=3).read().decode()
    root = ET.fromstring(nzb_xml)
    seg = root.find(".//{http://www.newzbin.com/DTD/2003/nzb}segment")
    assert seg is not None and seg.text == "sample-part1@assemblrr.test"

    # 2) NNTP auth + ARTICLE + yEnc body present
    with socket.create_connection(("127.0.0.1", nntp_port), timeout=3) as s:
        f = s.makefile("rwb", buffering=0)
        assert f.readline().startswith(b"200 ")
        f.write(b"AUTHINFO USER u1\r\n")
        assert f.readline().startswith(b"381 ")
        f.write(b"AUTHINFO PASS p1\r\n")
        assert f.readline().startswith(b"281 ")
        f.write(f"ARTICLE <{seg.text}>\r\n".encode())
        first = f.readline()
        assert first.startswith(b"220 "), first
        body_lines = []
        while True:
            ln = f.readline()
            if ln == b".\r\n" or not ln:
                break
            body_lines.append(ln)
        joined = b"".join(body_lines)
        assert b"=ybegin" in joined and b"=yend" in joined
        f.write(b"QUIT\r\n")
        assert f.readline().startswith(b"205 ")
finally:
    nntp.shutdown(); nntp.server_close()
    newznab.shutdown(); newznab.server_close()
PY
    then
        _TEST_PASSES=$((_TEST_PASSES + 1))
        echo "  PASS: mock NNTP auth/ARTICLE/yEnc + Newznab caps/NZB work offline"
    else
        _TEST_FAILURES=$((_TEST_FAILURES + 1))
        echo "  FAIL: mock NNTP/Newznab protocol check failed"
    fi
else
    echo "  SKIP: python3 unavailable"
fi

test_summary
