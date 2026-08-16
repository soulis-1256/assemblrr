#!/bin/bash
set -euo pipefail

# assemblrr Bootstrap Script
# Clones the repository and launches setup.sh
#
# Usage (bash/zsh):
#   bash <(curl -fsSL https://raw.githubusercontent.com/soulis-1256/assemblrr/main/platform/linux/bootstrap.sh)
#   bash <(curl -fsSL ...) --ref dev
#   ASSEMBLRR_REF=dev bash <(curl -fsSL ...)
# Usage (fish):
#   bash (curl -fsSL ... | psub)
#   bash (curl -fsSL ... | psub) --ref dev
#
# Ref selection (first match wins among flags; env is the default):
#   --ref REF | --branch REF | ASSEMBLRR_REF (default: main)
# Remaining args are passed to bin/setup.sh.

REPO="https://github.com/soulis-1256/assemblrr"
REF="${ASSEMBLRR_REF:-main}"
setup_args=()

while [ $# -gt 0 ]; do
    case "$1" in
        --ref|--branch)
            if [ -z "${2:-}" ]; then
                echo "error: $1 requires a value (branch, tag, or commit-ish)" >&2
                exit 1
            fi
            REF="$2"
            shift 2
            ;;
        --ref=*|--branch=*)
            REF="${1#*=}"
            if [ -z "$REF" ]; then
                echo "error: empty ref" >&2
                exit 1
            fi
            shift
            ;;
        *)
            setup_args+=("$1")
            shift
            ;;
    esac
done

TMPDIR=$(mktemp -d /tmp/assemblrr.XXXXXX)
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

echo "Cloning assemblrr @ ${REF}..."
if ! git clone --depth=1 --branch "$REF" "$REPO" "$TMPDIR"; then
    echo "error: failed to clone ${REPO} @ ${REF}" >&2
    exit 1
fi

cd "$TMPDIR"
bash bin/setup.sh "${setup_args[@]}"
