#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# assemblrr config parsing, path discovery, storage probes, and leftover scan

if [ -n "${_ASSEMBLRR_PATHS_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_PATHS_SOURCED=1

# Expand $VAR and ${VAR} references inside a validated string without eval/source.
_safe_expand_vars() {
    local val="$1"
    local out="" rest="$val" var="" repl=""

    while [[ "$rest" =~ ^([^$]*)\$(.*)$ ]]; do
        out+="${BASH_REMATCH[1]}"
        rest="${BASH_REMATCH[2]}"
        if [[ "$rest" =~ ^\{([A-Za-z_][A-Za-z0-9_]*)\}(.*)$ ]]; then
            var="${BASH_REMATCH[1]}"
            rest="${BASH_REMATCH[2]}"
            repl="${!var-}"
            out+="$repl"
        elif [[ "$rest" =~ ^([A-Za-z_][A-Za-z0-9_]*)(.*)$ ]]; then
            var="${BASH_REMATCH[1]}"
            rest="${BASH_REMATCH[2]}"
            repl="${!var-}"
            out+="$repl"
        else
            out+='$'
        fi
    done
    out+="$rest"
    printf '%s' "$out"
}

# Safely parse a KEY=VALUE file without executing shell code (no eval / source).
safe_source() {
    local file="$1"
    if [ ! -f "$file" ]; then
        return 1
    fi

    local do_export=0
    [[ $- == *a* ]] && do_export=1

    local -a keys=() vals=()
    local line key raw val
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        if ! [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            log_error_inline "Rejecting unsafe line in $file: $line"
            return 1
        fi
        key="${BASH_REMATCH[1]}"
        raw="${BASH_REMATCH[2]}"

        # Reject trailing backslash continuations.
        if [[ "$raw" == *\\ ]]; then
            log_error_inline "Rejecting unsafe line continuation in $file: $line"
            return 1
        fi

        if [[ "$raw" =~ ^\'([^\']*)\'$ ]]; then
            val="${BASH_REMATCH[1]}"
        elif [[ "$raw" =~ ^\"(([^\"\\]|\\.)*)\"$ ]]; then
            val="${BASH_REMATCH[1]}"
            if [[ "$val" == *'$('* ]] || [[ "$val" == *'`'* ]]; then
                log_error_inline "Rejecting command substitution in $file: $line"
                return 1
            fi
            val="${val//\\\"/\"}"
            val="${val//\\\\/\\}"
            val="${val//\\\$/\$}"
            val=$(_safe_expand_vars "$val")
        else
            # Unquoted value: reject whitespace, shell metacharacters, or quotes
            case "$raw" in
                *[[:space:]]*|*'$('*|*'`'*|*';'*|*'|'*|*'&'*|*'>'*|*'<'*|*'('*|*')'*|*\"*|*\'*)
                    log_error_inline "Rejecting unsafe value in $file: $line"
                    return 1
                    ;;
            esac
            val=$(_safe_expand_vars "$raw")
        fi

        keys+=("$key")
        vals+=("$val")
        # Make earlier assignments visible to subsequent lines (e.g. branding.conf)
        printf -v "$key" '%s' "$val"
        if [ "$do_export" -eq 1 ]; then
            export "$key"
        fi
    done < "$file"
    return 0
}

# Discover installation directory from ASSEMBLRR_DIR or runtime pointers.
find_install_directory() {
    if [ -n "${ASSEMBLRR_DIR:-}" ]; then
        echo "$ASSEMBLRR_DIR"
        return 0
    fi

    local name="${APP_NAME:-assemblrr}"
    local -a search_order=(
        "$HOME/.assemblrr-config"
        "$HOME/.${name}-config"
        "/opt/${name}/.${name}-config"
        "$HOME/${name}/.${name}-config"
    )
    local config_file
    for config_file in "${search_order[@]}"; do
        if [ -f "$config_file" ]; then
            safe_source "$config_file" || continue
            if [ -n "${INSTALL_DIRECTORY:-}" ]; then
                echo "$INSTALL_DIRECTORY"
                return 0
            fi
        fi
    done

    echo ""
    return 1
}

# Read KEY="value" from a dotenv file without mutating shell globals.
_pointer_get() {
    local file="$1"
    local key="$2"
    local line
    [ -f "$file" ] || return 0
    line=$(grep -E "^${key}=" "$file" 2>/dev/null | tail -1) || true
    line="${line#${key}=}"
    line="${line%$'\r'}"
    line="${line#\"}"
    line="${line%\"}"
    line="${line#\'}"
    line="${line%\'}"
    printf '%s\n' "$line"
}

# $1 = pipe-separated list, $2 = path to add. Prints the new list (no dups).
_known_path_list_add() {
    local list="${1:-}"
    local add="${2:-}"
    local p
    add="${add%/}"
    [ -n "$add" ] || { printf '%s\n' "$list"; return 0; }
    if [ -n "$list" ]; then
        local -a parts=()
        IFS='|' read -ra parts <<< "$list"
        for p in "${parts[@]}"; do
            [ "$p" = "$add" ] && { printf '%s\n' "$list"; return 0; }
        done
        printf '%s|%s\n' "$list" "$add"
    else
        printf '%s\n' "$add"
    fi
}

# Home pointer so the CLI can find a non-default (or mid-setup) install.
write_install_pointer() {
    local install_dir="${1%/}"
    local media_dir="${2:-}"
    local pointer="$HOME/.assemblrr-config"
    local known_i known_m prev_i prev_m
    media_dir="${media_dir%/}"

    known_i=$(_pointer_get "$pointer" "KNOWN_INSTALLS")
    known_m=$(_pointer_get "$pointer" "KNOWN_MEDIA")
    prev_i=$(_pointer_get "$pointer" "INSTALL_DIRECTORY")
    prev_m=$(_pointer_get "$pointer" "MEDIA_DIRECTORY")
    known_i=$(_known_path_list_add "$known_i" "$prev_i")
    known_i=$(_known_path_list_add "$known_i" "$install_dir")
    known_m=$(_known_path_list_add "$known_m" "$prev_m")
    known_m=$(_known_path_list_add "$known_m" "$media_dir")

    (
        umask 077
        {
            printf 'INSTALL_DIRECTORY="%s"\n' "$install_dir"
            if [ -n "$media_dir" ]; then
                printf 'MEDIA_DIRECTORY="%s"\n' "$media_dir"
            fi
            [ -n "$known_i" ] && printf 'KNOWN_INSTALLS="%s"\n' "$known_i"
            [ -n "$known_m" ] && printf 'KNOWN_MEDIA="%s"\n' "$known_m"
        } > "$pointer"
    )
    chmod 600 "$pointer" 2>/dev/null || true
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
    [ -z "$(find "$d" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1 || true)" ]
}

is_assemblrr_media_tree() {
    local d="$1"
    local name="${APP_NAME:-assemblrr}"
    [ -d "$d" ] || return 1
    [ "$(basename "$d")" = "${name}-media" ] || return 1
    [ -d "$d/torrents/movies" ] || [ -d "$d/media/movies" ] || [ -d "$d/usenet/complete" ] || [ -d "$d/blackhole" ]
}

is_complete_assemblrr_install() {
    local d="$1"
    [ -n "$d" ] && [ -d "$d" ] || return 1
    [ ! -f "$d/.assemblrr-setup-in-progress" ] || return 1
    { [ -f "$d/.assemblrr-config" ] || [ -f "$d/.${APP_NAME:-assemblrr}-config" ]; } || return 1
    [ -f "$d/cli.sh" ] || [ -f "$d/compose/base.yaml" ]
}

# Print detected Config, Media, and CLI paths (and optionally scan leftovers).
# Set ASSEMBLRR_SHOW_LEFTOVERS=0 to skip scanning external mounts (e.g. `status`).
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
    if [ "${ASSEMBLRR_SHOW_LEFTOVERS:-1}" = "1" ]; then
        while IFS=$'\t' read -r kind path; do
            [ -n "$path" ] || continue
            case "$kind" in
                install) printf '  Leftover install: %s\n' "$path" ;;
                media)   printf '  Leftover media:   %s\n' "$path" ;;
            esac
        done < <(list_assemblrr_leftovers "${INSTALL_DIR:-}" "${MEDIA_DIRECTORY:-}")
    fi
}

_assemblrr_tree_media_dir() {
    local d="$1"
    local cfg="" media=""
    [ -f "$d/.assemblrr-config" ] && cfg="$d/.assemblrr-config"
    [ -z "$cfg" ] && [ -f "$d/.${APP_NAME:-assemblrr}-config" ] && cfg="$d/.${APP_NAME:-assemblrr}-config"
    [ -n "$cfg" ] || return 0
    media=$(_pointer_get "$cfg" "MEDIA_DIRECTORY")
    printf '%s\n' "${media%/}"
}

# TSV: kind<TAB>path   kind is install|media
list_assemblrr_leftovers() {
    local skip_install="${1:-}"
    local skip_media="${2:-}"
    local name="${APP_NAME:-assemblrr}"
    local pointer="" root media
    local -A seen_i=()
    local -A seen_m=()

    skip_install="${skip_install%/}"
    skip_media="${skip_media%/}"

    _leftover_emit_install() {
        local p="${1%/}"
        local trust="${2:-0}"
        [ -n "$p" ] && [ -d "$p" ] || return 0
        [ "$p" != "$skip_install" ] || return 0
        [ -z "${seen_i[$p]:-}" ] || return 0
        if [ "$trust" != "1" ] && ! is_assemblrr_install_tree "$p"; then
            return 0
        fi
        seen_i[$p]=1
        printf 'install\t%s\n' "$p"
        media=$(_assemblrr_tree_media_dir "$p")
        if [ -n "$media" ] && [ -d "$media" ] && [ "$media" != "$skip_media" ] && \
           [ -z "${seen_m[$media]:-}" ]; then
            seen_m[$media]=1
            printf 'media\t%s\n' "$media"
        fi
    }

    _leftover_emit_media() {
        local p="${1%/}"
        local trust="${2:-0}"
        [ -n "$p" ] && [ -d "$p" ] || return 0
        [ "$p" != "$skip_media" ] || return 0
        [ -z "${seen_m[$p]:-}" ] || return 0
        if [ "$trust" != "1" ] && ! is_assemblrr_media_tree "$p"; then
            return 0
        fi
        seen_m[$p]=1
        printf 'media\t%s\n' "$p"
    }

    if [ -f "$HOME/.assemblrr-config" ]; then
        pointer="$HOME/.assemblrr-config"
    elif [ -f "$HOME/.${name}-config" ]; then
        pointer="$HOME/.${name}-config"
    fi
    if [ -n "$pointer" ]; then
        local -a parts=()
        local part raw_list
        raw_list=$(_pointer_get "$pointer" "KNOWN_INSTALLS")
        if [ -n "$raw_list" ]; then
            IFS='|' read -ra parts <<< "$raw_list"
            for part in "${parts[@]}"; do
                [ -n "$part" ] && _leftover_emit_install "$part" 1
            done
        fi
        raw_list=$(_pointer_get "$pointer" "KNOWN_MEDIA")
        if [ -n "$raw_list" ]; then
            IFS='|' read -ra parts <<< "$raw_list"
            for part in "${parts[@]}"; do
                [ -n "$part" ] && _leftover_emit_media "$part" 1
            done
        fi
    fi

    _leftover_scan_root() {
        local r="${1%/}"
        [ -n "$r" ] && [ -d "$r" ] || return 0
        _leftover_emit_install "${r}/${name}" 0
        _leftover_emit_media "${r}/${name}-media" 0
        local c
        for c in "$r"/*; do
            [ -d "$c" ] || continue
            _leftover_emit_install "${c}/${name}" 0
            _leftover_emit_media "${c}/${name}-media" 0
        done
    }

    _leftover_scan_root "${HOME:-}"
    _leftover_scan_root /opt
    while IFS= read -r root; do
        [ -n "$root" ] || continue
        _leftover_scan_root "$root"
    done < <(list_storage_roots)
}

expand_path() {
    local path="$1"
    echo "${path/#\~/$HOME}"
}

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

storage_free_label() {
    local root="$1"
    local avail
    avail=$(df -hP "$root" 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -n "$avail" ]; then
        echo "  (${avail} free)"
    fi
}

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

# Trigger WSL drive automounts using PowerShell Get-PSDrive (replaces Win11-removed wmic).
poke_wsl_automounts() {
    grep -qi microsoft /proc/version 2>/dev/null || return 0
    local letters="" letter mountpoint
    if command -v powershell.exe >/dev/null 2>&1; then
        letters=$(timeout 5 powershell.exe -NoProfile -NonInteractive -Command \
            '(Get-PSDrive -PSProvider FileSystem).Name' 2>/dev/null \
            | tr -d '\r' | grep -Eo '^[A-Za-z]$' | tr '[:upper:]' '[:lower:]' || true)
    fi
    for letter in $letters; do
        mountpoint="/mnt/$letter"
        [ -d "$mountpoint" ] || mkdir -p "$mountpoint" 2>/dev/null || true
        timeout 2 ls "$mountpoint" >/dev/null 2>&1 || true
        if [ -d "$mountpoint" ] && ! grep -Eq "[[:space:]]${mountpoint}[[:space:]]" /proc/mounts 2>/dev/null; then
            rmdir "$mountpoint" 2>/dev/null || true
        fi
    done
    for mountpoint in /mnt/[a-z]; do
        [ -d "$mountpoint" ] || continue
        timeout 2 ls "$mountpoint" >/dev/null 2>&1 || true
    done
}

storage_mount_root() {
    local p="${1%/}"
    local rest
    case "$p" in
        /mnt/[a-z]) echo "$p" ;;
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
        *) echo "$p" ;;
    esac
}

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
