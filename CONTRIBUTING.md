# Contributing to assemblrr

Thank you for contributing to assemblrr!

## Repository Guidelines

1. **Shell script conventions**
   - Entrypoints (`bin/*.sh`, `scripts/*.sh`, `platform/linux/*.sh`) use `#!/usr/bin/env bash` or `#!/bin/bash` with `set -euo pipefail`.
   - Sourced libraries (`lib/*.sh`) must **not** call `set -euo pipefail` globally, and every `lib/*.sh` module must include a `_ASSEMBLRR_*_SOURCED` idempotency guard and `# SPDX-License-Identifier: GPL-3.0-or-later`.
   - Read interactive input with `read_prompt` / `read_masked` (`lib/tty.sh`), never raw `read -p` inside prompts/menus.
   - Load config files via `safe_source` (`lib/paths.sh`).
   - Do not modify Docker Compose pinned image tags without verifying upstream manifests and running full test validation.

2. **Legal & Content Neutrality**
   - Do **not** include real copyrighted titles, release group names, piracy domains, or third-party proprietary API keys in code, comments, documentation, or tests.
   - Use clearly synthetic titles (`Alpha Film (2016)`, `Sample Show`) or public-domain/CC fixtures (`Big Buck Bunny`, Ubuntu ISO).

3. **Running Checks Locally**
   ```bash
   make test-unit
   make test-compose
   python3 -m unittest discover -s tests/unit -p 'test_*.py' -v
   bash tests/run.sh --lint
   ```
   All tests must pass offline without external paid services or live piracy indexers.
