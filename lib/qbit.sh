#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# assemblrr qBittorrent configuration & credential management
# Requires: lib/core.sh, lib/api.sh

if [ -n "${_ASSEMBLRR_QBIT_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_QBIT_SOURCED=1

# True when this install routes qBittorrent through Gluetun.
stack_vpn_enabled() {
    case "${VPN_ENABLED:-${setup_vpn:-n}}" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

# Backwards-compatible alias
qbit_vpn_enabled() {
    stack_vpn_enabled
}

qbit_vuetorrent_enabled() {
    [ "$(qbit_ui_mode)" = "vuetorrent" ]
}

qbit_qui_enabled() {
    [ "$(qbit_ui_mode)" = "qui" ]
}

# Generate PBKDF2 password hash for qBittorrent WebUI (@ByteArray(salt:hash)).
qbit_generate_pbkdf2() {
    local password="$1"
    if [ -z "$password" ]; then
        echo ""
        return
    fi
    if command -v python3 &>/dev/null; then
        QBIT_PWD="$password" python3 -c "import hashlib, os, base64; salt = os.urandom(16); dk = hashlib.pbkdf2_hmac('sha512', os.environ.get('QBIT_PWD', '').encode('utf-8'), salt, 100000); print(f'@ByteArray({base64.b64encode(salt).decode()}:{base64.b64encode(dk).decode()})')" 2>/dev/null || echo ""
    elif command -v python &>/dev/null; then
        QBIT_PWD="$password" python -c "import hashlib, os, base64; salt = os.urandom(16); dk = hashlib.pbkdf2_hmac('sha512', os.environ.get('QBIT_PWD', '').encode('utf-8'), salt, 100000); print(f'@ByteArray({base64.b64encode(salt).decode()}:{base64.b64encode(dk).decode()})')" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

_write_qui_redirect_webui() {
    local base_dir="${1:-${install_directory:-${INSTALL_DIR:-}}}"
    [ -n "$base_dir" ] || return 1
    local pub_dir="$base_dir/config/qbittorrent/qui-redirect/public"
    mkdir -p "$pub_dir"
    cat <<'EOF' > "$pub_dir/index.html"
<!doctype html>
<html><head><meta charset="utf-8"><title>Redirecting to qui…</title>
<script>window.location.replace(window.location.protocol + "//" + window.location.hostname + ":7476/");</script>
</head><body>Redirecting to <a href=":7476/">qui (:7476)</a>…</body></html>
EOF
    cp "$pub_dir/index.html" "$pub_dir/login.html"
}

# Write qBittorrent.conf pre-start (always preserves VPN tun0 bind even if python3 is absent).
write_qbittorrent_config() {
    local base_dir="${install_directory:-${INSTALL_DIR:-}}"
    [ -n "$base_dir" ] || return 1
    local qbit_config_dir="$base_dir/config/qbittorrent/qBittorrent"
    local conf_file="$qbit_config_dir/qBittorrent.conf"
    mkdir -p "$qbit_config_dir"

    local pbkdf2_hash
    pbkdf2_hash=$(qbit_generate_pbkdf2 "${auth_password:-${AUTH_PASSWORD:-}}")
    local user="${auth_username:-${AUTH_USERNAME:-admin}}"
    local alt_ui="false"
    local alt_root=""
    if qbit_vuetorrent_enabled; then
        alt_ui="true"
        alt_root="/vuetorrent"
    elif qbit_qui_enabled; then
        _write_qui_redirect_webui "$base_dir" || true
        alt_ui="true"
        alt_root="/config/qui-redirect"
    fi

    (
        umask 077
        {
            if stack_vpn_enabled; then
                printf '[BitTorrent]\n'
                printf 'Session\\Interface=tun0\n'
                printf 'Session\\InterfaceName=tun0\n\n'
            fi
            printf '[Preferences]\n'
            printf 'WebUI\\Username=%s\n' "$user"
            if [ -n "$pbkdf2_hash" ]; then
                printf 'WebUI\\Password_PBKDF2=%s\n' "$pbkdf2_hash"
            fi
            printf 'WebUI\\Port=8081\n'
            printf 'WebUI\\SessionTimeout=2592000\n'
            printf 'WebUI\\SessionsCountLimit=1000\n'
            if [ "$alt_ui" = "true" ]; then
                printf 'WebUI\\AlternativeUIEnabled=true\n'
                printf 'WebUI\\RootFolder=%s\n' "$alt_root"
            else
                printf 'WebUI\\AlternativeUIEnabled=false\n'
            fi
        } > "$conf_file"
    )
    chmod 600 "$conf_file" 2>/dev/null || true

    if stack_vpn_enabled; then
        log_success "Pre-configured qBittorrent credentials and tun0 bind"
    elif [ -n "$pbkdf2_hash" ]; then
        log_success "Pre-configured qBittorrent credentials (bypassing WebAPI restrictions)"
    else
        log_warning "python3 unavailable — skipped qBittorrent PBKDF2 hash; WebUI temp password will be used on first boot"
    fi
}

# setPreferences JSON: save paths, ATM, tun0 (when VPN is on), VueTorrent/qui-redirect WebUI, optional creds.
qbit_core_prefs_json() {
    local user="${1:-}"
    local pass="${2:-}"
    local iface=""
    if qbit_vpn_enabled; then
        iface="tun0"
    fi
    local alt_ui=false
    local alt_path=""
    if qbit_vuetorrent_enabled; then
        alt_ui=true
        alt_path="/vuetorrent"
    elif qbit_qui_enabled; then
        alt_ui=true
        alt_path="/config/qui-redirect"
    fi

    if [ -n "$user" ]; then
        jq -nc \
            --arg iface "$iface" \
            --argjson alt_ui "$alt_ui" \
            --arg alt_path "$alt_path" \
            --arg user "$user" \
            --arg pass "$pass" \
            '({
                save_path:"/data/torrents",
                temp_path:"/data/torrents/incomplete",
                temp_path_enabled:true,
                auto_tmm_enabled:true,
                current_network_interface:$iface,
                alternative_webui_enabled:$alt_ui,
                web_ui_session_timeout:2592000,
                web_ui_sessions_count_limit:1000,
                web_ui_username:$user,
                web_ui_password:$pass
            } + (if $alt_ui then {alternative_webui_path:$alt_path} else {} end))'
    else
        jq -nc \
            --arg iface "$iface" \
            --argjson alt_ui "$alt_ui" \
            --arg alt_path "$alt_path" \
            '({
                save_path:"/data/torrents",
                temp_path:"/data/torrents/incomplete",
                temp_path_enabled:true,
                auto_tmm_enabled:true,
                current_network_interface:$iface,
                alternative_webui_enabled:$alt_ui,
                web_ui_session_timeout:2592000,
                web_ui_sessions_count_limit:1000
            } + (if $alt_ui then {alternative_webui_path:$alt_path} else {} end))'
    fi
}

qbit_login_form() {
    local cookie_jar="$1"
    local user="$2"
    local pass="$3"
    local qbit_port="${4:-8081}"
    http_request POST "http://${API_HOST}:${qbit_port}/api/v2/auth/login" \
        -c "$cookie_jar" \
        -H "Referer: http://${API_HOST}:${qbit_port}" \
        --data-urlencode "username=${user}" \
        --data-urlencode "password=${pass}" || return 1
}

qbit_apply_prefs() {
    local cookie_jar="$1"
    local user="${2:-}"
    local pass="${3:-}"
    local qbit_port=8081
    local json
    json=$(qbit_core_prefs_json "$user" "$pass")
    if ! http_request POST "http://${API_HOST}:${qbit_port}/api/v2/app/setPreferences" \
        -b "$cookie_jar" \
        -H "Referer: http://${API_HOST}:${qbit_port}" \
        --data-urlencode "json=${json}"; then
        log_warning "qBittorrent: setPreferences failed (HTTP ${HTTP_STATUS})"
        return 1
    fi
    return 0
}

_qbit_latest_temp_password() {
    run_docker logs qbittorrent 2>&1 \
        | awk -F': ' '/temporary password is provided for this session:/ { pw=$NF } END { if (pw) print pw }' \
        || true
}

# Set qBittorrent WebUI credentials, save paths, and VPN interface.
qbit_set_credentials() {
    local qbit_port=8081
    local qbit_cookie_jar
    qbit_cookie_jar=$(mktemp)

    if [ -n "${AUTH_USERNAME:-}" ] && [ -n "${AUTH_PASSWORD:-}" ]; then
        qbit_login_form "$qbit_cookie_jar" "$AUTH_USERNAME" "$AUTH_PASSWORD" "$qbit_port" || true
        local qbit_sid
        qbit_sid=$(qbit_cookie_sid "$qbit_cookie_jar")
        if [ -n "$qbit_sid" ]; then
            if ! qbit_apply_prefs "$qbit_cookie_jar"; then
                rm -f "$qbit_cookie_jar"
                return 1
            fi
            if qbit_vpn_enabled; then
                _cfg_log_info "qBittorrent credentials already set; BitTorrent bound to tun0"
            else
                _cfg_log_info "qBittorrent credentials already set"
            fi
            rm -f "$qbit_cookie_jar"
            return 0
        fi
    fi

    local wait_time=0 max_wait=60
    while [ "$wait_time" -lt "$max_wait" ]; do
        local qbit_temp_pass
        qbit_temp_pass=$(_qbit_latest_temp_password)
        if [ -n "$qbit_temp_pass" ]; then
            qbit_login_form "$qbit_cookie_jar" "admin" "$qbit_temp_pass" "$qbit_port" || true
            local qbit_sid
            qbit_sid=$(qbit_cookie_sid "$qbit_cookie_jar")
            if [ -n "$qbit_sid" ]; then
                if ! qbit_apply_prefs "$qbit_cookie_jar" "$AUTH_USERNAME" "$AUTH_PASSWORD"; then
                    rm -f "$qbit_cookie_jar"
                    return 1
                fi
                echo >&2
                if qbit_vpn_enabled; then
                    _cfg_log_info "Set qBittorrent credentials, save path, and tun0 bind"
                else
                    _cfg_log_info "Set qBittorrent credentials and save path"
                fi
                rm -f "$qbit_cookie_jar"
                return 0
            fi
        fi
        wait_inline "Waiting for qBittorrent to initialize" "$wait_time"
        sleep 3
        wait_time=$((wait_time + 3))
    done
    echo >&2
    log_warning "Could not login to qBittorrent with temp password"
    rm -f "$qbit_cookie_jar"
    return 1
}

qbit_try_login() {
    local user="$1"
    local pass="$2"
    local cookie_jar="$3"
    local qbit_port=8081

    [ -n "$user" ] && [ -n "$pass" ] || return 1
    : >"$cookie_jar"
    qbit_login_form "$cookie_jar" "$user" "$pass" "$qbit_port" || return 1
    [ -n "$(qbit_cookie_sid "$cookie_jar")" ]
}

qbit_change_credentials() {
    local old_user="$1"
    local old_pass="$2"
    local new_user="$3"
    local new_pass="$4"
    local cookie_jar verify_jar

    if [ -z "$new_user" ] || [ -z "$new_pass" ]; then
        log_step_fail "qBittorrent: new credentials missing"
        return 1
    fi

    cookie_jar=$(mktemp)
    verify_jar=$(mktemp)

    if ! qbit_try_login "$old_user" "$old_pass" "$cookie_jar"; then
        if qbit_try_login "$new_user" "$new_pass" "$cookie_jar"; then
            qbit_apply_prefs "$cookie_jar" || true
            rm -f "$cookie_jar" "$verify_jar"
            log_step "qBittorrent: already using the new password"
            return 0
        fi
        local qbit_temp_pass
        qbit_temp_pass=$(_qbit_latest_temp_password)
        if [ -z "$qbit_temp_pass" ] || ! qbit_try_login "admin" "$qbit_temp_pass" "$cookie_jar"; then
            rm -f "$cookie_jar" "$verify_jar"
            log_step_fail "qBittorrent: could not log in with the old password"
            return 1
        fi
    fi

    qbit_apply_prefs "$cookie_jar" "$new_user" "$new_pass" || true
    rm -f "$cookie_jar"

    if qbit_try_login "$new_user" "$new_pass" "$verify_jar"; then
        rm -f "$verify_jar"
        log_step "qBittorrent: set login (${new_user})"
        return 0
    fi
    rm -f "$verify_jar"
    log_step_fail "qBittorrent: password change did not stick"
    return 1
}

qbit_create_category() {
    local service_name="$1"
    local category="$2"
    local save_path="$3"

    local qbit_port=8081
    local qbit_cookie_jar
    qbit_cookie_jar=$(mktemp)

    qbit_login_form "$qbit_cookie_jar" "$AUTH_USERNAME" "$AUTH_PASSWORD" "$qbit_port" || true
    local qbit_sid
    qbit_sid=$(qbit_cookie_sid "$qbit_cookie_jar")
    if [ -z "$qbit_sid" ]; then
        log_step_fail "${service_name}: could not login to qBittorrent to create categories"
        rm -f "$qbit_cookie_jar"
        return 1
    fi

    local created=0 edited=0
    if http_request POST "http://${API_HOST}:${qbit_port}/api/v2/torrents/createCategory" \
        -b "$qbit_cookie_jar" -H "Referer: http://${API_HOST}:${qbit_port}" \
        --data-urlencode "category=${category}" --data-urlencode "savePath=${save_path}"; then
        created=1
    fi
    if http_request POST "http://${API_HOST}:${qbit_port}/api/v2/torrents/editCategory" \
        -b "$qbit_cookie_jar" -H "Referer: http://${API_HOST}:${qbit_port}" \
        --data-urlencode "category=${category}" --data-urlencode "savePath=${save_path}"; then
        edited=1
    fi
    rm -f "$qbit_cookie_jar"

    if [ "$created" -eq 1 ] || [ "$edited" -eq 1 ]; then
        log_step "${service_name}: qBittorrent '${category}' category → ${save_path}"
        return 0
    fi
    log_step_fail "${service_name}: failed to set qBittorrent '${category}' category (HTTP ${HTTP_STATUS})"
    return 1
}

# --- Standalone qui (qBittorrent WebUI) configuration ---

_qui_secret_path() {
    local base="${INSTALL_DIR:-${install_directory:-}}"
    if [ -n "$base" ]; then
        printf '%s/secrets/qui_password.txt\n' "$base"
    fi
    return 0
}

_qui_login_password() {
    if [ -n "${QUI_PASSWORD:-}" ]; then
        printf '%s' "$QUI_PASSWORD"
        return 0
    fi
    local sp
    sp=$(_qui_secret_path)
    if [ -n "$sp" ] && [ -s "$sp" ]; then
        cat "$sp" 2>/dev/null || true
        return 0
    fi
    printf '%s' "${AUTH_PASSWORD:-}"
}

_qui_is_up() {
    http_request GET "http://${API_HOST}:${_QUI_PORT:-7476}/health"
}

# Authenticated JSON call against qui (X-Requested-With required by qui CSRF middleware).
_qui_api() {
    local method="$1"
    local port="$2"
    local path="$3"
    local jar="$4"
    shift 4
    http_request "$method" "http://${API_HOST}:${port}${path}" \
        -b "$jar" \
        -H "Content-Type: application/json" \
        -H "X-Requested-With: XMLHttpRequest" \
        "$@"
}

# Build Create/Update instance JSON payload for qui /api/instances.
qui_build_instance_payload() {
    local host_url="$1"
    local user="$2"
    local pass="$3"
    jq -nc \
        --arg name "qBittorrent" \
        --arg host "$host_url" \
        --arg u "$user" \
        --arg p "$pass" \
        '{name:$name,host:$host,username:$u,password:$p,hasLocalFilesystemAccess:true}'
}

_qui_login() {
    local jar="$1"
    local user="$2"
    local pass="$3"
    local port="${4:-7476}"
    local payload
    payload=$(jq -nc --arg u "$user" --arg p "$pass" '{username:$u,password:$p,remember_me:false}')
    : >"$jar"
    http_request POST "http://${API_HOST}:${port}/api/auth/login" \
        -c "$jar" -H "Content-Type: application/json" -H "X-Requested-With: XMLHttpRequest" -d "$payload" || return 1
}

# Write/update the single qui user (id=1) in config/qui/qui.db with an Argon2id hash.
# Upstream qui's HTTP /api/auth/setup & /api/auth/change-password enforce >=8 chars,
# whereas /api/auth/login verifies the stored Argon2id hash of any length. Writing
# the Argon2id hash directly preserves "one username/password for the whole stack".
_qui_sync_db_user() {
    local user="$1"
    local pass="$2"
    local base="${INSTALL_DIR:-${install_directory:-}}"
    [ -n "$base" ] && [ -n "$user" ] && [ -n "$pass" ] || return 1
    local db_path="$base/config/qui/qui.db"
    [ -f "$db_path" ] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    command -v openssl >/dev/null 2>&1 || return 1

    QUI_DB_PATH="$db_path" QUI_DB_USER="$user" QUI_DB_PASS="$pass" python3 - <<'PY' >/dev/null 2>&1
import base64, os, sqlite3, subprocess

db_path = os.environ["QUI_DB_PATH"]
user = os.environ["QUI_DB_USER"]
pw = os.environ["QUI_DB_PASS"]

salt = os.urandom(16)
out_hex = subprocess.check_output([
    "openssl", "kdf", "-keylen", "32",
    "-kdfopt", f"pass:{pw}",
    "-kdfopt", f"hexsalt:{salt.hex()}",
    "-kdfopt", "iter:3",
    "-kdfopt", "memcost:65536",
    "-kdfopt", "lanes:2",
    "-kdfopt", "threads:1",
    "ARGON2ID",
], stderr=subprocess.DEVNULL).decode().strip().replace(":", "")
salt_b64 = base64.b64encode(salt).decode().rstrip("=")
hash_b64 = base64.b64encode(bytes.fromhex(out_hex)).decode().rstrip("=")
encoded = f"$argon2id$v=19$m=65536,t=3,p=2${salt_b64}${hash_b64}"

con = sqlite3.connect(db_path, timeout=10)
cur = con.cursor()
cur.execute("""CREATE TABLE IF NOT EXISTS user (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
)""")
cur.execute("SELECT id FROM user WHERE id = 1")
if cur.fetchone():
    cur.execute("UPDATE user SET username = ?, password_hash = ?, updated_at = CURRENT_TIMESTAMP WHERE id = 1", (user, encoded))
else:
    cur.execute("INSERT INTO user (id, username, password_hash) VALUES (1, ?, ?)", (user, encoded))
con.commit()
con.close()
PY
}

configure_qui() {
    qbit_qui_enabled || return 0
    local qui_port="${1:-7476}"
    _QUI_PORT="$qui_port"

    local qui_user="${QUI_USERNAME:-${AUTH_USERNAME:-}}"
    local qui_pass="${QUI_PASSWORD:-${AUTH_PASSWORD:-}}"
    local secret_path
    secret_path=$(_qui_secret_path)
    [ -n "$secret_path" ] && rm -f "$secret_path" 2>/dev/null || true

    if [ -z "$qui_user" ] || [ -z "$qui_pass" ]; then
        log_step_fail "qui: auth credentials missing"
        return 1
    fi

    if ! wait_until "Waiting for qui UI" 60 2 _qui_is_up; then
        log_step_fail "qui: API not ready on port ${qui_port}"
        return 1
    fi

    local jar
    jar=$(mktemp)
    if ! _qui_login "$jar" "$qui_user" "$qui_pass" "$qui_port"; then
        local boot_pass="$qui_pass"
        [ "${#boot_pass}" -lt 8 ] && boot_pass="${qui_pass}__assemblrr_init"
        local setup_payload
        setup_payload=$(jq -nc --arg u "$qui_user" --arg p "$boot_pass" '{username:$u,password:$p}')
        http_request POST "http://${API_HOST}:${qui_port}/api/auth/setup" \
            -c "$jar" -H "Content-Type: application/json" -H "X-Requested-With: XMLHttpRequest" -d "$setup_payload" || true
        if [ "$boot_pass" != "$qui_pass" ] || ! _qui_login "$jar" "$qui_user" "$qui_pass" "$qui_port"; then
            _qui_sync_db_user "$qui_user" "$qui_pass" || true
        fi
        if ! _qui_login "$jar" "$qui_user" "$qui_pass" "$qui_port"; then
            rm -f "$jar"
            log_step_fail "qui: could not initialize or log in as ${qui_user} (HTTP ${HTTP_STATUS})"
            return 1
        fi
    fi

    local qbit_url="http://qbittorrent:8081"
    if qbit_vpn_enabled; then
        qbit_url="http://gluetun:8081"
    fi

    local instances="" existing_id=""
    if _qui_api GET "$qui_port" "/api/instances" "$jar"; then
        instances="$HTTP_BODY"
        existing_id=$(printf '%s' "$instances" | jq -r \
            '[.[]? | select(.name == "qBittorrent" or ((.host // "") | contains(":8081")))][0].id // empty' \
            2>/dev/null || true)
    fi

    local payload ok=0
    payload=$(qui_build_instance_payload "$qbit_url" "$AUTH_USERNAME" "$AUTH_PASSWORD")
    if [ -n "$existing_id" ]; then
        if _qui_api PUT "$qui_port" "/api/instances/${existing_id}" "$jar" -d "$payload"; then
            ok=1
        fi
    else
        if _qui_api POST "$qui_port" "/api/instances" "$jar" -d "$payload"; then
            ok=1
        fi
    fi

    rm -f "$jar"
    if [ "$ok" -eq 1 ]; then
        log_step "qui: wired qBittorrent instance (${qbit_url})"
        return 0
    fi
    log_step_fail "qui: failed to register qBittorrent instance (HTTP ${HTTP_STATUS})"
    return 1
}

qui_change_credentials() {
    local old_user="$1"
    local old_pass="$2"
    local new_user="$3"
    local new_pass="$4"
    local qui_port="${5:-7476}"

    qbit_qui_enabled || return 0
    if [ -z "$new_user" ] || [ -z "$new_pass" ]; then
        log_step_fail "qui: new credentials missing"
        return 1
    fi

    local secret_path
    secret_path=$(_qui_secret_path)
    [ -n "$secret_path" ] && rm -f "$secret_path" 2>/dev/null || true

    local updated=0
    if _qui_sync_db_user "$new_user" "$new_pass"; then
        updated=1
    elif [ "$old_user" = "$new_user" ] && [ "${#new_pass}" -ge 8 ]; then
        local jar
        jar=$(mktemp)
        if _qui_login "$jar" "$old_user" "$old_pass" "$qui_port"; then
            local ch_payload
            ch_payload=$(jq -nc --arg c "$old_pass" --arg n "$new_pass" '{currentPassword:$c,newPassword:$n}')
            if _qui_api PUT "$qui_port" "/api/auth/change-password" "$jar" -d "$ch_payload"; then
                updated=1
            fi
        fi
        rm -f "$jar"
    fi

    if [ "$updated" -eq 0 ]; then
        log_step_fail "qui: password change failed"
        return 1
    fi

    QUI_USERNAME="$new_user" QUI_PASSWORD="$new_pass" \
        AUTH_USERNAME="$new_user" AUTH_PASSWORD="$new_pass" \
        configure_qui "$qui_port" || return 1
    log_step "qui: updated credentials for ${new_user}"
    return 0
}
