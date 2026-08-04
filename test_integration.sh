#!/bin/bash
source /home/soulis/assemblrr/.assemblrr-config
echo "[1] Authenticating..."
curl -s -c /tmp/qbit_test_cookie -d "username=${AUTH_USERNAME}&password=${AUTH_PASSWORD}" http://localhost:8081/api/v2/auth/login

echo "[2] Adding Ubuntu torrent..."
curl -s -b /tmp/qbit_test_cookie -d "urls=magnet:?xt=urn:btih:60fb0fdfb5eb78cffef4caebe5e5ce4e8031d279&dn=ubuntu-22.04" http://localhost:8081/api/v2/torrents/add

echo "[3] Waiting 15 seconds to connect to trackers..."
sleep 15

curl -s -b /tmp/qbit_test_cookie http://localhost:8081/api/v2/torrents/info | jq -r '.[] | {name, state, num_complete, num_seeds}'

echo "[4] Sabotaging connections (max_connecs = 0)"
curl -s -b /tmp/qbit_test_cookie -d 'json={"max_connecs": 0}' http://localhost:8081/api/v2/app/setPreferences

echo "[5] Waiting 15 seconds for stall..."
sleep 15

curl -s -b /tmp/qbit_test_cookie http://localhost:8081/api/v2/torrents/info | jq -r '.[] | {name, state, num_complete, num_seeds}'

echo ">>> RUNNING WATCHDOG SCRIPT LIVE <<<"
export AUTH_USERNAME AUTH_PASSWORD
bash scripts/vpn-watchdog.sh

echo "[6] Restoring connections..."
curl -s -b /tmp/qbit_test_cookie -d 'json={"max_connecs": 500}' http://localhost:8081/api/v2/app/setPreferences

echo "[7] Deleting test torrent..."
curl -s -b /tmp/qbit_test_cookie -d "hashes=60fb0fdfb5eb78cffef4caebe5e5ce4e8031d279&deleteFiles=true" http://localhost:8081/api/v2/torrents/delete
rm /tmp/qbit_test_cookie
