#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# assemblrr Linux Bootstrap Script
# Clones the repository (branch, tag, or commit SHA) and launches bin/setup.sh
set -euo pipefail

REPO="https://github.com/soulis-1256/assemblrr"
REF="${ASSEMBLRR_REF:-main}"
setup_args=()

while [ $# -gt 0 ]; do
    case "$1" in
        --ref|--branch)
            if [ -z "${2:-}" ]; then
                echo "error: $1 requires a value (branch, tag, or commit SHA)" >&2
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
if ! git clone --depth=1 --branch "$REF" "$REPO" "$TMPDIR" 2>/dev/null; then
    rm -rf "$TMPDIR"
    mkdir -p "$TMPDIR"
    if ! git clone --depth=1 "$REPO" "$TMPDIR" \
        || ! git -C "$TMPDIR" fetch --depth=1 origin "$REF" 2>/dev/null \
        || ! git -C "$TMPDIR" checkout -q FETCH_HEAD 2>/dev/null; then
        echo "error: failed to clone/checkout ${REPO} @ ${REF}" >&2
        exit 1
    fi
fi

export ASSEMBLRR_INSTALL_REF="$REF"
cd "$TMPDIR"
bash bin/setup.sh "${setup_args[@]}"
