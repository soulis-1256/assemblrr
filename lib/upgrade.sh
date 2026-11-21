#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# assemblrr upgrade engine — source tree -> install dir (git ref or local --from)
# Provides: upgrade_app, apply_managed_files, run_migrations, validate_install_compose
# Requires: core.sh, branding.sh, compose.sh, managed_files.sh; INSTALL_DIR set

if [ -n "${_ASSEMBLRR_UPGRADE_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_UPGRADE_SOURCED=1

UPGRADE_DEFAULT_REF="main"
UPGRADE_VERSION_FILE=".assemblrr-version"
UPGRADE_CHANNEL_FILE=".assemblrr-channel"
UPGRADE_MIGRATIONS_FILE=".assemblrr-migrations"

_upgrade_default_ref() {
    local install_dir="${1:-${INSTALL_DIR:-}}"
    local ref=""
    if [ -n "${ASSEMBLRR_CHANNEL:-}" ]; then
        printf '%s\n' "$ASSEMBLRR_CHANNEL"
        return 0
    fi
    if [ -n "$install_dir" ] && [ -f "$install_dir/$UPGRADE_CHANNEL_FILE" ]; then
        ref=$(tr -d '\r\n ' < "$install_dir/$UPGRADE_CHANNEL_FILE" 2>/dev/null || true)
    fi
    printf '%s\n' "${ref:-$UPGRADE_DEFAULT_REF}"
}

_write_upgrade_channel() {
    local install_dir="$1"
    local ref="$2"
    [ -n "$ref" ] || return 0
    printf '%s\n' "$ref" > "$install_dir/$UPGRADE_CHANNEL_FILE"
}

# resolve_upgrade_source --from DIR | --ref REF
# Sets: UPGRADE_SOURCE_ROOT, UPGRADE_SOURCE_LABEL, UPGRADE_SOURCE_TEMP
resolve_upgrade_source() {
    local from_dir=""
    local ref
    ref=$(_upgrade_default_ref "${INSTALL_DIR:-}")
    local tmp=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --from)
                from_dir="${2:-}"
                shift 2
                ;;
            --ref|--branch)
                ref="${2:-}"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    UPGRADE_SOURCE_TEMP="${UPGRADE_SOURCE_TEMP:-}"
    UPGRADE_SOURCE_ROOT=""
    UPGRADE_SOURCE_LABEL=""

    if [ -n "$from_dir" ]; then
        if [ ! -d "$from_dir" ]; then
            log_error "Upgrade source not a directory: $from_dir"
            return 1
        fi
        UPGRADE_SOURCE_ROOT=$(cd "$from_dir" && pwd)
        if [ ! -f "$UPGRADE_SOURCE_ROOT/lib/core.sh" ] || [ ! -f "$UPGRADE_SOURCE_ROOT/compose/base.yaml" ]; then
            log_error "Not an assemblrr source tree (missing lib/core.sh or compose/base.yaml): $UPGRADE_SOURCE_ROOT"
            return 1
        fi
        local sha="unknown"
        if [ -d "$UPGRADE_SOURCE_ROOT/.git" ]; then
            sha=$(git -C "$UPGRADE_SOURCE_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
        fi
        UPGRADE_SOURCE_LABEL="local:${UPGRADE_SOURCE_ROOT}@${sha}"
        return 0
    fi

    local repo="${APP_REPO_URL:-https://github.com/soulis-1256/assemblrr}"
    tmp=$(mktemp -d)
    UPGRADE_SOURCE_TEMP="$tmp"
    if ! wait_while "Fetching assemblrr @ ${ref}" git clone --depth=1 --branch "$ref" "$repo" "$tmp/assemblrr"; then
        rm -rf "$tmp/assemblrr"
        if ! wait_while "Fetching assemblrr (fallback clone)" git clone --depth=1 "$repo" "$tmp/assemblrr"; then
            rm -rf "$UPGRADE_SOURCE_TEMP"
            UPGRADE_SOURCE_TEMP=""
            log_error "Failed to clone ${repo}. Check network and APP_REPO_URL."
            return 1
        fi
        if ! git -C "$tmp/assemblrr" fetch --depth=1 origin "$ref" 2>/dev/null \
            || ! git -C "$tmp/assemblrr" checkout -q FETCH_HEAD 2>/dev/null; then
            if ! git -C "$tmp/assemblrr" checkout -q "$ref" 2>/dev/null; then
                rm -rf "$UPGRADE_SOURCE_TEMP"
                UPGRADE_SOURCE_TEMP=""
                log_error "Failed to checkout ref: $ref"
                return 1
            fi
        fi
    fi
    UPGRADE_SOURCE_ROOT="$tmp/assemblrr"
    local sha
    sha=$(git -C "$UPGRADE_SOURCE_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    UPGRADE_SOURCE_LABEL="git:${repo}@${ref}(${sha})"
    return 0
}

cleanup_upgrade_source() {
    if [ -n "${UPGRADE_SOURCE_TEMP:-}" ] && [ -d "$UPGRADE_SOURCE_TEMP" ]; then
        rm -rf "$UPGRADE_SOURCE_TEMP"
    fi
    UPGRADE_SOURCE_TEMP=""
    if [ -n "${_UPGRADE_ROLLBACK_DIR:-}" ] && [ -d "$_UPGRADE_ROLLBACK_DIR" ]; then
        rm -rf "$_UPGRADE_ROLLBACK_DIR"
    fi
    _UPGRADE_ROLLBACK_DIR=""
}

_stage_managed_rollback() {
    local source_root="$1"
    local install_dir="$2"
    local stage_dir="$3"
    local src dest dest_path

    UPGRADE_SOURCE_ROOT="$source_root"
    if [ -f "$source_root/lib/managed_files.sh" ]; then
        # shellcheck source=/dev/null
        source "$source_root/lib/managed_files.sh"
    fi

    : >"$stage_dir/.added"
    while IFS='|' read -r src dest; do
        [ -z "$dest" ] && continue
        [[ "$dest" =~ ^# ]] && continue
        dest_path="$install_dir/$dest"
        if [ -f "$dest_path" ]; then
            mkdir -p "$stage_dir/files/$(dirname "$dest")"
            cp -p "$dest_path" "$stage_dir/files/$dest" 2>/dev/null || cp "$dest_path" "$stage_dir/files/$dest"
        else
            printf '%s\n' "$dest" >>"$stage_dir/.added"
        fi
    done < <(list_managed_files)
}

_restore_managed_rollback() {
    local install_dir="$1"
    local stage_dir="$2"
    [ -n "$stage_dir" ] && [ -d "$stage_dir" ] || return 0
    if [ -d "$stage_dir/files" ]; then
        cp -a "$stage_dir/files/." "$install_dir/" 2>/dev/null || true
    fi
    if [ -f "$stage_dir/.added" ]; then
        local rel
        while IFS= read -r rel; do
            [ -n "$rel" ] && rm -f "$install_dir/$rel" 2>/dev/null || true
        done <"$stage_dir/.added"
    fi
    log_warning "Rolled back managed files in ${install_dir} after failed validation."
}

apply_managed_files() {
    local source_root="$1"
    local install_dir="$2"
    local check_only="${3:-0}"
    local src dest src_path dest_path
    local copied=0 skipped=0 missing=0

    UPGRADE_SOURCE_ROOT="$source_root"
    # Prefer source tree manifest (may include new modules/overlays).
    # shellcheck source=/dev/null
    if [ -f "$source_root/lib/managed_files.sh" ]; then
        source "$source_root/lib/managed_files.sh"
    else
        source "${_lib_dir:-}/managed_files.sh"
    fi

    while IFS='|' read -r src dest; do
        [ -z "$src" ] && continue
        [[ "$src" =~ ^# ]] && continue
        src_path="$source_root/$src"
        dest_path="$install_dir/$dest"
        if [ ! -f "$src_path" ]; then
            log_warning "Managed file missing in source (skip): $src"
            missing=$((missing + 1))
            continue
        fi
        if [ "$check_only" = "1" ]; then
            if [ ! -f "$dest_path" ]; then
                log_info "  [new]  $dest"
            elif ! cmp -s "$src_path" "$dest_path" 2>/dev/null; then
                log_info "  [diff] $dest"
            else
                skipped=$((skipped + 1))
                continue
            fi
            copied=$((copied + 1))
            continue
        fi
        mkdir -p "$(dirname "$dest_path")"
        cp "$src_path" "$dest_path"
        case "$src" in
            scripts/*.sh|scripts/*.py|bin/*.sh|migrations/*.sh|platform/linux/*.sh)
                chmod +x "$dest_path" 2>/dev/null || true
                ;;
        esac
        copied=$((copied + 1))
    done < <(list_managed_files)

    if [ "$check_only" = "1" ]; then
        log_info "Managed files: ${copied} would change, ${skipped} identical, ${missing} missing in source"
    else
        log_success "Applied ${copied} managed file(s) (${missing} missing in source)"
    fi
}

# --- Migrations ---

_migration_already_recorded() {
    local install_dir="$1"
    local mid="$2"
    local f="$install_dir/$UPGRADE_MIGRATIONS_FILE"
    [ -f "$f" ] || return 1
    grep -qxF "$mid" "$f" 2>/dev/null
}

_record_migration() {
    local install_dir="$1"
    local mid="$2"
    local f="$install_dir/$UPGRADE_MIGRATIONS_FILE"
    touch "$f"
    if ! grep -qxF "$mid" "$f" 2>/dev/null; then
        echo "$mid" >> "$f"
    fi
}

run_migrations() {
    local source_root="$1"
    local install_dir="$2"
    local check_only="${3:-0}"
    local mig_dir="$source_root/migrations"
    local f

    if [ ! -d "$mig_dir" ]; then
        log_info "No migrations directory in source"
        return 0
    fi

    while IFS= read -r -d '' f; do
        # Unset BEFORE sourcing so a malformed file never inherits the previous migration's handlers
        unset -f migration_should_skip migration_apply 2>/dev/null || true
        migration_id=""
        migration_description=""
        # shellcheck source=/dev/null
        source "$f"

        if [ -z "${migration_id:-}" ]; then
            log_warning "Migration without migration_id: $f"
            unset -f migration_should_skip migration_apply 2>/dev/null || true
            continue
        fi

        if _migration_already_recorded "$install_dir" "$migration_id"; then
            log_info "Migration ${migration_id}: already recorded — skip"
            unset -f migration_should_skip migration_apply 2>/dev/null || true
            continue
        fi

        if type migration_should_skip >/dev/null 2>&1 && migration_should_skip "$install_dir"; then
            log_info "Migration ${migration_id}: detect says skip (${migration_description:-})"
            if [ "$check_only" != "1" ]; then
                _record_migration "$install_dir" "$migration_id"
            fi
            unset -f migration_should_skip migration_apply 2>/dev/null || true
            continue
        fi

        if [ "$check_only" = "1" ]; then
            log_info "Migration ${migration_id}: WOULD APPLY — ${migration_description:-}"
            unset -f migration_should_skip migration_apply 2>/dev/null || true
            continue
        fi

        log_info "Migration ${migration_id}: applying — ${migration_description:-}"
        if type migration_apply >/dev/null 2>&1; then
            if migration_apply "$install_dir"; then
                _record_migration "$install_dir" "$migration_id"
                log_success "Migration ${migration_id}: done"
            else
                unset -f migration_should_skip migration_apply 2>/dev/null || true
                log_error "Migration ${migration_id}: failed"
                return 1
            fi
        else
            log_warning "Migration ${migration_id}: no migration_apply — recording as done"
            _record_migration "$install_dir" "$migration_id"
        fi
        unset -f migration_should_skip migration_apply 2>/dev/null || true
    done < <(find "$mig_dir" -maxdepth 1 -type f -name '*.sh' -print0 | sort -z)
}

write_upgrade_version() {
    local install_dir="$1"
    local label="$2"
    printf '%s\n' "$label" > "$install_dir/$UPGRADE_VERSION_FILE"
}

refresh_user_cli() {
    local install_dir="$1"
    if [ -n "$install_dir" ] && [ ! -f "$HOME/.assemblrr-config" ]; then
        write_install_pointer "$install_dir" "${MEDIA_DIRECTORY:-}"
    fi
    install_user_cli_wrapper
}

validate_install_compose() {
    local install_dir="$1"
    build_compose_args "$install_dir" "${VPN_ENABLED:-n}"
    if ! run_docker compose "${COMPOSE_ARGS[@]}" config --quiet 2>/tmp/assemblrr-compose-validate.err; then
        log_warning "Compose validation failed:"
        sed 's/^/  /' /tmp/assemblrr-compose-validate.err 2>/dev/null | head -20
        return 1
    fi
    return 0
}

# upgrade_app [--check] [--from DIR] [--ref REF] [--skip-backup] [--skip-stack|--no-restart] [--skip-wire] [-y]
upgrade_app() {
    local check_only=0
    local skip_backup=0
    local skip_stack=0
    local skip_wire=0
    local assume_yes=0
    local stage2=0
    local from_dir=""
    local ref=""
    local explicit_ref=0
    local parse_args=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --check) check_only=1; shift ;;
            --skip-backup) skip_backup=1; shift ;;
            --skip-stack|--no-restart) skip_stack=1; shift ;;
            --skip-wire) skip_wire=1; shift ;;
            -y|--yes) assume_yes=1; shift ;;
            --stage2) stage2=1; shift ;;
            --from)
                from_dir="${2:-}"
                [ -z "$from_dir" ] && log_error "Usage: upgrade --from DIR"
                parse_args+=(--from "$from_dir")
                shift 2
                ;;
            --ref|--branch)
                ref="${2:-}"
                [ -z "$ref" ] && log_error "Usage: upgrade --ref REF"
                explicit_ref=1
                parse_args+=(--ref "$ref")
                shift 2
                ;;
            *)
                log_error "Unknown upgrade option: $1"
                return 1
                ;;
        esac
    done

    if [ -z "$from_dir" ] && [ -z "$ref" ]; then
        ref=$(_upgrade_default_ref "$INSTALL_DIR")
        parse_args+=(--ref "$ref")
    fi

    trap cleanup_upgrade_source EXIT

    resolve_upgrade_source "${parse_args[@]}"

    if [ "$stage2" -eq 0 ]; then
        log_info "Upgrade source: $UPGRADE_SOURCE_LABEL"
        log_info "Install:        $INSTALL_DIR"
        if [ -f "$INSTALL_DIR/$UPGRADE_VERSION_FILE" ]; then
            log_info "Current:        $(cat "$INSTALL_DIR/$UPGRADE_VERSION_FILE")"
        else
            log_info "Current:        (no version stamp — first upgrade)"
        fi
        echo

        log_info "=== Plan: managed files ==="
        apply_managed_files "$UPGRADE_SOURCE_ROOT" "$INSTALL_DIR" 1
        echo
        log_info "=== Plan: migrations ==="
        run_migrations "$UPGRADE_SOURCE_ROOT" "$INSTALL_DIR" 1
        echo

        if [ "$check_only" = "1" ]; then
            log_success "Dry-run complete (no changes made)."
            cleanup_upgrade_source
            trap - EXIT
            return 0
        fi

        if [ "$assume_yes" != "1" ]; then
            read_prompt "Apply this upgrade to ${INSTALL_DIR}? [y/N]: "
            if [[ ! ${REPLY,,} =~ ^y$ ]]; then
                log_info "Upgrade cancelled."
                cleanup_upgrade_source
                trap - EXIT
                return 0
            fi
        fi

        if [ "$skip_backup" != "1" ]; then
            local backup_dest="${HOME}/${APP_NAME:-assemblrr}-backups"
            log_info "Backing up to ${backup_dest}..."
            if type backup_app >/dev/null 2>&1; then
                backup_app "$backup_dest"
            else
                log_warning "backup_app not available — skipping automatic backup"
            fi
        else
            log_warning "Skipping backup (--skip-backup)"
        fi

        _UPGRADE_ROLLBACK_DIR=$(mktemp -d)
        _stage_managed_rollback "$UPGRADE_SOURCE_ROOT" "$INSTALL_DIR" "$_UPGRADE_ROLLBACK_DIR"

        log_info "Applying managed files..."
        apply_managed_files "$UPGRADE_SOURCE_ROOT" "$INSTALL_DIR" 0
        refresh_user_cli "$INSTALL_DIR"

        # Re-exec the newly installed cli.sh so newly split lib/*.sh modules execute cleanly
        if [ "${ASSEMBLRR_UPGRADE_REEXEC:-1}" = "1" ] && [ -f "$INSTALL_DIR/cli.sh" ] \
            && [[ "${BASH_SOURCE[0]:-}" != "" ]] && [[ "${0##*/}" == cli.sh || "${0##*/}" == assemblrr ]]; then
            local -a next_args=(upgrade --stage2 --from "$UPGRADE_SOURCE_ROOT" --skip-backup -y)
            [ "$skip_stack" = "1" ] && next_args+=(--skip-stack)
            [ "$skip_wire" = "1" ] && next_args+=(--skip-wire)
            [ "$explicit_ref" = "1" ] && next_args+=(--ref "$ref")
            export UPGRADE_SOURCE_TEMP _UPGRADE_ROLLBACK_DIR
            export _ASSEMBLRR_UPGRADE_LABEL_OVERRIDE="$UPGRADE_SOURCE_LABEL"
            trap - EXIT
            exec bash "$INSTALL_DIR/cli.sh" "${next_args[@]}"
        fi
    fi

    local stamp_label="${_ASSEMBLRR_UPGRADE_LABEL_OVERRIDE:-$UPGRADE_SOURCE_LABEL}"

    if type prepare_install_dirs >/dev/null 2>&1; then
        prepare_install_dirs "$INSTALL_DIR"
    fi

    log_info "Running migrations..."
    run_migrations "$UPGRADE_SOURCE_ROOT" "$INSTALL_DIR" 0

    if ! validate_install_compose "$INSTALL_DIR"; then
        _restore_managed_rollback "$INSTALL_DIR" "${_UPGRADE_ROLLBACK_DIR:-}"
        cleanup_upgrade_source
        trap - EXIT
        log_error "Compose invalid after upgrade — managed files restored to previous state."
        return 1
    fi

    write_upgrade_version "$INSTALL_DIR" "$stamp_label"
    if [ "$explicit_ref" = "1" ] && [ -n "$ref" ]; then
        _write_upgrade_channel "$INSTALL_DIR" "$ref"
    fi

    if [ "$skip_stack" = "1" ]; then
        log_info "Skipping stack restart (--skip-stack)"
    else
        log_info "Bringing stack up with updated compose..."
        build_compose_args "$INSTALL_DIR" "${VPN_ENABLED:-n}"
        # --remove-orphans drops containers for services removed from managed compose
        # while leaving services defined in custom.yaml alone.
        if ! compose_up_stack "default" --build; then
            log_error "docker compose up failed. Restore with: ${APP_CLI_NAME:-assemblrr} restore <backup.tar.gz>"
            return 1
        fi
    fi

    if [ "$skip_wire" = "1" ]; then
        log_info "Skipping service wiring (--skip-wire)"
    elif [ -f "$INSTALL_DIR/config.sh" ]; then
        log_info "Wiring services..."
        # Re-wire must not open fzf/read prompts during unattended upgrades.
        if ASSEMBLRR_NONINTERACTIVE=1 bash "$INSTALL_DIR/config.sh"; then
            log_success "Service wiring completed"
        else
            log_warning "Service wiring reported failures. Fix issues, then re-run: ${APP_CLI_NAME:-assemblrr} config apply"
        fi
    else
        log_warning "config.sh missing after upgrade — cannot wire services"
    fi

    cleanup_upgrade_source
    trap - EXIT

    log_success "Upgrade complete."
    log_info "Version: $(cat "$INSTALL_DIR/$UPGRADE_VERSION_FILE" 2>/dev/null || echo unknown)"
    log_info "If something is wrong: ${APP_CLI_NAME:-assemblrr} restore <backup.tar.gz>"
    return 0
}
