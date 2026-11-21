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
WATCHDOG_STALLED_GRAB_SEC="${WATCHDOG_STALLED_GRAB_SEC:-180}"
WATCHDOG_STATE_DIR="${WATCHDOG_STATE_DIR:-/tmp}"
CONFIG_DIR="${CONFIG_DIR:-/config}"
RADARR_URL="${RADARR_URL:-http://radarr:7878}"
SONARR_URL="${SONARR_URL:-http://sonarr:8989}"
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

# Pure helper: find 0%-progress torrents stuck in metaDL/stalledDL with 0 connected seeds
# for at least <threshold_sec>. Prints "<hash>\t<name>\t<age_sec>" per line.
watchdog_find_stalled_grabs() {
    local torrents_json="${1:-[]}"
    local now="${2:-0}"
    local threshold="${3:-180}"

    [ "$threshold" -gt 0 ] 2>/dev/null || return 0
    printf '%s' "$torrents_json" | jq -r \
        --argjson now "$now" \
        --argjson thr "$threshold" '
        .[]? |
        select(
            (.state == "metaDL" or .state == "stalledDL")
            and ((.downloaded // 0) == 0)
            and ((.progress // 0) == 0)
            and ((.num_seeds // 0) == 0)
            and ((.dlspeed // 0) == 0)
            and ((.added_on // 0) > 0)
            and (($now - (.added_on // $now)) >= $thr)
        ) |
        [(.hash // ""), (.name // ""), (($now - (.added_on // $now)) | tostring)] | @tsv
    ' 2>/dev/null || true
}

_watchdog_read_arr_key() {
    local svc="$1"
    local xml="${CONFIG_DIR%/}/${svc}/config.xml"
    [ -r "$xml" ] || return 1
    sed -n 's/.*<ApiKey>\([^<]*\)<\/ApiKey>.*/\1/p' "$xml" 2>/dev/null | head -1
}

# Check Radarr & Sonarr queues for a stalled 0% torrent hash; if managed by *arr,
# remove + blocklist it and trigger an automatic search for the next release.
watchdog_failover_stalled_grab() {
    local hash="$1"
    local name="$2"
    local age="$3"
    [ -n "$hash" ] || return 1

    local svc svc_label svc_url apikey queue_json qid
    for svc in radarr sonarr; do
        if [ "$svc" = "radarr" ]; then
            svc_label="Radarr"
            svc_url="$RADARR_URL"
        else
            svc_label="Sonarr"
            svc_url="$SONARR_URL"
        fi
        apikey=$(_watchdog_read_arr_key "$svc" || true)
        [ -n "$apikey" ] || continue

        queue_json=$(curl -sS --connect-timeout 3 --max-time 10 \
            -H "X-Api-Key: $apikey" \
            "${svc_url}/api/v3/queue?pageSize=100" 2>/dev/null || true)
        [ -n "$queue_json" ] || continue

        qid=$(printf '%s' "$queue_json" | jq -r --arg h "${hash,,}" '
            [.records[]? | select(((.downloadId // "") | ascii_downcase) == $h) | .id][0] // empty
        ' 2>/dev/null || true)
        [ -n "$qid" ] || continue

        local code
        code=$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 15 \
            -X DELETE \
            -H "X-Api-Key: $apikey" \
            "${svc_url}/api/v3/queue/${qid}?removeFromClient=true&blocklist=true&skipRedownload=false" 2>/dev/null || echo "000")
        if [ "$code" = "200" ] || [ "$code" = "202" ] || [ "$code" = "204" ]; then
            log_watchdog ACTION "Stalled 0% grab failover (${age}s, 0 seeds): blocklisted '${name}' in ${svc_label} and triggered replacement search."
            return 0
        fi
    done
    return 1
}

# Reuse a persistent session cookie jar across ticks so qBittorrent 5.3's 15-session LRU
# cap does not evict interactive WebUI tabs; only log in again if missing or rejected.
# shellcheck disable=SC2329
cleanup_watchdog() {
    rm -f "${LOGIN_BODY:-}" "${TORRENTS_BODY:-}"
}

login_qbit() {
    local http_code
    (umask 077; : > "$COOKIE_JAR")
    chmod 600 "$COOKIE_JAR" 2>/dev/null || true
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

qbit_watchdog_fetch() {
    local endpoint="$1"
    local out_file="$2"
    curl -sS -o "$out_file" -w "%{http_code}" --connect-timeout 5 --max-time 15 \
        -b "$COOKIE_JAR" \
        -H "Referer: http://${QBIT_HOST}" \
        "http://${QBIT_HOST}${endpoint}" 2>/dev/null || echo "000"
}

qbit_watchdog_get() {
    local endpoint="$1"
    curl -sS --connect-timeout 5 --max-time 15 \
        -b "$COOKIE_JAR" \
        -H "Referer: http://${QBIT_HOST}" \
        "http://${QBIT_HOST}${endpoint}" 2>/dev/null || true
}

watchdog_main() {
    COOKIE_JAR="${WATCHDOG_STATE_DIR%/}/qbit_watchdog_cookie.txt"
    LOGIN_BODY=$(mktemp "${WATCHDOG_STATE_DIR%/}/qbit_watchdog_login.XXXXXX")
    TORRENTS_BODY=$(mktemp "${WATCHDOG_STATE_DIR%/}/qbit_watchdog_torrents.XXXXXX")
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

    if ! watchdog_cookie_has_sid "$COOKIE_JAR"; then
        if ! login_qbit; then
            log_watchdog ERROR "Failed to authenticate to qBittorrent API."
            echo "auth_failed" > "${WATCHDOG_STATE_DIR%/}/qbit_watchdog_last_status"
            exit 1
        fi
    fi

    local torrents_http torrents
    torrents_http=$(qbit_watchdog_fetch "/api/v2/torrents/info" "$TORRENTS_BODY")
    torrents=$(cat "$TORRENTS_BODY" 2>/dev/null || true)
    if [ "$torrents_http" = "403" ] || [ "$torrents_http" = "401" ] || \
       [ -z "$torrents" ] || ! printf '%s' "$torrents" | jq -e 'type == "array"' >/dev/null 2>&1; then
        if ! login_qbit; then
            log_watchdog ERROR "Failed to authenticate to qBittorrent API."
            echo "auth_failed" > "${WATCHDOG_STATE_DIR%/}/qbit_watchdog_last_status"
            exit 1
        fi
        torrents_http=$(qbit_watchdog_fetch "/api/v2/torrents/info" "$TORRENTS_BODY")
        torrents=$(cat "$TORRENTS_BODY" 2>/dev/null || true)
    fi

    if [ -z "$torrents" ] || ! printf '%s' "$torrents" | jq -e 'type == "array"' >/dev/null 2>&1; then
        log_watchdog ERROR "Failed to fetch valid torrent list from qBittorrent API (HTTP ${torrents_http})."
        echo "api_failed" > "${WATCHDOG_STATE_DIR%/}/qbit_watchdog_last_status"
        exit 1
    fi

    local last_status=""
    if [ -f "${WATCHDOG_STATE_DIR%/}/qbit_watchdog_last_status" ]; then
        last_status=$(cat "${WATCHDOG_STATE_DIR%/}/qbit_watchdog_last_status")
    fi
    if [ -n "$last_status" ] && [ "$last_status" != "success" ]; then
        log_watchdog INFO "Watchdog recovered: Connection to qBittorrent API restored."
    fi
    echo "success" > "${WATCHDOG_STATE_DIR%/}/qbit_watchdog_last_status"

    local num_torrents current_time last_heartbeat time_diff
    num_torrents=$(printf '%s' "$torrents" | jq 'length' 2>/dev/null || echo 0)
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

    local -a DETECTED_TORRENTS=()
    local working_count=0 hash name properties trackers is_broken is_working

    while IFS=$'\t' read -r hash name; do
        [ -z "$hash" ] && continue

        properties=$(qbit_watchdog_get "/api/v2/torrents/properties?hash=${hash}")
        trackers=$(qbit_watchdog_get "/api/v2/torrents/trackers?hash=${hash}")

        read -r is_broken is_working < <(watchdog_classify_torrent "$properties" "$trackers")
        if [ "$is_working" -eq 1 ]; then
            working_count=$((working_count + 1))
        fi
        if [ "$is_broken" -eq 1 ]; then
            DETECTED_TORRENTS+=("$name")
        fi
    done < <(printf '%s' "$torrents" | jq -r '.[] | [(.hash // ""), (.name // "")] | @tsv' 2>/dev/null || true)

    local broken_count=${#DETECTED_TORRENTS[@]}
    if [ "$broken_count" -gt 0 ]; then
        local last_restart=0 gluetun_status remaining torrent_name
        if [ -f "${WATCHDOG_STATE_DIR%/}/qbit_watchdog_last_restart" ]; then
            last_restart=$(cat "${WATCHDOG_STATE_DIR%/}/qbit_watchdog_last_restart" 2>/dev/null || echo 0)
            [[ "$last_restart" =~ ^[0-9]+$ ]] || last_restart=0
        fi

        if [ "$working_count" -gt 0 ]; then
            log_debug "Ignoring ${broken_count} stalled torrent(s): ${working_count} torrent(s) have active peers/trackers (not a global VPN failure)."
        else
            # Optional: check Gluetun's local control endpoint if open without blocking on auth
            gluetun_status=$(curl -sS --connect-timeout 2 --max-time 5 "${GLUETUN_CONTROL_URL}/v1/openvpn/status" 2>/dev/null | jq -r '.status // empty' 2>/dev/null || true)
            if [ -n "$gluetun_status" ] && [ "$gluetun_status" != "running" ]; then
                log_watchdog DETECTED "Gluetun reported VPN status '${gluetun_status}'."
            fi

            if ! watchdog_should_restart_vpn "$broken_count" "$working_count" "$current_time" "$last_restart" "$WATCHDOG_COOLDOWN_SEC"; then
                remaining=$((WATCHDOG_COOLDOWN_SEC - (current_time - last_restart)))
                log_watchdog INFO "VPN restart cooldown active (${remaining}s remaining); skipping restart for ${broken_count} stalled torrent(s)."
            else
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
        fi
    fi

    if [ "$working_count" -gt 0 ] || [ "$broken_count" -eq 0 ]; then
        local st_hash st_name st_age
        while IFS=$'\t' read -r st_hash st_name st_age; do
            [ -n "$st_hash" ] || continue
            watchdog_failover_stalled_grab "$st_hash" "$st_name" "$st_age" || true
        done < <(watchdog_find_stalled_grabs "$torrents" "$current_time" "$WATCHDOG_STALLED_GRAB_SEC")
    fi

    log_debug "Watchdog check completed successfully. Monitored ${num_torrents} torrents. All healthy."
    exit 0
}

if [ "${WATCHDOG_SOURCE_ONLY:-0}" != "1" ]; then
    watchdog_main "$@"
fi
