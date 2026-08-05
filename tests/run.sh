#!/bin/bash
# Assemblrr test runner
#
# Usage:
#   ./tests/run.sh              # unit tests only
#   ./tests/run.sh unit
#   ./tests/run.sh compose      # docker compose config checks
#   ./tests/run.sh integration  # live stack (requires ASSEMBLRR_ALLOW_LIVE_TEST=1)
#   ./tests/run.sh all          # unit + compose (not live integration)
#   ./tests/run.sh lint         # shellcheck if installed
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

MODE="${1:-unit}"
FAILED=0

run_scripts() {
    local dir="$1"
    local pattern="$2"
    local count=0
    local f
    shopt -s nullglob
    for f in "$dir"/$pattern; do
        count=$((count + 1))
        echo ""
        echo "######## $(basename "$f") ########"
        if bash "$f"; then
            echo "-> OK"
        else
            echo "-> FAILED"
            FAILED=$((FAILED + 1))
        fi
    done
    shopt -u nullglob
    if [ "$count" -eq 0 ]; then
        echo "No tests matched $dir/$pattern"
        FAILED=$((FAILED + 1))
    fi
}

run_unit() {
    echo "Running unit tests..."
    # Pure unit tests first (no docker required)
    for f in \
        "$SCRIPT_DIR/unit/test_compose.sh" \
        "$SCRIPT_DIR/unit/test_core.sh" \
        "$SCRIPT_DIR/unit/test_vpn_secrets.sh"
    do
        echo ""
        echo "######## $(basename "$f") ########"
        if bash "$f"; then
            echo "-> OK"
        else
            echo "-> FAILED"
            FAILED=$((FAILED + 1))
        fi
    done
}

run_compose() {
    echo "Running compose config checks..."
    echo ""
    echo "######## test_compose_config.sh ########"
    if bash "$SCRIPT_DIR/unit/test_compose_config.sh"; then
        echo "-> OK"
    else
        echo "-> FAILED"
        FAILED=$((FAILED + 1))
    fi
}

run_integration() {
    echo "Running live integration tests..."
    if bash "$SCRIPT_DIR/integration/watchdog_stall.sh"; then
        echo "-> OK"
    else
        local rc=$?
        echo "-> FAILED (exit $rc)"
        FAILED=$((FAILED + 1))
    fi
}

run_lint() {
    if ! command -v shellcheck >/dev/null 2>&1; then
        echo "shellcheck not installed — skip lint"
        echo "  Install: https://github.com/koalaman/shellcheck#installing"
        return 0
    fi
    echo "Running shellcheck..."
    local files=()
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(find bin lib scripts tests -name '*.sh' -print0 2>/dev/null)

    if [ "${#files[@]}" -eq 0 ]; then
        echo "No shell files found"
        return 0
    fi

    # SC1091: sourced paths resolved at runtime; SC2034: libs export for callers
    if shellcheck -x -e SC1091,SC2034 "${files[@]}"; then
        echo "shellcheck: OK"
    else
        echo "shellcheck: FAILED"
        FAILED=$((FAILED + 1))
    fi
}

case "$MODE" in
    unit)
        run_unit
        ;;
    compose)
        run_compose
        ;;
    integration|live)
        run_integration
        ;;
    lint)
        run_lint
        ;;
    all)
        run_unit
        run_compose
        run_lint
        ;;
    *)
        echo "Unknown mode: $MODE" >&2
        echo "Usage: $0 [unit|compose|integration|lint|all]" >&2
        exit 2
        ;;
esac

echo ""
if [ "$FAILED" -gt 0 ]; then
    echo "OVERALL: FAILED ($FAILED suite(s))"
    exit 1
fi
echo "OVERALL: OK"
exit 0
