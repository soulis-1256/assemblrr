#!/bin/bash
# assemblrr upgrade engine — source tree → install dir (git ref or local --from)
# Provides: upgrade_app, upgrade_check
# Requires: core.sh, branding.sh, compose.sh, managed_files.sh; INSTALL_DIR set
# Optional: backup_app from cli context

if [ -n "${_ASSEMBLRR_UPGRADE_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_UPGRADE_SOURCED=1

# Defaults
UPGRADE_DEFAULT_REF="main"
UPGRADE_VERSION_FILE=".assemblrr-version"
UPGRADE_MIGRATIONS_FILE=".assemblrr-migrations"

# --- Source resolution (transport layer) ---

# resolve_upgrade_source --from DIR | --ref REF
# Sets: UPGRADE_SOURCE_ROOT, UPGRADE_SOURCE_LABEL, UPGRADE_SOURCE_TEMP (if cleanup needed)
resolve_upgrade_source() {
    local from_dir=""
    local ref="${UPGRADE_DEFAULT_REF}"
    local tmp=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --from)
                from_dir="${2:-}"
                shift 2
                ;;
            --ref)
                ref="${2:-}"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    UPGRADE_SOURCE_TEMP=""
    UPGRADE_SOURCE_ROOT=""
    UPGRADE_SOURCE_LABEL=""

    if [ -n "$from_dir" ]; then
        if [ ! -d "$from_dir" ]; then
            log_error "Upgrade source not a directory: $from_dir"
        fi
        UPGRADE_SOURCE_ROOT=$(cd "$from_dir" && pwd)
        if [ ! -f "$UPGRADE_SOURCE_ROOT/lib/core.sh" ] || [ ! -f "$UPGRADE_SOURCE_ROOT/compose/base.yaml" ]; then
            log_error "Not an assemblrr source tree (missing lib/core.sh or compose/base.yaml): $UPGRADE_SOURCE_ROOT"
        fi
        local sha="unknown"
        if [ -d "$UPGRADE_SOURCE_ROOT/.git" ]; then
            sha=$(git -C "$UPGRADE_SOURCE_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
        fi
        UPGRADE_SOURCE_LABEL="local:${UPGRADE_SOURCE_ROOT}@${sha}"
        return 0
    fi

    # Git transport (production path) — same apply path as --from
    local repo="${APP_REPO_URL:-https://github.com/soulis-1256/assemblrr}"
    tmp=$(mktemp -d)
    UPGRADE_SOURCE_TEMP="$tmp"
    if ! wait_while "Fetching assemblrr @ ${ref}" git clone --depth=1 --branch "$ref" "$repo" "$tmp/assemblrr"; then
        # branch might be a commit or default branch name failed; try without --branch then checkout
        rm -rf "$tmp/assemblrr"
        if ! wait_while "Fetching assemblrr (default branch)" git clone --depth=1 "$repo" "$tmp/assemblrr"; then
            [ -n "$UPGRADE_SOURCE_TEMP" ] && rm -rf "$UPGRADE_SOURCE_TEMP"
            log_error "Failed to clone ${repo}. Check network and APP_REPO_URL."
        fi
        if [ "$ref" != "main" ] && [ "$ref" != "master" ]; then
            git -C "$tmp/assemblrr" fetch --depth=1 origin "$ref" 2>/dev/null || true
            git -C "$tmp/assemblrr" checkout "$ref" 2>/dev/null || \
                log_error "Failed to checkout ref: $ref"
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
}

# --- Managed files ---

apply_managed_files() {
    local source_root="$1"
    local install_dir="$2"
    local check_only="${3:-0}"
    local src dest src_path dest_path
    local copied=0 skipped=0 missing=0

    UPGRADE_SOURCE_ROOT="$source_root"
    # Prefer source tree manifest (may be newer than install).
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
            scripts/*|bin/cli.sh|bin/config.sh|bin/setup.sh) chmod +x "$dest_path" 2>/dev/null || true ;;
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
        # shellcheck disable=SC1090
        migration_id=""
        migration_description=""
        # shellcheck source=/dev/null
        source "$f"

        if [ -z "${migration_id:-}" ]; then
            log_warning "Migration without migration_id: $f"
            continue
        fi

        if _migration_already_recorded "$install_dir" "$migration_id"; then
            log_info "Migration ${migration_id}: already recorded — skip"
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
                log_error "Migration ${migration_id}: failed"
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

# --- CLI install refresh ---

refresh_user_cli() {
    local install_dir="$1"
    if [ -n "$install_dir" ] && [ ! -f "$HOME/.assemblrr-config" ]; then
        write_install_pointer "$install_dir" "${MEDIA_DIRECTORY:-}"
    fi
    install_user_cli_wrapper
}

# --- Validate compose after apply ---

validate_install_compose() {
    local install_dir="$1"
    build_compose_args "$install_dir" "${VPN_ENABLED:-n}"
    if ! run_docker compose "${COMPOSE_ARGS[@]}" --profile "${MEDIA_SERVICE:-jellyfin}" config --quiet 2>/tmp/assemblrr-compose-validate.err; then
        log_warning "Compose validation failed:"
        sed 's/^/  /' /tmp/assemblrr-compose-validate.err 2>/dev/null | head -20
        return 1
    fi
    return 0
}

# --- Public entrypoints ---

# upgrade_app [--check] [--from DIR] [--ref REF] [--skip-backup] [--skip-stack] [--skip-wire] [-y]
upgrade_app() {
    local check_only=0
    local skip_backup=0
    local skip_stack=0
    local skip_wire=0
    local assume_yes=0
    local from_dir=""
    local ref=""
    local parse_args=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --check) check_only=1; shift ;;
            --skip-backup) skip_backup=1; shift ;;
            --skip-stack) skip_stack=1; shift ;;
            --skip-wire) skip_wire=1; shift ;;
            -y|--yes) assume_yes=1; shift ;;
            --from)
                from_dir="${2:-}"
                [ -z "$from_dir" ] && log_error "Usage: upgrade --from DIR"
                parse_args+=(--from "$from_dir")
                shift 2
                ;;
            --ref)
                ref="${2:-}"
                [ -z "$ref" ] && log_error "Usage: upgrade --ref REF"
                parse_args+=(--ref "$ref")
                shift 2
                ;;
            *)
                log_error "Unknown upgrade option: $1"
                ;;
        esac
    done

    if [ -z "$from_dir" ] && [ -z "$ref" ]; then
        parse_args+=(--ref "$UPGRADE_DEFAULT_REF")
    fi

    trap cleanup_upgrade_source EXIT

    resolve_upgrade_source "${parse_args[@]}"
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
        read -p "Apply this upgrade to ${INSTALL_DIR}? [y/N]: " -r
        if [[ ! ${REPLY,,} =~ ^y$ ]]; then
            log_info "Upgrade cancelled."
            cleanup_upgrade_source
            trap - EXIT
            return 0
        fi
    fi

    # Backup (reuses cli backup_app if defined)
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

    log_info "Applying managed files..."
    apply_managed_files "$UPGRADE_SOURCE_ROOT" "$INSTALL_DIR" 0

    # Ensure migrations dir exists in install for record-keeping transparency
    mkdir -p "$INSTALL_DIR/migrations"
    if [ -d "$UPGRADE_SOURCE_ROOT/migrations" ]; then
        cp -a "$UPGRADE_SOURCE_ROOT/migrations/." "$INSTALL_DIR/migrations/" 2>/dev/null || true
    fi

    log_info "Running migrations..."
    run_migrations "$UPGRADE_SOURCE_ROOT" "$INSTALL_DIR" 0

    write_upgrade_version "$INSTALL_DIR" "$UPGRADE_SOURCE_LABEL"
    refresh_user_cli "$INSTALL_DIR"

    if ! validate_install_compose "$INSTALL_DIR"; then
        log_error "Compose invalid after upgrade. Restore with: ${APP_CLI_NAME:-assemblrr} restore <backup.tar.gz>"
    fi

    if [ "$skip_stack" = "1" ]; then
        log_info "Skipping stack restart (--skip-stack)"
    else
        log_info "Bringing stack up with updated compose..."
        build_compose_args "$INSTALL_DIR" "${VPN_ENABLED:-n}"
        # --remove-orphans drops containers for services removed from managed compose
        # (e.g. Portainer) while leaving services still defined in custom.yaml alone.
        if ! compose_up_stack "${MEDIA_SERVICE:-jellyfin}" --build; then
            log_error "docker compose up failed. Restore with: ${APP_CLI_NAME:-assemblrr} restore <backup.tar.gz>"
        fi
    fi

    if [ "$skip_wire" = "1" ]; then
        log_info "Skipping service wiring (--skip-wire)"
    elif [ -f "$INSTALL_DIR/config.sh" ]; then
        log_info "Wiring services..."
        # Re-wire must not open fzf/read prompts (would hang unattended upgrades
        # and can wipe Bazarr providers if the picker is skipped).
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
