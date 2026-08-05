#!/bin/bash
# .env.example stays aligned with setup's envsubst key list and actually substitutes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../helpers.sh"

example="$REPO_ROOT/.env.example"
setup="$REPO_ROOT/bin/setup.sh"

test_suite ".env.example exists"
assert_true "repo has .env.example" "[ -f \"$example\" ]"
assert_true "setup.sh exists" "[ -f \"$setup\" ]"

mapfile -t template_keys < <(
    grep -E '^[A-Za-z_][A-Za-z0-9_]*=\$\{[A-Za-z_][A-Za-z0-9_]*\}$' "$example" \
        | sed 's/=.*//' \
        | sort -u
)

test_suite "template has expected keys"
if [ "${#template_keys[@]}" -gt 0 ]; then
    _TEST_PASSES=$((_TEST_PASSES + 1))
    echo "  PASS: found ${#template_keys[@]} KEY=\${KEY} lines"
else
    _TEST_FAILURES=$((_TEST_FAILURES + 1))
    echo "  FAIL: no KEY=\${KEY} lines in .env.example"
fi

# First envsubst '...' argument in setup (literal key list)
envsubst_arg=$(
    grep -E "envsubst '" "$setup" | head -1 \
        | sed -n "s/.*envsubst '\\([^']*\\)'.*/\\1/p"
)

test_suite "setup envsubst list"
if [ -n "$envsubst_arg" ]; then
    _TEST_PASSES=$((_TEST_PASSES + 1))
    echo "  PASS: found envsubst key list in setup.sh"
else
    _TEST_FAILURES=$((_TEST_FAILURES + 1))
    echo "  FAIL: no envsubst '...' list in setup.sh"
    test_summary
    exit 1
fi

mapfile -t envsubst_keys < <(
    # Parse ${NAME} tokens without expanding them
    printf '%s\n' "$envsubst_arg" \
        | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' \
        | sed 's/^\${//;s/}$//' \
        | sort -u
)

test_suite "template keys match envsubst list"
for key in "${template_keys[@]}"; do
    if printf '%s\n' "${envsubst_keys[@]}" | grep -qx "$key"; then
        _TEST_PASSES=$((_TEST_PASSES + 1))
        echo "  PASS: $key in envsubst list"
    else
        _TEST_FAILURES=$((_TEST_FAILURES + 1))
        echo "  FAIL: $key missing from setup envsubst list"
    fi
done

for key in "${envsubst_keys[@]}"; do
    if printf '%s\n' "${template_keys[@]}" | grep -qx "$key"; then
        _TEST_PASSES=$((_TEST_PASSES + 1))
        echo "  PASS: $key present in .env.example"
    else
        _TEST_FAILURES=$((_TEST_FAILURES + 1))
        echo "  FAIL: envsubst lists $key but .env.example has no matching assignment"
    fi
done

test_suite "envsubst leaves no placeholders"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

export PUID=1000 PGID=1000 \
    MEDIA_DIRECTORY=/data/media INSTALL_DIRECTORY=/opt/assemblrr \
    MEDIA_SERVICE=jellyfin TZ=UTC \
    VPN_ENABLED=n VPN_SERVICE= VPN_TYPE=openvpn \
    WIREGUARD_ADDRESSES= \
    PORT_FORWARD_ONLY=off VPN_PORT_FORWARDING=off \
    API_HOST=127.0.0.1

envsubst "$envsubst_arg" < "$example" > "$tmp"

if grep -E '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$tmp" >/dev/null; then
    _TEST_FAILURES=$((_TEST_FAILURES + 1))
    echo "  FAIL: unsubstituted placeholders remain:"
    grep -E '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$tmp" | sed 's/^/        /' || true
else
    _TEST_PASSES=$((_TEST_PASSES + 1))
    echo "  PASS: no leftover placeholders"
fi

for key in PUID INSTALL_DIRECTORY MEDIA_SERVICE API_HOST; do
    val=$(grep -E "^${key}=" "$tmp" | head -1 | cut -d= -f2- || true)
    if [ -n "$val" ]; then
        _TEST_PASSES=$((_TEST_PASSES + 1))
        echo "  PASS: $key set ($val)"
    else
        _TEST_FAILURES=$((_TEST_FAILURES + 1))
        echo "  FAIL: $key empty or missing in generated .env"
    fi
done

test_summary
