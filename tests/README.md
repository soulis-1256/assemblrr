# Tests

Runtime scripts live in `scripts/` (installed with the stack). **All tests live here.**

## Layout

```text
tests/
  helpers.sh                 # assertions, install discovery, qBittorrent helpers
  run.sh                     # entrypoint
  unit/
    test_compose.sh          # lib/compose.sh
    test_core.sh             # expand_path, safe_source, rm guards
    test_vpn_secrets.sh      # validate_vpn_secrets
    test_compose_config.sh   # docker compose config (needs Docker)
  integration/
    watchdog_stall.sh        # live qBittorrent + vpn-watchdog (opt-in)
```

## Quick start

```bash
# From repo root
./tests/run.sh              # unit tests (no Docker required)
./tests/run.sh compose      # docker compose config validation
./tests/run.sh all          # unit + compose + shellcheck (if installed)
make test                   # same as ./tests/run.sh all
```

## Live integration (watchdog)

Mutates a **running** qBittorrent (sets `max_connecs=0`, adds a public Ubuntu magnet, runs `vpn-watchdog.sh`). Always restores settings on exit.

```bash
ASSEMBLRR_ALLOW_LIVE_TEST=1 ./tests/run.sh integration

# Or point at a non-default install:
ASSEMBLRR_DIR=~/assemblrr ASSEMBLRR_ALLOW_LIVE_TEST=1 \
  ./tests/integration/watchdog_stall.sh
```

Without `ASSEMBLRR_ALLOW_LIVE_TEST=1` the script exits with code 2 and does nothing.

Config resolution order:

1. `ASSEMBLRR_DIR`
2. `ASSEMBLRR_CONFIG` (path to `.assemblrr-config`)
3. `find_install_directory` from `lib/core.sh`
4. `$HOME/assemblrr`

## Notes

- Unit tests use a tiny bash assertion helper (no BATS dependency).
- Compose checks create a temporary fixture with dummy secret files so `docker compose config` succeeds.
- Install [shellcheck](https://www.shellcheck.net/) for `./tests/run.sh lint`.
