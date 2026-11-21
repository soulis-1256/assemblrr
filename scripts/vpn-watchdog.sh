#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# VPN Watchdog for qBittorrent — Automated Tracker Routing Check
# Monitors qBittorrent for systemic broken-network symptoms and restarts Gluetun
# with cooldown & healthy-traffic guards to prevent single-magnet false positives
# and restart storms.

set -euo pipefail

QBIT_HOST="${QBIT_HOST:-127.0.0.1:8081}"
AUTH_USERNAME_FILE="${AUTH_USERNAME_FILE:-/run/secrets/auth_username.txt}"
AUTH_PASSWORD_FILE="${AUTH_PASSWORD_FILE:-/run/secrets/auth_password.txt}"
GLUETUN_CONTROL_URL="${GLUETUN_CONTROL_URL:-http://127.0.0.1:8000}"

WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-30}"
HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-3600}"
WATCHDOG_COOLDOWN_SEC="${WATCHDOG_COOLDOWN_SEC:-300}"
WATCHDOG_STATE_DIR="${WATCHDOG_STATE_DIR:-/tmp}"
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

# Pure helper: evaluate torrent properties + trackers JSON for broken routing.
# Prints: "<broken 0|1> <working 0|1>"
watchdog_classify_torrent() {
    local props_json="${1:-}"
    local trackers_json="${2:-}"

    local has_metadata nb_conn failed_trackers routing_errs working_trackers
    has_metadata=$(printf '%s' "$props_json" | jq -r '.has_metadata // false' 2>/dev/null || echo false)
    nb_conn=$(printf '%s' "$props_json" | jq -r '.nb_connections // 0' 2>/dev/null || echo 0)
    [[ "$nb_conn" =~ ^[0-9]+$ ]] || nb_conn=0

    failed_trackers=$(printf '%s' "$trackers_json" | jq '[.[]? | select(.status == 4)] | length' 2>/dev/null || echo 0)
    [[ "$failed_trackers" =~ ^[0-9]+$ ]] || failed_trackers=0

    routing_errs=$(printf '%s' "$trackers_json" | jq '[.[]? | select(.status == 4 and ((.msg // "") | test("Operation not permitted|timed out|Host not found|Network is unreachable"; "i")))] | length' 2>/dev/null || echo 0)
    [[ "$routing_errs" =~ ^[0-9]+$ ]] || routing_errs=0

    working_trackers=$(printf '%s' "$trackers_json" | jq '[.[]? | select(.status == 2)] | length' 2>/dev/null || echo 0)
    [[ "$working_trackers" =~ ^[0-9]+$ ]] || working_trackers=0

    local is_working=0 is_broken=0
    if [ "$nb_conn" -gt 0 ] || [ "$working_trackers" -gt 0 ]; then
        is_working=1
    fi
    if [ "$has_metadata" = "false" ] && [ "$nb_conn" -eq 0 ] \
        && [ "$failed_trackers" -ge 3 ] && [ "$routing_errs" -gt 0 ]; then
        is_broken=1
    fi

    echo "${is_broken} ${is_working}"
}

# Return 0 if a curl Netscape cookie jar contains a non-empty qBittorrent session cookie
# (including #HttpOnly_ prefixed lines and port-suffixed QBT_SID_<port> cookies from qBit 5.x).
watchdog_cookie_has_sid() {
    local jar="$1"
    [ -f "$jar" ] || return 1
    awk '($1 !~ /^#/ || $1 ~ /^#HttpOnly_/) && NF >= 7 && ($6 ~ /^QBT_SID/ || $6 == "SID") && $7 != "" { found = 1 } END { exit(found ? 0 : 1) }' "$jar" 2>/dev/null
}

# Pure helper: return 0 when broken routing warrants a gluetun restart, 1 otherwise.
# Args: <broken_count> <working_count> <now_epoch> <last_restart_epoch> <cooldown_sec>
watchdog_should_restart_vpn() {
    local broken="${1:-0}"
    local working="${2:-0}"
    local now="${3:-0}"
    local last_restart="${4:-0}"
    local cooldown="${5:-300}"

    [ "$broken" -gt 0 ] || return 1
    # Any active peer connection or healthy status-2 tracker proves the VPN path works;
    # do not nuke everyone's transfers because of one unseeded/dead magnet link.
    [ "$working" -eq 0 ] || return 1
    if [ "$last_restart" -gt 0 ] && [ "$((now - last_restart))" -lt "$cooldown" ]; then
        return 1
    fi
    return 0
}

if [ "${WATCHDOG_SOURCE_ONLY:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

COOKIE_JAR=$(mktemp "${WATCHDOG_STATE_DIR%/}/qbit_watchdog_cookie.XXXXXX")
LOGIN_BODY=$(mktemp "${WATCHDOG_STATE_DIR%/}/qbit_watchdog_login.XXXXXX")
cleanup_watchdog() {
    rm -f "${COOKIE_JAR:-}" "${LOGIN_BODY:-}"
}
trap cleanup_watchdog EXIT INT TERM

if [ ! -r "$AUTH_USERNAME_FILE" ] || [ ! -r "$AUTH_PASSWORD_FILE" ]; then
    log_watchdog ERROR "Watchdog credentials not readable ($AUTH_USERNAME_FILE / $AUTH_PASSWORD_FILE)."
    exit 1
fi

QBIT_USER=$(tr -d '\r\n' < "$AUTH_USERNAME_FILE")
QBIT_PASS=$(tr -d '\r\n' < "$AUTH_PASSWORD_FILE")

if [ ! -f "${WATCHDOG_STATE_DIR%/}/qbit_watchdog_started" ]; then
    log_watchdog INFO "VPN Watchdog active. Monitoring qBittorrent at ${QBIT_HOST} (Interval: ${WATCHDOG_INTERVAL}s, Heartbeat: ${HEARTBEAT_INTERVAL}s, Cooldown: ${WATCHDOG_COOLDOWN_SEC}s)."
    touch "${WATCHDOG_STATE_DIR%/}/qbit_watchdog_started"
fi

login_qbit() {
    local http_code
    http_code=$(curl -sS -o "$LOGIN_BODY" -w "%{http_code}" --connect-timeout 5 --max-time 15 \
        -c "$COOKIE_JAR" \
        -H "Referer: http://${QBIT_HOST}" \
        --data-urlencode "username=${QBIT_USER}" \
        --data-urlencode "password=${QBIT_PASS}" \
        "http://${QBIT_HOST}/api/v2/auth/login" 2>/dev/null || true)

    if [ "$http_code" != "200" ] && [ "$http_code" != "204" ]; then
        return 1
    fi

    watchdog_cookie_has_sid "$COOKIE_JAR"
}

qbit_watchdog_get() {
    local endpoint="$1"
    curl -sS --connect-timeout 5 --max-time 15 \
        -b "$COOKIE_JAR" \
        -H "Referer: http://${QBIT_HOST}" \
        "http://${QBIT_HOST}${endpoint}" 2>/dev/null || true
}

if ! login_qbit; then
    log_watchdog ERROR "Failed to authenticate to qBittorrent API."
    echo "auth_failed" > "${WATCHDOG_STATE_DIR%/}/qbit_watchdog_last_status"
    exit 1
fi

TORRENTS=$(qbit_watchdog_get "/api/v2/torrents/info")
if [ -z "$TORRENTS" ] || ! printf '%s' "$TORRENTS" | jq -e 'type == "array"' >/dev/null 2>&1; then
    log_watchdog ERROR "Failed to fetch valid torrent list from qBittorrent API."
    echo "api_failed" > "${WATCHDOG_STATE_DIR%/}/qbit_watchdog_last_status"
    exit 1
fi

last_status=""
if [ -f "${WATCHDOG_STATE_DIR%/}/qbit_watchdog_last_status" ]; then
    last_status=$(cat "${WATCHDOG_STATE_DIR%/}/qbit_watchdog_last_status")
fi
if [ -n "$last_status" ] && [ "$last_status" != "success" ]; then
    log_watchdog INFO "Watchdog recovered: Connection to qBittorrent API restored."
fi
echo "success" > "${WATCHDOG_STATE_DIR%/}/qbit_watchdog_last_status"

num_torrents=$(printf '%s' "$TORRENTS" | jq 'length' 2>/dev/null || echo 0)
[[ "$num_torrents" =~ ^[0-9]+$ ]] || num_torrents=0

current_time=$(date +%s)
last_heartbeat=0
if [ -f "${WATCHDOG_STATE_DIR%/}/qbit_watchdog_last_heartbeat" ]; then
    last_heartbeat=$(cat "${WATCHDOG_STATE_DIR%/}/qbit_watchdog_last_heartbeat" 2>/dev/null || echo 0)
    [[ "$last_heartbeat" =~ ^[0-9]+$ ]] || last_heartbeat=0
fi

time_diff=$((current_time - last_heartbeat))
if [ "$time_diff" -ge "$HEARTBEAT_INTERVAL" ]; then
    log_watchdog INFO "Heartbeat: Watchdog is active. Connected to qBittorrent. Monitoring ${num_torrents} torrent(s). VPN routing is healthy."
    echo "$current_time" > "${WATCHDOG_STATE_DIR%/}/qbit_watchdog_last_heartbeat"
fi

if [ "$num_torrents" -eq 0 ]; then
    log_debug "No torrents found to check. Watchdog check completed silently."
    exit 0
fi

DETECTED_TORRENTS=()
working_count=0

while IFS=$'\t' read -r hash name; do
    [ -z "$hash" ] && continue

    PROPERTIES=$(qbit_watchdog_get "/api/v2/torrents/properties?hash=${hash}")
    TRACKERS=$(qbit_watchdog_get "/api/v2/torrents/trackers?hash=${hash}")

    read -r is_broken is_working < <(watchdog_classify_torrent "$PROPERTIES" "$TRACKERS")
    if [ "$is_working" -eq 1 ]; then
        working_count=$((working_count + 1))
    fi
    if [ "$is_broken" -eq 1 ]; then
        DETECTED_TORRENTS+=("$name")
    fi
done < <(printf '%s' "$TORRENTS" | jq -r '.[] | [(.hash // ""), (.name // "")] | @tsv' 2>/dev/null || true)

broken_count=${#DETECTED_TORRENTS[@]}
if [ "$broken_count" -gt 0 ]; then
    last_restart=0
    if [ -f "${WATCHDOG_STATE_DIR%/}/qbit_watchdog_last_restart" ]; then
        last_restart=$(cat "${WATCHDOG_STATE_DIR%/}/qbit_watchdog_last_restart" 2>/dev/null || echo 0)
        [[ "$last_restart" =~ ^[0-9]+$ ]] || last_restart=0
    fi

    if [ "$working_count" -gt 0 ]; then
        log_debug "Ignoring ${broken_count} stalled torrent(s): ${working_count} torrent(s) have active peers/trackers (not a global VPN failure)."
        exit 0
    fi

    # Optional: check Gluetun's local control endpoint if open without blocking on auth
    gluetun_status=$(curl -sS --connect-timeout 2 --max-time 5 "${GLUETUN_CONTROL_URL}/v1/openvpn/status" 2>/dev/null | jq -r '.status // empty' 2>/dev/null || true)
    if [ -n "$gluetun_status" ] && [ "$gluetun_status" != "running" ]; then
        log_watchdog DETECTED "Gluetun reported VPN status '${gluetun_status}'."
    fi

    if ! watchdog_should_restart_vpn "$broken_count" "$working_count" "$current_time" "$last_restart" "$WATCHDOG_COOLDOWN_SEC"; then
        remaining=$((WATCHDOG_COOLDOWN_SEC - (current_time - last_restart)))
        log_watchdog INFO "VPN restart cooldown active (${remaining}s remaining); skipping restart for ${broken_count} stalled torrent(s)."
        exit 0
    fi

    log_watchdog DETECTED "VPN routing failure! Torrents with broken-network symptoms found:"
    for torrent_name in "${DETECTED_TORRENTS[@]}"; do
        log_watchdog DETECTED "$torrent_name"
    done
    log_watchdog ACTION "Triggering Gluetun restart to fetch a new VPN IP..."
    echo "routing_failed" > "${WATCHDOG_STATE_DIR%/}/qbit_watchdog_last_status"
    echo "$current_time" > "${WATCHDOG_STATE_DIR%/}/qbit_watchdog_last_restart"
    docker restart gluetun
    exit 1
fi

log_debug "Watchdog check completed successfully. Monitored ${num_torrents} torrents. All healthy."
exit 0
