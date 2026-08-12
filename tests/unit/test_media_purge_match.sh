#!/bin/bash
# Unit tests for media-purge qB folder-key matching (synthetic titles only).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../helpers.sh"

test_suite "media-purge qB token match"

purge="$REPO_ROOT/scripts/media-purge.sh"
assert_true "media-purge.sh exists" "[ -f \"$purge\" ]"

if bash "$purge" --match-self-test; then
    _TEST_PASSES=$((_TEST_PASSES + 1))
    echo "  PASS: media-purge --match-self-test"
else
    _TEST_FAILURES=$((_TEST_FAILURES + 1))
    echo "  FAIL: media-purge --match-self-test"
fi

test_summary
