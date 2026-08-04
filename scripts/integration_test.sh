#!/bin/bash
set -euo pipefail

source /home/soulis/assemblrr/.assemblrr-config

API="http://127.0.0.1:8081/api/v2"
COOKIE="/tmp/qbit_cookie.txt"

# 1. Login
echo "Logging in..."
curl -s -c "$COOKIE" -H "Referer: http://127.0.0.1:8081" -d "username=${AUTH_USERNAME}&password=${AUTH_PASSWORD}" "${API}/auth/login"

# 2. Add Ubuntu Torrent via Tracker-Injected Magnet Link (Domain Independent)
echo "Adding test torrent via Decentralized Magnet..."
# Contains the Ubuntu 22.04 LTS hash + Opentrackr (one of the largest public trackers)
TARGET_HASH="3b245504cf5f11bbdbe1201cea6a6bf45aee1bc0"
MAGNET="magnet:?xt=urn:btih:${TARGET_HASH}&dn=ubuntu-22.04.4-desktop-amd64.iso&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce&tr=udp%3A%2F%2Ftracker.openbittorrent.com%3A6969%2Fannounce"
curl -s -b "$COOKIE" -d "urls=${MAGNET}" "${API}/torrents/add"

# Wait to grab peers
echo "Waiting 15 seconds for peers..."
sleep 15
curl -s -b "$COOKIE" "${API}/torrents/info" | jq -r '.[] | "Torrent: \(.name) | State: \(.state) | Seeds: \(.num_seeds)/\(.num_complete)"'

# 3. Sabotage
echo "Sabotaging global connections to 0 and restarting torrent..."
curl -s -b "$COOKIE" -H "Referer: http://127.0.0.1:8081" -d 'json={"max_connecs": 0}' "${API}/app/setPreferences"

# Pause and resume to drop active connections instantly
curl -s -b "$COOKIE" -d "hashes=${TARGET_HASH}" "${API}/torrents/stop"
sleep 2
curl -s -b "$COOKIE" -d "hashes=${TARGET_HASH}" "${API}/torrents/start"

echo "Waiting 15 seconds to stall..."
sleep 15
curl -s -b "$COOKIE" "${API}/torrents/info" | jq -r '.[] | "Torrent: \(.name) | State: \(.state) | Seeds: \(.num_seeds)/\(.num_complete)"'

# 4. Watchdog execution
echo ">>> RUNNING WATCHDOG <<<"
export AUTH_USERNAME AUTH_PASSWORD
# Just in case CRLF was introduced during git syncs or creation
sed -i 's/\r$//' scripts/vpn-watchdog.sh
bash scripts/vpn-watchdog.sh

# 5. Restore & Clean up
echo "Restoring max connections..."
curl -s -b "$COOKIE" -H "Referer: http://127.0.0.1:8081" -d 'json={"max_connecs": 500}' "${API}/app/setPreferences"

echo "Deleting torrent..."
curl -s -b "$COOKIE" -d "hashes=${TARGET_HASH}&deleteFiles=true" "${API}/torrents/delete"

rm -f "$COOKIE"
echo "Done."