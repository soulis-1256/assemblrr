#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# assemblrr filesystem, secret-writing, ownership, and CLI wrapper helpers

if [ -n "${_ASSEMBLRR_FS_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_FS_SOURCED=1

readonly UTILITY_ALPINE_IMAGE="alpine:3.24.4"
readonly -a DEFAULT_MEDIA_SUBDIRS=(
    "torrents/movies"
    "torrents/tv"
    "torrents/incomplete"
    "media/movies"
    "media/tv"
    "usenet/incomplete"
    "usenet/complete/movies"
    "usenet/complete/tv"
)

# Write a secret safely: 0700 parent dir + 0600 file via atomic rename (no 0644 TOCTOU).
write_secret_file() {
    local path="$1"
    local value="${2:-}"
    local dir tmp
    [ -n "$path" ] || return 1
    dir=$(dirname "$path")
    mkdir -p "$dir"
    chmod 700 "$dir" 2>/dev/null || true
    tmp=$(mktemp "${dir}/.tmp.XXXXXX") || return 1
    (
        umask 077
        printf '%s' "$value" > "$tmp"
    )
    chmod 600 "$tmp"
    mv "$tmp" "$path"
}

remove_stale_user_cli_libs() {
    local lib="$HOME/.local/bin/lib"
    [ -d "$lib" ] || return 0
    rm -f "$lib/"*.sh 2>/dev/null || true
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
        "${HOME}/.assemblrr-config" \
        /opt/assemblrr/.assemblrr-config \
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

_canonical_path() {
    local p="$1"
    if command -v realpath >/dev/null 2>&1; then
        realpath -m "$p" 2>/dev/null && return 0
    fi
    # Pure-bash fallback normalizing /./ and /../ segments
    local -a segs=() out=()
    local s
    IFS='/' read -ra segs <<< "$p"
    for s in "${segs[@]}"; do
        case "$s" in
            ""|".") continue ;;
            "..") [ "${#out[@]}" -gt 0 ] && unset 'out[${#out[@]}-1]' ;;
            *) out+=("$s") ;;
        esac
    done
    local joined
    joined=$(IFS=/; echo "${out[*]}")
    echo "/$joined"
}

# Validate that a path is safe to remove (used by safe_rm_rf)
_is_safe_rm_path() {
    local dir="$1"
    if [ -z "$dir" ]; then
        log_error "Refusing to remove empty path"
        return 1
    fi

    case "$dir" in
        /*) ;;
        *)
            log_error "Refusing to remove relative path: $dir"
            return 1
            ;;
    esac

    dir=$(_canonical_path "$dir")

    case "$dir" in
        ""|"/"|"/home"|"/usr"|"/etc"|"/var"|"/opt"|"/root"|"/tmp"|"/mnt"|"/media"|"/bin"|"/lib"|"/sbin"|"${HOME:-}")
            log_error "Refusing to remove system path: $dir"
            return 1
            ;;
        /mnt/[a-z]|/etc/*|/usr/*|/var/lib|/var/log)
            log_error "Refusing to remove protected path: $dir"
            return 1
            ;;
    esac

    if [[ "$dir" =~ ^/home/[^/]+$ ]]; then
        log_error "Refusing to remove home directory: $dir"
        return 1
    fi

    # Require depth >= 3 (e.g. /home/user/assemblrr has 3 slashes).
    local slashes="${dir//[^\/]/}"
    local depth=${#slashes}
    if [ "$depth" -lt 3 ]; then
        log_error "Refusing to remove shallow path (depth < 3): $dir"
        return 1
    fi
    return 0
}

safe_rm_rf() {
    local dir="$1"
    while [ "${dir%/}" != "$dir" ]; do
        dir="${dir%/}"
    done

    if ! _is_safe_rm_path "$dir"; then
        return 1
    fi
    dir=$(_canonical_path "$dir")

    if ! rm -rf "$dir" 2>/dev/null; then
        local parent_dir base_name
        parent_dir="$(dirname "$dir")"
        base_name="$(basename "$dir")"
        if ! run_docker run --rm -v "$parent_dir:/target" "$UTILITY_ALPINE_IMAGE" rm -rf "/target/$base_name" 2>/dev/null; then
            log_warning "Failed to remove $dir. You may need to remove it manually."
        fi
    fi
}

create_and_verify_directory() {
    local dir="$1"
    local dir_type="$2"
    local quiet="${3:-0}"
    local rc=0

    if [ ! -d "$dir" ]; then
        [ "$quiet" = "1" ] || echo "The directory \"$dir\" does not exist. Attempting to create..."
        run_with_timeout 15 mkdir -p "$dir" || rc=$?
        if [ "$rc" -eq 124 ]; then
            log_error "Timed out creating \"$dir\" (15s). The drive looks stuck (flaky USB / WSL). From PowerShell: wsl --shutdown — then check the drive in Explorer, or re-run setup and pick Home."
        elif [ "$rc" -ne 0 ]; then
            log_error "Failed to create $dir_type directory at \"$dir\". Check permissions"
        elif [ "$quiet" != "1" ]; then
            log_success "Directory $dir created"
        fi
    fi

    if [ ! -w "$dir" ] || [ ! -r "$dir" ]; then
        log_error "Directory \"$dir\" is not writable or readable. Check permissions"
    fi
}

# Set ownership on a path (recursive). Checks descendants before short-circuiting.
ensure_owned() {
    local path="$1"
    local uid="$2"
    local gid="$3"

    [ -e "$path" ] || return 0

    local actual_uid actual_gid mismatch=""
    actual_uid=$(stat -c '%u' "$path" 2>/dev/null || echo "")
    actual_gid=$(stat -c '%g' "$path" 2>/dev/null || echo "")

    if [ "$actual_uid" = "$uid" ] && [ "$actual_gid" = "$gid" ]; then
        if [ -d "$path" ]; then
            mismatch=$(find "$path" \( ! -uid "$uid" -o ! -gid "$gid" \) -print -quit 2>/dev/null || true)
            if [ -z "$mismatch" ] && { [ "$(id -u)" != "$uid" ] || [ -w "$path" ]; }; then
                return 0
            fi
        else
            return 0
        fi
    fi

    if chown -R "$uid:$gid" "$path" 2>/dev/null; then
        return 0
    fi
    if command -v docker >/dev/null 2>&1 || declare -F run_docker >/dev/null 2>&1; then
        if [ -d "$path" ]; then
            if run_docker run --rm -v "$path:/target" "$UTILITY_ALPINE_IMAGE" chown -R "$uid:$gid" /target >/dev/null 2>&1; then
                return 0
            fi
        elif [ -e "$path" ]; then
            local _parent _base
            _parent=$(dirname "$path")
            _base=$(basename "$path")
            if run_docker run --rm -v "$_parent:/target" "$UTILITY_ALPINE_IMAGE" chown "$uid:$gid" "/target/$_base" >/dev/null 2>&1; then
                return 0
            fi
        fi
    fi
    if command -v sudo >/dev/null 2>&1 && sudo chown -R "$uid:$gid" "$path" 2>/dev/null; then
        return 0
    fi

    log_error "Cannot set ownership of $path to ${uid}:${gid} (Docker may have created it as root). Fix with: sudo chown -R ${uid}:${gid} \"$path\""
}

# Create host bind-mount targets under the install tree before containers start.
prepare_install_dirs() {
    local install_dir="$1"
    local uid="${2:-$(id -u)}"
    local gid="${3:-$(id -g)}"

    if [ -z "$install_dir" ]; then
        log_error "prepare_install_dirs: install_dir is required"
        return 1
    fi

    local -a rel_paths=(
        "config"
        "config/gluetun"
        "config/jellyfin"
        "config/qbittorrent"
        "config/sonarr"
        "config/radarr"
        "config/prowlarr"
        "config/seerr"
        "config/recyclarr"
        "config/bazarr"
        "config/sabnzbd"
        "secrets"
        "scripts"
    )

    if [ -d "$install_dir" ] && [ ! -w "$install_dir" ]; then
        ensure_owned "$install_dir" "$(id -u)" "$(id -g)"
    fi

    if [ ! -d "$install_dir" ]; then
        mkdir -p "$install_dir" || log_error "Failed to create install directory: $install_dir"
    fi

    if [ -d "$install_dir/config" ] && [ ! -w "$install_dir/config" ]; then
        ensure_owned "$install_dir/config" "$(id -u)" "$(id -g)"
    fi

    local rel path
    for rel in "${rel_paths[@]}"; do
        path="$install_dir/$rel"
        if [ ! -d "$path" ]; then
            if ! mkdir -p "$path" 2>/dev/null; then
                ensure_owned "$(dirname "$path")" "$(id -u)" "$(id -g)"
                mkdir -p "$path" || log_error "Failed to create $path"
            fi
        fi
    done

    # Seerr runs as node (UID 1000); skip its subdir when aligning PUID != 1000 to avoid thrashing.
    if [ "$uid" = "1000" ] && [ "$gid" = "1000" ]; then
        ensure_owned "$install_dir/config" "$uid" "$gid"
    else
        chown "$uid:$gid" "$install_dir/config" 2>/dev/null || true
        local _child
        for _child in "$install_dir/config"/*; do
            [ -e "$_child" ] || continue
            [ "$(basename "$_child")" = "seerr" ] && continue
            ensure_owned "$_child" "$uid" "$gid"
        done
        ensure_owned "$install_dir/config/seerr" "1000" "1000"
    fi
    ensure_owned "$install_dir/secrets" "$uid" "$gid"
    chmod 700 "$install_dir/secrets" 2>/dev/null || true
    ensure_owned "$install_dir/scripts" "$uid" "$gid"

    if [ "$(id -u)" = "$uid" ] && [ ! -w "$install_dir/config" ]; then
        log_error "Install config directory is not writable: $install_dir/config"
    fi
}

setup_directory_structure() {
    local media_dir="$1"
    local -a subdirs=("${DEFAULT_MEDIA_SUBDIRS[@]}")
    if [ -n "${MEDIA_SUBDIRS+x}" ] && [ "${#MEDIA_SUBDIRS[@]}" -gt 0 ]; then
        subdirs=("${MEDIA_SUBDIRS[@]}")
    fi
    create_and_verify_directory "$media_dir" "media" 1
    local subdir
    for subdir in "${subdirs[@]}"; do
        create_and_verify_directory "$media_dir/$subdir" "media subdirectory" 1
    done
}

verify_user_permissions() {
    local username="$1"
    local directory="$2"

    if ! id -u "$username" &>/dev/null; then
        log_error "User \"$username\" doesn't exist!"
    fi

    if [ "$username" = "$(id -un)" ]; then
        if [ ! -w "$directory" ]; then
            log_error "User \"$username\" doesn't have write permissions to \"$directory\""
        fi
    elif ! sudo -u "$username" test -w "$directory"; then
        log_error "User \"$username\" doesn't have write permissions to \"$directory\""
    fi
}
