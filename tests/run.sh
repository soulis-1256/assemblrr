#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Usage: ./tests/run.sh [unit|compose|integration|lint|all]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

MODE="${1:-unit}"
FAILED=0

run_unit() {
    echo "Running shell unit tests..."
    local count=0 f
    while IFS= read -r -d '' f; do
        count=$((count + 1))
        echo ""
        echo "######## $(basename "$f") ########"
        if bash "$f"; then
            echo "-> OK"
        else
            echo "-> FAILED"
            FAILED=$((FAILED + 1))
        fi
    done < <(find "$SCRIPT_DIR/unit" -maxdepth 1 -type f -name 'test_*.sh' -print0 | sort -z)

    if [ "$count" -eq 0 ]; then
        echo "No shell unit tests found under $SCRIPT_DIR/unit"
        FAILED=$((FAILED + 1))
    fi

    if command -v python3 >/dev/null 2>&1; then
        echo ""
        echo "######## Python unittest suite ########"
        if python3 -m unittest discover -s "$SCRIPT_DIR/unit" -p 'test_*.py' -v; then
            echo "-> OK"
        else
            echo "-> FAILED"
            FAILED=$((FAILED + 1))
        fi
    fi
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
    local f
    for f in \
        "$SCRIPT_DIR/integration/watchdog_stall.sh" \
        "$SCRIPT_DIR/integration/media_purge_e2e.sh" \
        "$SCRIPT_DIR/integration/usenet_mock_e2e.sh"
    do
        [ -f "$f" ] || continue
        echo ""
        echo "######## $(basename "$f") ########"
        if bash "$f"; then
            echo "-> OK"
        else
            local rc=$?
            echo "-> FAILED (exit $rc)"
            FAILED=$((FAILED + 1))
        fi
    done
}

run_lint() {
    local files=() f
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(find bin lib scripts migrations platform/linux tests -name '*.sh' -print0 2>/dev/null)

    if [ "${#files[@]}" -gt 0 ]; then
        echo "Running bash -n syntax checks (${#files[@]} files)..."
        if bash -n "${files[@]}"; then
            echo "bash -n: OK"
        else
            echo "bash -n: FAILED"
            FAILED=$((FAILED + 1))
        fi
    fi

    if command -v python3 >/dev/null 2>&1; then
        local py_files=()
        while IFS= read -r -d '' f; do
            py_files+=("$f")
        done < <(find scripts tests -name '*.py' -print0 2>/dev/null)
        if [ "${#py_files[@]}" -gt 0 ]; then
            echo "Running Python py_compile (${#py_files[@]} files)..."
            if python3 -m py_compile "${py_files[@]}"; then
                echo "py_compile: OK"
            else
                echo "py_compile: FAILED"
                FAILED=$((FAILED + 1))
            fi
        fi
    fi

    if ! command -v shellcheck >/dev/null 2>&1; then
        if [ "${CI:-}" = "true" ]; then
            echo "ERROR: shellcheck is missing in CI environment" >&2
            FAILED=$((FAILED + 1))
            return 1
        fi
        echo "shellcheck not installed — skip locally (enforced in CI)"
        echo "  Install: https://github.com/koalaman/shellcheck#installing"
        return 0
    fi

    echo "Running shellcheck..."
    if shellcheck -x -e SC1091,SC2034 "${files[@]}"; then
        echo "shellcheck: OK"
    else
        echo "shellcheck: FAILED"
        FAILED=$((FAILED + 1))
    fi
}

case "$MODE" in
    unit) run_unit ;;
    compose) run_compose ;;
    integration|live) run_integration ;;
    lint) run_lint ;;
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
