#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Unit tests for bin/cli.sh (help, source-safety, archive validation, show_config)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../helpers.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

test_suite "cli.sh --help works without existing install tree"
help_out=$(HOME="$tmp" ASSEMBLRR_DIR="" bash "$REPO_ROOT/bin/cli.sh" --help)
assert_contains "$help_out" "Lifecycle:" "grouped help shows Lifecycle"
assert_contains "$help_out" "Configuration & Upgrades:" "grouped help shows Configuration"
assert_contains "$help_out" "Operations & Backups:" "grouped help shows Operations"
assert_contains "$help_out" "config [show|edit|apply]" "lists config subcommands"

help_short=$(HOME="$tmp" ASSEMBLRR_DIR="" bash "$REPO_ROOT/bin/cli.sh" -h)
assert_eq "$help_out" "$help_short" "-h matches --help deterministically"

test_suite "cli.sh can be sourced without running main or needing install dir"
# shellcheck source=/dev/null
source "$REPO_ROOT/bin/cli.sh"
INSTALL_DIR="$tmp/inst"
MEDIA_DIRECTORY="$tmp/media"
mkdir -p "$INSTALL_DIR" "$MEDIA_DIRECTORY"
cfg_out=$(ASSEMBLRR_SHOW_LEFTOVERS=0 show_config)
assert_contains "$cfg_out" "Media service:      jellyfin" "show_config displays jellyfin"
assert_contains "$cfg_out" "SABnzbd / Usenet:" "show_config displays new feature rows"

test_suite "validate_backup_archive rejects missing .env and path traversal"
bad_noenv="$tmp/noenv.tar.gz"
mkdir -p "$tmp/b1"
touch "$tmp/b1/foo.txt"
tar -czf "$bad_noenv" -C "$tmp/b1" .
assert_failure "rejects archive missing .env" validate_backup_archive "$bad_noenv"

bad_trav="$tmp/trav.tar.gz"
python3 - "$bad_trav" <<'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w:gz") as tf:
    info = tarfile.TarInfo("../evil.txt")
    data = b"x"
    info.size = len(data)
    tf.addfile(info, io.BytesIO(data))
PY
assert_failure "rejects archive with .. traversal" validate_backup_archive "$bad_trav"

good_arc="$tmp/good.tar.gz"
mkdir -p "$tmp/b2"
echo "PUID=1000" > "$tmp/b2/.env"
tar -czf "$good_arc" -C "$tmp/b2" .
assert_success "accepts valid backup containing .env" validate_backup_archive "$good_arc"

test_suite "update_containers explains pinned images"
uc_fn=$(sed -n '/^update_containers()/,/^}/p' "$REPO_ROOT/bin/cli.sh")
assert_contains "$uc_fn" "pins core service image tags" "mentions pinned core images"
assert_contains "$uc_fn" "upgrade" "points users to assemblrr upgrade"

test_suite "read_prompt 1-arg REPLY and interactive uninstall_app cancel"
REPLY=""
read_prompt "Confirm: " <<< "yes"
assert_eq "yes" "$REPLY" "1-arg read_prompt populates REPLY under set -u"
uninst_out=$(ASSEMBLRR_SHOW_LEFTOVERS=0 HOME="$tmp" uninstall_app <<< "no" 2>&1)
assert_contains "$uninst_out" "Uninstall cancelled." "1-arg read_prompt in uninstall_app cancels cleanly"
assert_true "INSTALL_DIR preserved on cancel" "[ -d \"$INSTALL_DIR\" ]"
uninst_fn=$(sed -n '/^uninstall_app()/,/^}/p' "$REPO_ROOT/bin/cli.sh")
assert_not_contains "$uninst_fn" "Type the full path" "does not require typing full paths"
assert_contains "$uninst_fn" "wait_while" "shows live spinner while stopping containers"

test_suite "status --help documents --all and --docker"
status_help=$(check_status --help)
assert_contains "$status_help" "--all" "status help documents --all"
assert_contains "$status_help" "--docker" "status help documents --docker"

test_suite "check_vpn works with wget-only gluetun and surfaces clear errors"
_orig_run_docker=$(declare -f run_docker)
_orig_log_error=$(declare -f log_error)
stub_log_error_no_exit

# Case 1: VPN disabled fails immediately with clear message
VPN_ENABLED=n
out=$(check_vpn 2>&1) || true
assert_contains "$out" "VPN is not enabled" "reports when VPN is disabled"

# Case 2: Gluetun stopped fails immediately without retry delay
VPN_ENABLED=y
# shellcheck disable=SC2329
run_docker() {
    if [ "${1:-}" = "inspect" ]; then
        echo "false"
        return 0
    fi
    return 1
}
out=$(check_vpn 2>&1) || true
assert_contains "$out" "Gluetun container is not running" "reports stopped gluetun immediately"

# Case 3: Gluetun has only wget (no curl) -> check_vpn compares VPN IP vs host IP
_mock_bin="$tmp/vpn-mock-bin"
_fake_gluetun="$tmp/fake-gluetun-bin"
mkdir -p "$_mock_bin" "$_fake_gluetun"
ln -sf "$(command -v sh)" "$_fake_gluetun/sh"
ln -sf "$(command -v grep)" "$_fake_gluetun/grep"
cat > "$_fake_gluetun/wget" <<'WEOF'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
    echo "GNU Wget 1.25.0"
    exit 0
fi
echo "203.0.113.42"
WEOF
chmod +x "$_fake_gluetun/wget"

cat > "$_mock_bin/curl" <<'EOF'
#!/bin/sh
echo "198.51.100.10"
EOF
chmod +x "$_mock_bin/curl"

# shellcheck disable=SC2329
run_docker() {
    case "${1:-}" in
        inspect)
            echo "true"
            return 0
            ;;
        exec)
            shift # exec
            shift # gluetun
            PATH="$_fake_gluetun" "$@"
            return $?
            ;;
    esac
    return 1
}
out=$(PATH="$_mock_bin:$PATH" check_vpn 2>&1) || true
assert_contains "$out" "Your real IP: 198.51.100.10" "prints real public IP"
assert_contains "$out" "VPN exit IP:  203.0.113.42" "prints VPN exit IP from wget-only gluetun"
assert_contains "$out" "VPN is active and routing traffic correctly!" "confirms active VPN routing"

# Case 4: Matching IP warns and returns non-zero
cat > "$_mock_bin/curl" <<'EOF'
#!/bin/sh
echo "203.0.113.42"
EOF
leak_rc=0
out=$(PATH="$_mock_bin:$PATH" check_vpn 2>&1) || leak_rc=$?
assert_eq "1" "$leak_rc" "returns non-zero when VPN IP matches host IP"
assert_contains "$out" "VPN IP matches your real IP" "warns on IP match"

# Case 5: Missing curl and wget inside gluetun fails cleanly instead of silent exit
# shellcheck disable=SC2329
run_docker() {
    case "${1:-}" in
        inspect) echo "true"; return 0 ;;
        exec) return 127 ;;
    esac
}
miss_rc=0
out=$(PATH="$_mock_bin:$PATH" check_vpn 2>&1) || miss_rc=$?
assert_eq "1" "$miss_rc" "returns non-zero when container lacks curl/wget"
assert_contains "$out" "neither curl nor wget" "explains missing HTTP client in container"

eval "$_orig_run_docker"
eval "$_orig_log_error"

test_suite "service_live_snapshot & service_live_format_panel render dynamic service states"
VPN_ENABLED=y USENET_ENABLED=n BYPARR_ENABLED=n QBIT_UI=vuetorrent
rows_mixed=$'jellyfin\trunning\thealthy\nseerr\trunning\tstarting\nseerr-gateway\tcreated\t\ngluetun\trunning\tstarting\nqbittorrent\tcreated\t\nradarr\trunning\thealthy\nmycustom\trunning\tunhealthy'
snap=$(service_live_snapshot "waiting" "$rows_mixed")
assert_contains "$snap" "jellyfin|Jellyfin|healthy|1|" "healthy service marked ready"
assert_contains "$snap" "seerr|Seerr (internal)|starting|0|healthcheck pending" "starting service shows healthcheck pending"
assert_contains "$snap" "seerr-gateway|Seerr|created|0|waiting on seerr" "seerr-gateway shows dependency on seerr"
assert_contains "$snap" "qbittorrent|qBittorrent|created|0|waiting on gluetun" "qbittorrent shows dependency on gluetun"
assert_contains "$snap" "bazarr|Bazarr|missing|0|" "missing container marked missing in waiting phase"
assert_contains "$snap" "mycustom|mycustom|unhealthy|0|needs attention" "custom service included and flagged unhealthy"

snap_starting=$(service_live_snapshot "starting" $'gluetun\trunning\tstarting')
assert_contains "$snap_starting" "bazarr|Bazarr|pending|0|creating" "uncreated container shows pending during starting phase"

snap_filtered=$(service_live_snapshot "waiting" "$rows_mixed" "radarr" "seerr")
assert_contains "$snap_filtered" "radarr|Radarr|healthy|1|" "filtered snapshot keeps radarr"
assert_contains "$snap_filtered" "seerr|Seerr (internal)|starting|0|" "filtered snapshot keeps seerr"
assert_not_contains "$snap_filtered" "jellyfin|" "filtered snapshot omits unselected services"

panel_1col=$(service_live_format_panel "$snap" "Waiting for services" 12 30 90 0)
assert_contains "$panel_1col" "SERVICE" "1-col layout shows table header on tall terminal"
assert_contains "$panel_1col" "✓ Jellyfin" "1-col layout shows check icon for healthy"
assert_contains "$panel_1col" "◐ Seerr (internal)" "1-col layout shows spinner icon for starting"
assert_contains "$panel_1col" "waiting on gluetun" "1-col layout shows dependency detail"
assert_contains "$panel_1col" "Waiting for services:" "1-col layout shows ready counter and elapsed seconds"

panel_2col=$(service_live_format_panel "$snap" "Waiting for services" 12 14 90 0)
assert_not_contains "$panel_2col" "SERVICE              STATE" "2-col compact grid omits verbose header on short terminal"
assert_contains "$panel_2col" "Waiting for services:" "2-col compact grid shows ready counter"

panel_1line=$(service_live_format_panel "$snap" "Waiting for services" 12 4 60 0)
assert_eq "1" "$(printf '%s\n' "$panel_1line" | wc -l)" "tiny terminal collapses to 1 line"
assert_contains "$panel_1line" "pending:" "tiny terminal lists pending services"

test_suite "wait_for_services & wait_while_services dynamically track transitions"
_orig_status_rows=$(declare -f _status_compose_rows)
_state_counter="$tmp/wait_tick"
echo 0 > "$_state_counter"
# shellcheck disable=SC2329
_status_compose_rows() {
    local n
    n=$(cat "$_state_counter")
    n=$((n + 1))
    echo "$n" > "$_state_counter"
    if [ "$n" -eq 1 ]; then
        printf 'radarr\trunning\tstarting\nsonarr\trunning\thealthy\n'
    else
        printf 'radarr\trunning\thealthy\nsonarr\trunning\thealthy\n'
    fi
}
ASSEMBLRR_WAIT_INTERVAL=0
out=$(wait_for_services radarr sonarr 2>&1)
assert_contains "$out" "Waiting for services: 1/2 ready" "logs non-TTY progress while radarr starting"
assert_contains "$out" "waiting: Radarr (starting)" "lists pending service in non-TTY update"
assert_contains "$out" "All 2 services ready" "finishes once all target services become healthy"

WAIT_WHILE_OUTPUT=""
ASSEMBLRR_LIVE_TARGETS="radarr sonarr"
ASSEMBLRR_WAIT_INTERVAL=0.05
wait_while_services "Starting radarr" bash -c 'echo compose-ok; sleep 0.2' 2>"$tmp/ww.log"
out_ww=$(cat "$tmp/ww.log")
assert_eq "compose-ok" "$WAIT_WHILE_OUTPUT" "wait_while_services captures command output"
assert_contains "$out_ww" "Starting radarr:" "wait_while_services emits live status"

rc_fail=0
wait_while_services "Fail test" bash -c 'echo fail-line; exit 4' >/dev/null 2>&1 || rc_fail=$?
assert_eq "4" "$rc_fail" "wait_while_services propagates failure exit status"
assert_eq "fail-line" "$WAIT_WHILE_OUTPUT" "wait_while_services preserves failure output"
ASSEMBLRR_LIVE_TARGETS=""
eval "$_orig_status_rows"

test_suite "wait_for_services PTY redraw updates in place and restores cursor"
pty_tick="$tmp/pty_tick"
echo 0 > "$pty_tick"
pty_live=$(python3 - "$REPO_ROOT/bin/cli.sh" "$pty_tick" <<'PY'
import os, pty, select, subprocess, sys, time

cli_sh, tick_file = sys.argv[1], sys.argv[2]
script = f"""
source '{cli_sh}'
VPN_ENABLED=n USENET_ENABLED=n BYPARR_ENABLED=n QBIT_UI=stock
_status_compose_rows() {{
    local n
    n=$(cat '{tick_file}')
    n=$((n + 1))
    echo "$n" > '{tick_file}'
    if [ "$n" -eq 1 ]; then
        printf 'radarr\\trunning\\tstarting\\nsonarr\\trunning\\thealthy\\n'
    else
        printf 'radarr\\trunning\\thealthy\\nsonarr\\trunning\\thealthy\\n'
    fi
}}
ASSEMBLRR_WAIT_INTERVAL=0.1
wait_for_services radarr sonarr
"""
master, slave = pty.openpty()
env = dict(os.environ)
env["TERM"] = "xterm-256color"
env.pop("NO_COLOR", None)
p = subprocess.Popen(
    ["bash", "-c", script],
    stdin=slave, stdout=slave, stderr=slave,
    env=env,
    start_new_session=True, close_fds=True,
)
os.close(slave)
out = b""
deadline = time.time() + 5.0
while time.time() < deadline:
    r, _, _ = select.select([master], [], [], 0.1)
    if r:
        try:
            chunk = os.read(master, 4096)
            if not chunk:
                break
            out += chunk
        except OSError:
            break
    elif p.poll() is not None:
        break
os.close(master)
rc = p.wait(timeout=3)
text = out.decode("utf-8", "replace")
print(f"RC={rc}")
print("HAS_HIDE_CURSOR=" + str("\x1b[?25l" in text))
print("HAS_SHOW_CURSOR=" + str("\x1b[?25h" in text))
print("HAS_CLEAR_PANEL=" + str("\x1b[J" in text))
print("HAS_READY=" + str("All 2 services ready" in text))
PY
)
assert_contains "$pty_live" "RC=0" "PTY wait_for_services exits 0"
assert_contains "$pty_live" "HAS_HIDE_CURSOR=True" "PTY hides cursor during redraw"
assert_contains "$pty_live" "HAS_SHOW_CURSOR=True" "PTY restores cursor on exit"
assert_contains "$pty_live" "HAS_CLEAR_PANEL=True" "PTY clears temporary live panel"
assert_contains "$pty_live" "HAS_READY=True" "PTY prints final ready message"

test_summary
