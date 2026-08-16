#!/bin/bash
# assemblrr core library — sourced by all other lib modules and entry points
# Provides: color codes, logging, safe_source, find_install_directory,
#           path utilities, directory helpers, wait_inline

# Guard against double-sourcing (readonly arrays would fail on re-source)
if [ -n "${_ASSEMBLRR_CORE_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_CORE_SOURCED=1

# --- Color codes ---
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# --- Logging ---
# Optional: set LOG_FILE before sourcing lib/core.sh to enable file logging
_log_to_file() {
    if [ -n "${LOG_FILE:-}" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    fi
    return 0
}
log_success() { echo -e "${GREEN}$1${NC}"; _log_to_file "INFO: $1"; return 0; }
log_error()   { echo -e "${RED}$1${NC}" >&2; _log_to_file "ERROR: $1"; exit 1; }
log_warning() { echo -e "${YELLOW}$1${NC}"; _log_to_file "WARN: $1"; return 0; }
log_info()    { echo "$1"; _log_to_file "INFO: $1"; return 0; }
log_debug()   { _log_to_file "DEBUG: $1"; return 0; }

# --- Progress indicators ---
# Rewrite the current line as "Waiting for Radarr API (12s)".
wait_inline() {
    local label="$1"
    local secs="${2:-0}"
    printf '\r%s (%ss)   ' "$label" "$secs" >&2
}

# Run a command while updating wait_inline every second.
# Captures stdout+stderr in WAIT_WHILE_OUTPUT. Returns the command's exit status.
wait_while() {
    local label="$1"
    shift
    local out ticker rc=0 had_errexit=0
    [ $# -gt 0 ] || return 1
    out=$(mktemp)
    [[ $- == *e* ]] && had_errexit=1
    (
        secs=0
        trap 'exit 0' TERM INT
        while true; do
            wait_inline "$label" "$secs"
            sleep 1
            secs=$((secs + 1))
        done
    ) &
    ticker=$!
    set +e
    "$@" >"$out" 2>&1
    rc=$?
    [ "$had_errexit" = 1 ] && set -e
    kill "$ticker" 2>/dev/null || true
    wait "$ticker" 2>/dev/null || true
    echo >&2
    WAIT_WHILE_OUTPUT=$(cat "$out" 2>/dev/null || true)
    rm -f "$out"
    return "$rc"
}

# --- Safe source ---
# Safely source a config file — validates that it contains only KEY=VALUE
# assignments (no command substitution, pipes, etc.) before sourcing
safe_source() {
    local file="$1"
    if [ ! -f "$file" ]; then
        return 1
    fi

    local line
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        # Skip blank lines and comments
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        # Must match KEY=VALUE pattern (KEY: alphanumeric + underscore)
        if ! [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            echo -e "${RED}Rejecting unsafe line in $file: $line${NC}" >&2
            return 1
        fi

        # Reject dangerous shell constructs in the value
        case "$line" in
            *'$('* | *'`'* | *';'* | *'||'* | *'&&'* | *'>'* | *'<'*)
                echo -e "${RED}Rejecting unsafe line in $file: $line${NC}" >&2
                return 1
                ;;
        esac
    done < "$file"

    # Strip CR so a .env written from a Windows clone / drvfs mount can be sourced
    # shellcheck disable=SC1090
    source <(tr -d '\r' < "$file")
}

# --- Install directory discovery ---
# Discover installation directory from runtime config
find_install_directory() {
    # Prefer the home pointer over $HOME/assemblrr so a leftover default tree
    # from the VPN bootstrap cannot shadow a later non-default install path.
    local search_order=(
        "/opt/assemblrr/.assemblrr-config"
        "$HOME/.assemblrr-config"
        "$HOME/assemblrr/.assemblrr-config"
    )

    # Check ASSEMBLRR_DIR env var first
    if [ -n "${ASSEMBLRR_DIR:-}" ]; then
        echo "$ASSEMBLRR_DIR"
        return 0
    fi

    for config_file in "${search_order[@]}"; do
        if [ -f "$config_file" ]; then
            safe_source "$config_file"
            if [ -n "${INSTALL_DIRECTORY:-}" ]; then
                echo "$INSTALL_DIRECTORY"
                return 0
            fi
        fi
    done

    echo ""
    return 1
}

# Home pointer so the CLI can find a non-default (or mid-setup) install.
# Includes MEDIA_DIRECTORY so uninstall --media can see an external drive
# even if the install tree was never finished.
write_install_pointer() {
    local install_dir="$1"
    local media_dir="${2:-}"
    local pointer="$HOME/.assemblrr-config"
    {
        printf 'INSTALL_DIRECTORY="%s"\n' "$install_dir"
        if [ -n "$media_dir" ]; then
            printf 'MEDIA_DIRECTORY="%s"\n' "$media_dir"
        fi
    } > "$pointer"
    chmod 600 "$pointer"
}

load_install_pointer() {
    local pointer=""
    if [ -f "$HOME/.assemblrr-config" ]; then
        pointer="$HOME/.assemblrr-config"
    elif [ -f "$HOME/.${APP_NAME:-assemblrr}-config" ]; then
        pointer="$HOME/.${APP_NAME:-assemblrr}-config"
    else
        return 1
    fi
    safe_source "$pointer"
}

is_assemblrr_install_tree() {
    local d="$1"
    local name="${APP_NAME:-assemblrr}"
    [ -d "$d" ] || return 1
    [ "$(basename "$d")" = "$name" ] || return 1
    if [ -f "$d/.assemblrr-config" ] || [ -f "$d/.${name}-config" ] || \
       [ -f "$d/cli.sh" ] || [ -f "$d/compose/base.yaml" ] || [ -d "$d/lib" ]; then
        return 0
    fi
    # mkdir-only leftover from a setup that died before copying files
    [ -z "$(find "$d" -mindepth 1 -maxdepth 1 2>/dev/null | head -1)" ]
}

is_assemblrr_media_tree() {
    local d="$1"
    local name="${APP_NAME:-assemblrr}"
    [ -d "$d" ] || return 1
    [ "$(basename "$d")" = "${name}-media" ] || return 1
    [ -d "$d/torrents/movies" ] || [ -d "$d/media/movies" ] || [ -d "$d/blackhole" ]
}

# Shared location block for `status` and `uninstall`.
# Uses INSTALL_DIR, MEDIA_DIRECTORY, APP_CLI_NAME (optional heading as $1).
print_detected_locations() {
    local heading="${1:-}"
    local cli_path="$HOME/.local/bin/${APP_CLI_NAME:-assemblrr}"
    local kind path
    [ -n "$heading" ] && echo "$heading"
    printf '  Config:  %s\n' "${INSTALL_DIR:-unknown}"
    printf '  Media:   %s\n' "${MEDIA_DIRECTORY:-unknown}"
    if [ -e "$cli_path" ]; then
        printf '  CLI:     %s\n' "$cli_path"
    fi
    while IFS=$'\t' read -r kind path; do
        [ -n "$path" ] || continue
        case "$kind" in
            install) printf '  Extra:   leftover install %s\n' "$path" ;;
            media)   printf '  Extra:   leftover media %s\n' "$path" ;;
        esac
    done < <(list_assemblrr_leftovers "${INSTALL_DIR:-}" "${MEDIA_DIRECTORY:-}")
}

# TSV: kind<TAB>path   kind is install|media
# Optional $1/$2 are already-known paths to skip.
list_assemblrr_leftovers() {
    local skip_install="${1:-}"
    local skip_media="${2:-}"
    local root d
    local -A seen=()

    while IFS= read -r root; do
        [ -n "$root" ] || continue
        [ -n "${seen[$root]:-}" ] && continue
        seen[$root]=1
        d="${root}/${APP_NAME:-assemblrr}"
        if [ -d "$d" ] && [ "$d" != "$skip_install" ] && is_assemblrr_install_tree "$d"; then
            printf 'install\t%s\n' "$d"
        fi
        d="${root}/${APP_NAME:-assemblrr}-media"
        if [ -d "$d" ] && [ "$d" != "$skip_media" ] && is_assemblrr_media_tree "$d"; then
            printf 'media\t%s\n' "$d"
        fi
    done < <({ printf '%s\n' "${HOME:-}"; list_storage_roots; })
}

# --- Path utilities ---

# Expand tilde in user input paths (no eval — safe from code injection)
expand_path() {
    local path="$1"
    # Only expand leading ~ to $HOME, nothing else
    echo "${path/#\~/$HOME}"
}

# Human label for a detected storage root (WSL drive letter or mount name).
storage_root_label() {
    local root="${1%/}"
    local letter
    case "$root" in
        /mnt/[a-z])
            letter="${root##*/}"
            echo "Windows ${letter^^}:"
            ;;
        /media/*|/run/media/*)
            echo "${root##*/}"
            ;;
        *)
            echo "$root"
            ;;
    esac
}

# " (123G free)" or empty if df cannot report.
storage_free_label() {
    local root="$1"
    local avail
    avail=$(df -hP "$root" 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -n "$avail" ]; then
        echo "  (${avail} free)"
    fi
}

# Mounted volumes that are useful as install/media parents.
# WSL: /mnt/<letter>. Linux: /media and /run/media children.
list_storage_roots() {
    local d
    local -A seen=()

    _list_storage_emit() {
        local p="${1%/}"
        [ -n "$p" ] && [ -d "$p" ] || return 0
        [ "$p" = "${HOME:-}" ] && return 0
        [ -n "${seen[$p]:-}" ] && return 0
        seen[$p]=1
        printf '%s\n' "$p"
    }

    for d in /mnt/[a-z]; do
        [ -d "$d" ] || continue
        if grep -Eq "[[:space:]]${d}[[:space:]]" /proc/mounts 2>/dev/null; then
            _list_storage_emit "$d"
        fi
    done

    for d in /media/"${USER:-}"/* /media/* /run/media/"${USER:-}"/*; do
        [ -d "$d" ] || continue
        case "$d" in
            /media|"/media/${USER:-}"|/run/media|"/run/media/${USER:-}") continue ;;
        esac
        [ -r "$d" ] || continue
        _list_storage_emit "$d"
    done
}

# WSL often does not attach a USB letter until something touches /mnt/<letter>.
# Ask Windows which letters exist, then ls each so automount can catch up.
poke_wsl_automounts() {
    grep -qi microsoft /proc/version 2>/dev/null || return 0
    local letters letter mountpoint
    letters=$(timeout 5 cmd.exe /c "wmic logicaldisk get name" 2>/dev/null \
        | tr -d '\r' | grep -Eo '[A-Za-z]:' | tr -d ':' | tr '[:upper:]' '[:lower:]' || true)
    for letter in $letters; do
        mountpoint="/mnt/$letter"
        mkdir -p "$mountpoint" 2>/dev/null || true
        timeout 2 ls "$mountpoint" >/dev/null 2>&1 || true
        if ! grep -Eq "[[:space:]]${mountpoint}[[:space:]]" /proc/mounts 2>/dev/null; then
            rmdir "$mountpoint" 2>/dev/null || true
        fi
    done
    for mountpoint in /mnt/[a-z]; do
        [ -d "$mountpoint" ] || continue
        timeout 2 ls "$mountpoint" >/dev/null 2>&1 || true
    done
}

# Mount root for a path we might install onto (/mnt/e/foo → /mnt/e).
storage_mount_root() {
    local p="${1%/}"
    local rest
    case "$p" in
        /mnt/[a-z])
            echo "$p"
            ;;
        /mnt/[a-z]/*)
            rest="${p#/mnt/}"
            echo "/mnt/${rest%%/*}"
            ;;
        /run/media/*)
            echo "$p" | awk -F/ '{ if (NF >= 5) print "/"$2"/"$3"/"$4"/"$5; else print $0 }'
            ;;
        /media/*)
            echo "$p" | awk -F/ '{ if (NF >= 4) print "/"$2"/"$3"/"$4; else print $0 }'
            ;;
        *)
            echo "$p"
            ;;
    esac
}

# True for WSL drive letters and typical removable-media mounts.
storage_needs_probe() {
    case "${1%/}" in
        /mnt/[a-z]|/mnt/[a-z]/*|/media/*|/run/media/*) return 0 ;;
        *) return 1 ;;
    esac
}

run_with_timeout() {
    local secs="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout --foreground "$secs" "$@"
    else
        "$@"
    fi
}

# Timed write/read/unlink on the mount. 0 = ok, 1 = fail/timeout (already logged).
probe_writable_path() {
    local path="$1"
    local secs="${2:-8}"
    local root probe start now elapsed rc=0

    root=$(storage_mount_root "$path")
    [ -n "$root" ] || return 1
    probe="$root/.assemblrr-write-test.$$"
    start=$(date +%s)

    export ASSEMBLRR_PROBE_FILE="$probe"
    run_with_timeout "$secs" bash -c \
        'printf ok > "$ASSEMBLRR_PROBE_FILE" && grep -qx ok "$ASSEMBLRR_PROBE_FILE" && rm -f "$ASSEMBLRR_PROBE_FILE"' \
        || rc=$?
    unset ASSEMBLRR_PROBE_FILE
    rm -f "$probe" 2>/dev/null || true

    now=$(date +%s)
    elapsed=$((now - start))

    if [ "$rc" -eq 124 ]; then
        log_warning "No response from ${root} after ${secs}s — the drive looks stuck."
        log_info "Common on flaky USB / WSL drive letters (Explorer may freeze on that disk too)."
        log_info "From PowerShell:  wsl --shutdown"
        log_info "Then check the drive in Explorer, or pick Home in the list."
        return 1
    fi
    if [ "$rc" -ne 0 ]; then
        log_warning "Cannot write to ${root} (disconnected, or no permission)."
        return 1
    fi
    if [ "$elapsed" -ge 3 ]; then
        log_warning "${root} is slow (${elapsed}s). USB/WSL mounts can stall setup and Docker later."
    fi
    return 0
}

# PATH entry (~/.local/bin/<cli>) is a wrapper that execs $INSTALL_DIR/cli.sh.
# Older installs copied cli.sh plus a lib/ subset there; those leftovers are removed.

remove_stale_user_cli_libs() {
    local lib="$HOME/.local/bin/lib"
    local m
    [ -d "$lib" ] || return 0
    for m in core branding compose vpn managed_files upgrade services ui config_edit; do
        rm -f "$lib/${m}.sh"
    done
    rmdir "$lib" 2>/dev/null || true
}

write_user_cli_wrapper() {
    local dest="$1"
    mkdir -p "$(dirname "$dest")"
    cat >"$dest" <<'EOF'
#!/bin/bash
set -euo pipefail
# PATH wrapper — runs the install-tree CLI.

_read_install_dir() {
    local f="$1" line
    [ -f "$f" ] || return 1
    line=$(grep -E '^INSTALL_DIRECTORY=' "$f" | head -1) || return 1
    line="${line#INSTALL_DIRECTORY=}"
    line="${line%$'\r'}"
    line="${line#\"}"
    line="${line%\"}"
    line="${line#\'}"
    line="${line%\'}"
    [ -n "$line" ] || return 1
    printf '%s\n' "$line"
}

dir="${ASSEMBLRR_DIR:-}"
if [ -z "$dir" ]; then
    for f in \
        /opt/assemblrr/.assemblrr-config \
        "${HOME}/.assemblrr-config" \
        "${HOME}/assemblrr/.assemblrr-config"
    do
        if dir=$(_read_install_dir "$f"); then
            break
        fi
        dir=""
    done
fi

if [ -z "$dir" ] || [ ! -f "$dir/cli.sh" ]; then
    echo "assemblrr: could not find the install. Run setup, or set ASSEMBLRR_DIR." >&2
    exit 1
fi

exec bash "$dir/cli.sh" "$@"
EOF
    chmod +x "$dest"
}

install_user_cli_wrapper() {
    local dest="$HOME/.local/bin/${APP_CLI_NAME:-assemblrr}"
    write_user_cli_wrapper "$dest"
    remove_stale_user_cli_libs
    ensure_local_bin_on_path
}

# Persist ~/.local/bin on PATH for bash, zsh, and fish.
# Does not create ~/.bash_profile (that would hide ~/.profile on login bash).
_append_path_line() {
    local file="$1"
    local line="$2"
    local marker="$3"
    if [ -f "$file" ] && grep -qF "$marker" "$file" 2>/dev/null; then
        return 0
    fi
    mkdir -p "$(dirname "$file")"
    printf '%s\n' "$line" >> "$file"
}

ensure_local_bin_on_path() {
    export PATH="$HOME/.local/bin:$PATH"
    local line='export PATH="$HOME/.local/bin:$PATH"'
    local marker='.local/bin'
    _append_path_line "$HOME/.profile" "$line" "$marker"
    _append_path_line "$HOME/.bashrc" "$line" "$marker"
    if [ -f "$HOME/.bash_profile" ]; then
        _append_path_line "$HOME/.bash_profile" "$line" "$marker"
    fi
    if [ -f "$HOME/.zshrc" ] || command -v zsh >/dev/null 2>&1; then
        _append_path_line "$HOME/.zshrc" "$line" "$marker"
    fi
    if command -v fish >/dev/null 2>&1 || [ -d "$HOME/.config/fish" ]; then
        _append_path_line "$HOME/.config/fish/config.fish" 'fish_add_path $HOME/.local/bin' "$marker"
    fi
}

# Validate that a path is safe to remove (used by safe_rm_rf)
_is_safe_rm_path() {
    local dir="$1"
    # Refuse empty paths
    if [ -z "$dir" ]; then
        log_error "Refusing to remove empty path"
        return 1
    fi
    # Safety guard: never remove root, system paths, or shallow paths
    case "$dir" in
        ""|"/"|"/home"|"/usr"|"/etc"|"/var"|"/opt"|"/root"|"/tmp"|"${HOME:-}")
            log_error "Refusing to remove system path: $dir"
            return 1
            ;;
    esac
    # Refuse to remove a user's home directory directly
    if [[ "$dir" =~ ^/home/[^/]+$ ]]; then
        log_error "Refusing to remove home directory: $dir"
        return 1
    fi
    # Refuse to remove paths shallower than /home/<user>/<app> (3+ slashes required)
    # Examples: /home/soulis (2 levels) = blocked, /home/soulis/assemblrr (3 levels) = allowed
    local depth
    depth=$(echo "$dir" | tr -cd '/' | wc -c)
    if [ "$depth" -lt 2 ]; then
        log_error "Refusing to remove shallow path (depth < 2): $dir"
        return 1
    fi
    return 0
}

# Remove a directory with sudo fallback (Docker containers create root-owned files)
safe_rm_rf() {
    local dir="$1"
    # Normalize trailing slashes
    while [ "${dir%/}" != "$dir" ]; do
        dir="${dir%/}"
    done

    if ! _is_safe_rm_path "$dir"; then
        return 1
    fi

    if ! rm -rf "$dir" 2>/dev/null; then
        local parent_dir; parent_dir="$(dirname "$dir")"
        local base_name; base_name="$(basename "$dir")"
        # Run rm inside docker by mounting the parent directory
        if ! docker run --rm -v "$parent_dir:/target" alpine rm -rf "/target/$base_name" 2>/dev/null; then
            log_warning "Failed to remove $dir. You may need to remove it manually."
        fi
    fi
}

# --- Directory helpers ---

create_and_verify_directory() {
    local dir="$1"
    local dir_type="$2"
    local rc=0

    if [ ! -d "$dir" ]; then
        echo "The directory \"$dir\" does not exist. Attempting to create..."
        run_with_timeout 15 mkdir -p "$dir" || rc=$?
        if [ "$rc" -eq 124 ]; then
            log_error "Timed out creating \"$dir\" (15s). The drive looks stuck (flaky USB / WSL). From PowerShell: wsl --shutdown — then check the drive in Explorer, or re-run setup and pick Home."
        elif [ "$rc" -ne 0 ]; then
            log_error "Failed to create $dir_type directory at \"$dir\". Check permissions"
        else
            log_success "Directory $dir created"
        fi
    fi

    if [ ! -w "$dir" ] || [ ! -r "$dir" ]; then
        log_error "Directory \"$dir\" is not writable or readable. Check permissions"
    fi
}

# Set ownership on a path (recursive). Tries without sudo first.
# Usage: ensure_owned "$path" "$uid" "$gid"
ensure_owned() {
    local path="$1"
    local uid="$2"
    local gid="$3"

    [ -e "$path" ] || return 0

    local actual_uid actual_gid
    actual_uid=$(stat -c '%u' "$path" 2>/dev/null || echo "")
    actual_gid=$(stat -c '%g' "$path" 2>/dev/null || echo "")

    if [ "$actual_uid" = "$uid" ] && [ "$actual_gid" = "$gid" ]; then
        # Directory may still be mode-inaccessible to us (e.g. root sticky leftovers)
        if [ -d "$path" ] && [ "$(id -u)" = "$uid" ] && [ ! -w "$path" ]; then
            :
        else
            return 0
        fi
    fi

    if chown -R "$uid:$gid" "$path" 2>/dev/null; then
        return 0
    fi
    if command -v sudo >/dev/null 2>&1 && sudo chown -R "$uid:$gid" "$path" 2>/dev/null; then
        return 0
    fi

    log_error "Cannot set ownership of $path to ${uid}:${gid} (Docker may have created it as root). Fix with: sudo chown -R ${uid}:${gid} \"$path\""
}

# Create every host bind-mount target under the install tree *before* any
# container starts. Docker creates missing mount parents as root; that makes
# later setup mkdir fail. Call this immediately before compose up / VPN test.
#
# Usage: prepare_install_dirs "$install_dir" "$puid" "$pgid"
prepare_install_dirs() {
    local install_dir="$1"
    local uid="${2:-$(id -u)}"
    local gid="${3:-$(id -g)}"

    if [ -z "$install_dir" ]; then
        log_error "prepare_install_dirs: install_dir is required"
    fi

    # Paths mounted from compose/base.yaml, vpn.yaml, and optional custom services
    local -a rel_paths=(
        "config"
        "config/gluetun"
        "config/jellyfin"
        "config/emby"
        "config/plex"
        "config/qbittorrent"
        "config/sonarr"
        "config/radarr"
        "config/prowlarr"
        "config/seerr"
        "config/recyclarr"
        "config/lidarr"
        "config/sabnzbd"
        "config/bazarr"
        "secrets"
        "scripts"
    )

    # Ensure install root is owned by the target user
    if [ -d "$install_dir" ] && [ ! -w "$install_dir" ]; then
        ensure_owned "$install_dir" "$(id -u)" "$(id -g)"
    fi

    if [ ! -d "$install_dir" ]; then
        mkdir -p "$install_dir" || log_error "Failed to create install directory: $install_dir"
    fi

    # If config/ already exists as root (failed prior VPN test), reclaim before mkdir
    if [ -d "$install_dir/config" ] && [ ! -w "$install_dir/config" ]; then
        ensure_owned "$install_dir/config" "$(id -u)" "$(id -g)"
    fi

    local rel
    for rel in "${rel_paths[@]}"; do
        local path="$install_dir/$rel"
        if [ ! -d "$path" ]; then
            if ! mkdir -p "$path" 2>/dev/null; then
                ensure_owned "$(dirname "$path")" "$(id -u)" "$(id -g)"
                mkdir -p "$path" || log_error "Failed to create $path"
            fi
        fi
    done

    # Align tree to the service host user (PUID/PGID)
    ensure_owned "$install_dir/config" "$uid" "$gid"
    ensure_owned "$install_dir/secrets" "$uid" "$gid"
    ensure_owned "$install_dir/scripts" "$uid" "$gid"

    # Seerr runs as node (UID 1000), not necessarily PUID
    if [ "$uid" != "1000" ] || [ "$gid" != "1000" ]; then
        ensure_owned "$install_dir/config/seerr" "1000" "1000"
    fi

    # Setup process must keep writing under config/ (qBittorrent conf, etc.)
    if [ "$(id -u)" = "$uid" ] && [ ! -w "$install_dir/config" ]; then
        log_error "Install config directory is not writable: $install_dir/config"
    fi
}

setup_directory_structure() {
    local media_dir="$1"
    create_and_verify_directory "$media_dir" "media"
    for subdir in "${MEDIA_SUBDIRS[@]}"; do
        create_and_verify_directory "$media_dir/$subdir" "media subdirectory"
    done
}

verify_user_permissions() {
    local username="$1"
    local directory="$2"

    if ! id -u "$username" &>/dev/null; then
        log_error "User \"$username\" doesn't exist!"
    fi

    # Check write access directly for the current user (no sudo needed)
    if [ "$username" = "$(id -un)" ]; then
        if [ ! -w "$directory" ]; then
            log_error "User \"$username\" doesn't have write permissions to \"$directory\""
        fi
    elif ! sudo -u "$username" test -w "$directory"; then
        log_error "User \"$username\" doesn't have write permissions to \"$directory\""
    fi
}

verify_docker() {
    local docker_exe="/mnt/c/Program Files/Docker/Docker/Docker Desktop.exe"
    local is_wsl=false
    if grep -qi microsoft /proc/version 2>/dev/null; then
        is_wsl=true
    fi

    # Check if docker command is missing
    if ! command -v docker &>/dev/null; then
        # If in WSL2 and Docker Desktop is installed on host, we can start it to mount it
        if [ "$is_wsl" = true ] && [ -f "$docker_exe" ] && command -v cmd.exe &>/dev/null; then
            log_info "Docker Desktop integration is offline. Attempting to start Docker Desktop on Windows..."
            cmd.exe /c start "" "C:\\Program Files\\Docker\\Docker\\Docker Desktop.exe" < /dev/null > /dev/null 2>&1 &
            for i in {1..45}; do
                wait_inline "Waiting for Docker Desktop integration" "$i"
                sleep 1
                if command -v docker &>/dev/null && docker info &>/dev/null; then
                    echo ""
                    log_success "Docker Desktop started successfully and integration is ready."
                    return 0
                fi
            done
            echo ""
        fi
        log_warning "Docker is not installed or not in PATH."
        return 1
    fi

    # If docker command exists, check if daemon is running
    if ! docker info &>/dev/null; then
        if [ "$is_wsl" = true ] && [ -f "$docker_exe" ] && command -v cmd.exe &>/dev/null; then
            log_info "Docker daemon is not running. Attempting to start Docker Desktop on Windows..."
            cmd.exe /c start "" "C:\\Program Files\\Docker\\Docker\\Docker Desktop.exe" < /dev/null > /dev/null 2>&1 &
            for i in {1..45}; do
                wait_inline "Waiting for Docker daemon" "$i"
                sleep 1
                if docker info &>/dev/null; then
                    echo ""
                    log_success "Docker Desktop started successfully and is ready."
                    return 0
                fi
            done
            echo ""
        fi
        return 1
    fi

    return 0
}

# Helper to generate PBKDF2 password hash for qBittorrent WebUI
# Format: @ByteArray(salt:hash) where both salt and hash are Base64 encoded
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

run_docker() {
    # Run the docker command directly
    # Disable exit on error temporarily so we can catch the status
    set +e
    docker "$@"
    local exit_code=$?
    set -e

    if [ $exit_code -ne 0 ]; then
        # If it failed, check if the Docker daemon is actually running or missing
        if ! command -v docker &>/dev/null || ! docker info &>/dev/null; then
            log_warning "Docker daemon is not running or integration is offline. Attempting auto-start..."
            if verify_docker; then
                # Retry the command once
                docker "$@"
                return $?
            else
                log_error "Docker daemon is not running. Please start Docker and try again."
            fi
        fi
    fi

    return $exit_code
}

# --- Masked input ---
# Read masked input (shows asterisks for each character, works in WSL2)
read_masked() {
    local prompt="$1"
    local var_name="$2"
    local value=""
    local charcount=0
    local old_settings

    clear_masked_input() {
        while [ "$charcount" -gt 0 ]; do
            printf '\b \b' >&2
            charcount=$((charcount - 1))
        done
        value=""
    }

    printf "%s" "$prompt"

    # Save and disable terminal echo
    old_settings=$(stty -g)
    stty -echo

    while IFS= read -r -n 1 char; do
        # Enter key
        if [[ $char == $'\n' ]] || [[ -z "$char" ]]; then
            break
        fi
        # Backspace / Delete
        if [[ $char == $'\177' ]] || [[ $char == $'\b' ]]; then
            if [ $charcount -gt 0 ]; then
                charcount=$((charcount - 1))
                printf '\b \b' >&2
                value="${value%?}"
            fi
        # Ctrl+U and Ctrl+W clear current masked input
        elif [[ $char == $'\025' ]] || [[ $char == $'\027' ]]; then
            clear_masked_input
        # Escape sequences (Ctrl+Backspace, Ctrl+Delete, etc.)
        elif [[ $char == $'\e' ]]; then
            local seq=""
            local next=""
            while IFS= read -r -s -n 1 -t 0.01 next; do
                seq+="$next"
                [[ $next == "~" ]] && break
                [ ${#seq} -ge 8 ] && break
            done

            case "$seq" in
                "[3;5~"|"[127;5u"|"[8;5~")
                    clear_masked_input
                    ;;
            esac
        else
            charcount=$((charcount + 1))
            printf '*' >&2
            value+="$char"
        fi
    done

    # Restore terminal settings
    stty "$old_settings"
    echo
    printf -v "$var_name" '%s' "$value"
}
