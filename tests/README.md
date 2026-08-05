# Tests

Runtime hooks stay in `scripts/`. Tests live here.

```bash
./tests/run.sh              # unit
./tests/run.sh compose      # docker compose config
./tests/run.sh all          # unit + compose + shellcheck (if installed)
make test
```

## Live integration

Hits a running qBittorrent (stalls connections, runs `vpn-watchdog`). Opt-in only:

```bash
ASSEMBLRR_ALLOW_LIVE_TEST=1 ./tests/run.sh integration
```

Install dir: `ASSEMBLRR_DIR`, `ASSEMBLRR_CONFIG`, then `~/assemblrr`.
