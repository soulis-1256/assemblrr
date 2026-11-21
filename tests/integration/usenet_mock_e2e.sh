#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Offline Docker E2E test for SABnzbd + Usenet wiring against local mock_nntp.py & mock_newznab.py.
# Zero external internet calls or paid Usenet providers required.
# Opt-in live container check: ASSEMBLRR_ALLOW_LIVE_TEST=1 ./tests/integration/usenet_mock_e2e.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ "${ASSEMBLRR_ALLOW_LIVE_TEST:-}" != "1" ]; then
    echo "Refusing to spin up temporary SABnzbd container without ASSEMBLRR_ALLOW_LIVE_TEST=1" >&2
    exit 2
fi

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

tmp=$(mktemp -d)
nntp_pid="" newznab_pid="" cid=""
cleanup() {
    [ -n "$cid" ] && docker rm -f "$cid" >/dev/null 2>&1 || true
    [ -n "$nntp_pid" ] && kill "$nntp_pid" >/dev/null 2>&1 || true
    [ -n "$newznab_pid" ] && kill "$newznab_pid" >/dev/null 2>&1 || true
    rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

mkdir -p "$tmp/config" "$tmp/data/usenet/incomplete" "$tmp/data/usenet/complete/movies" "$tmp/data/usenet/complete/tv"

python3 "$REPO_ROOT/tests/fixtures/mock_nntp.py" --host 0.0.0.0 --port 0 --user mockuser --password mockpass --port-file "$tmp/nntp.port" &
nntp_pid=$!
python3 "$REPO_ROOT/tests/fixtures/mock_newznab.py" --host 0.0.0.0 --port 0 --port-file "$tmp/newznab.port" &
newznab_pid=$!

for _ in $(seq 1 30); do
    [ -s "$tmp/nntp.port" ] && [ -s "$tmp/newznab.port" ] && break
    sleep 0.2
done
nntp_port=$(tr -d '\r\n' < "$tmp/nntp.port")
newznab_port=$(tr -d '\r\n' < "$tmp/newznab.port")
echo "Started mock NNTP :${nntp_port} and mock Newznab :${newznab_port}"

cid=$(docker run -d --network host \
    -e "PUID=$(id -u)" -e "PGID=$(id -g)" -e "TZ=UTC" \
    -v "$tmp/config:/config" \
    -v "$tmp/data:/data" \
    lscr.io/linuxserver/sabnzbd:5.1.3)

# shellcheck source=/dev/null
source "$REPO_ROOT/lib/core.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/api.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/usenet.sh"

INSTALL_DIR="$tmp"
USENET_ENABLED="y"
USENET_HOST="127.0.0.1"
USENET_PORT="$nntp_port"
USENET_SSL="n"
USENET_USERNAME="mockuser"
USENET_CONNECTIONS="2"
AUTH_USERNAME="admin"
AUTH_PASSWORD="testpassword123"
API_HOST="127.0.0.1"
SABNZBD_PORT=8080
mkdir -p "$tmp/secrets"
write_secret_file "$tmp/secrets/usenet_password.txt" "mockpass"

# Wait for SABnzbd first-boot ini & API
sab_key=$(read_sabnzbd_api_key 2>/dev/null || true)
[ -n "$sab_key" ] || { echo "SABnzbd did not initialize sabnzbd.ini" >&2; exit 1; }

# Configure mock NNTP server in SABnzbd via configure_sabnzbd
configure_sabnzbd

# Fetch mock NZB and push via SABnzbd addfile/addurl
curl -sf "http://127.0.0.1:${newznab_port}/api?t=get&id=sample-1" > "$tmp/sample.nzb"
curl -sf -F "name=@${tmp}/sample.nzb" -F "cat=movies" \
    "http://127.0.0.1:${SABNZBD_PORT}/api?mode=addfile&apikey=${sab_key}&output=json" >/dev/null

# Wait up to 30s for mock NZB completion
ok=0
for _ in $(seq 1 30); do
    hist=$(curl -sf "http://127.0.0.1:${SABNZBD_PORT}/api?mode=history&apikey=${sab_key}&output=json" || echo "{}")
    if printf '%s' "$hist" | jq -e '.history.slots[]? | select(.status == "Completed")' >/dev/null 2>&1; then
        ok=1
        break
    fi
    sleep 1
done
[ "$ok" -eq 1 ] || { echo "Mock NZB did not complete in SABnzbd" >&2; exit 1; }

found=$(find "$tmp/data/usenet/complete" -name "assemblrr-sample.txt" 2>/dev/null | head -1 || true)
[ -n "$found" ] || { echo "Decoded file missing under $tmp/data/usenet/complete" >&2; exit 1; }
grep -qx "assemblrr mock usenet payload ok" "$found"
echo "STATUS: OK (SABnzbd downloaded & yEnc-decoded mock NZB from mock_nntp.py)"
