#!/bin/bash
# VPN Watchdog for qBittorrent - Automated Tracker Routing Check
# Monitors qBittorrent for generic broken-network symptoms.
# Restarts gluetun if a failure is detected.

set -euo pipefail

QBIT_HOST="${QBIT_HOST:-127.0.0.1:8081}"
AUTH_USERNAME_FILE="${AUTH_USERNAME_FILE:-/run/secrets/auth_username.txt}"
AUTH_PASSWORD_FILE="${AUTH_PASSWORD_FILE:-/run/secrets/auth_password.txt}"
QBIT_USER="$(cat "$AUTH_USERNAME_FILE")"
QBIT_PASS="$(cat "$AUTH_PASSWORD_FILE")"
COOKIE_JAR="/tmp/qbit_watchdog_cookie.txt"

# Heartbeat and log levels config
WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-30}"
HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-3600}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"

log_watchdog() {
    local level="$1"
    shift
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*"
}

log_debug() {
    if [ "$LOG_LEVEL" = "DEBUG" ]; then
        log_watchdog DEBUG "$*"
    fi
}

# Initial startup log (only printed on the very first execution in this container lifecycle)
if [ ! -f "/tmp/qbit_watchdog_started" ]; then
    log_watchdog INFO "VPN Watchdog active. Monitoring qBittorrent at ${QBIT_HOST} (Interval: ${WATCHDOG_INTERVAL}s, Heartbeat: ${HEARTBEAT_INTERVAL}s)."
    touch "/tmp/qbit_watchdog_started"
fi

login_qbit() {
    local http_code
    http_code=$(curl -s -o /tmp/qbit_watchdog_login_body.txt -w "%{http_code}" -c "$COOKIE_JAR" \
        -H "Referer: http://${QBIT_HOST}" \
        --data "username=${QBIT_USER}&password=${QBIT_PASS}" \
        "http://${QBIT_HOST}/api/v2/auth/login" 2>/dev/null || true)

    if [ "$http_code" != "204" ]; then
        return 1
    fi

    awk '$6 ~ /^QBT_SID_/ { found = 1 } END { exit(found ? 0 : 1) }' "$COOKIE_JAR" 2>/dev/null
}

api_get() {
    local endpoint="$1"
    curl -s -b "$COOKIE_JAR" "http://${QBIT_HOST}${endpoint}"
}

if ! login_qbit; then
    log_watchdog ERROR "Failed to authenticate to qBittorrent API."
    echo "auth_failed" > "/tmp/qbit_watchdog_last_status"
    exit 1
fi

TORRENTS=$(api_get "/api/v2/torrents/info")

# Check if we recovered from a previous failure
last_status=""
if [ -f "/tmp/qbit_watchdog_last_status" ]; then
    last_status=$(cat "/tmp/qbit_watchdog_last_status")
fi

if [ -n "$last_status" ] && [ "$last_status" != "success" ]; then
    log_watchdog INFO "Watchdog recovered: Connection to qBittorrent API restored."
fi
echo "success" > "/tmp/qbit_watchdog_last_status"

num_torrents=0
if [ -n "$TORRENTS" ] && [ "$TORRENTS" != "[]" ]; then
    num_torrents=$(echo "$TORRENTS" | jq '. | length')
fi

# Heartbeat log (periodic verification message)
current_time=$(date +%s)
last_heartbeat=0
if [ -f "/tmp/qbit_watchdog_last_heartbeat" ]; then
    last_heartbeat=$(cat "/tmp/qbit_watchdog_last_heartbeat")
fi

time_diff=$((current_time - last_heartbeat))
if [ "$time_diff" -ge "$HEARTBEAT_INTERVAL" ]; then
    log_watchdog INFO "Heartbeat: Watchdog is active. Connected to qBittorrent. Monitoring ${num_torrents} torrent(s). VPN routing is healthy."
    echo "$current_time" > "/tmp/qbit_watchdog_last_heartbeat"
fi

if [ -z "$TORRENTS" ] || [ "$TORRENTS" = "[]" ]; then
    log_debug "No torrents found to check. Watchdog check completed silently."
    rm -f "$COOKIE_JAR"
    exit 0
fi

DETECTED_TORRENTS=()

while IFS='|' read -r hash name; do
    [ -z "$hash" ] && continue

    PROPERTIES=$(api_get "/api/v2/torrents/properties?hash=${hash}")
    TRACKERS=$(api_get "/api/v2/torrents/trackers?hash=${hash}")

    has_metadata=$(echo "$PROPERTIES" | jq -r '.has_metadata')
    nb_connections=$(echo "$PROPERTIES" | jq -r '.nb_connections')
    failed_trackers=$(echo "$TRACKERS" | jq '[.[] | select(.status == 4)] | length')
    operation_not_permitted=$(echo "$TRACKERS" | jq '[.[] | select(.status == 4 and (.msg | contains("Operation not permitted")))] | length')
    timed_out=$(echo "$TRACKERS" | jq '[.[] | select(.status == 4 and (.msg | contains("timed out")))] | length')
    host_not_found=$(echo "$TRACKERS" | jq '[.[] | select(.status == 4 and (.msg | contains("Host not found")))] | length')

    if [ "$has_metadata" = "false" ] && [ "$nb_connections" -eq 0 ] && [ "$failed_trackers" -ge 3 ] && \
        { [ "$operation_not_permitted" -gt 0 ] || [ "$timed_out" -gt 0 ] || [ "$host_not_found" -gt 0 ]; }; then
        DETECTED_TORRENTS+=("$name")
    fi
done < <(echo "$TORRENTS" | jq -r '.[] | [.hash, .name] | @tsv' | tr '\t' '|')

rm -f "$COOKIE_JAR"

if [ ${#DETECTED_TORRENTS[@]} -gt 0 ]; then
    log_watchdog DETECTED "VPN routing failure! Torrents with broken-network symptoms found:"
    for torrent_name in "${DETECTED_TORRENTS[@]}"; do
        log_watchdog DETECTED "$torrent_name"
    done
    log_watchdog ACTION "Triggering Gluetun restart to fetch a new VPN IP..."
    echo "routing_failed" > "/tmp/qbit_watchdog_last_status"
    docker restart gluetun
    exit 1
fi

log_debug "Watchdog check completed successfully. Monitored ${num_torrents} torrents. All healthy."
exit 0
