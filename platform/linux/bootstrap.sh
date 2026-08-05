#!/bin/bash
set -euo pipefail

# assemblrr Bootstrap Script
# Clones the repository and launches setup.sh
# Usage (bash/zsh): bash <(curl -fsSL https://raw.githubusercontent.com/soulis-1256/assemblrr/main/platform/linux/bootstrap.sh)
# Usage (fish):     bash (curl -fsSL https://raw.githubusercontent.com/soulis-1256/assemblrr/main/platform/linux/bootstrap.sh | psub)

REPO="https://github.com/soulis-1256/assemblrr"
TMPDIR=$(mktemp -d /tmp/assemblrr.XXXXXX)

git clone --depth=1 "$REPO" "$TMPDIR"
cd "$TMPDIR"
bash bin/setup.sh "$@"
