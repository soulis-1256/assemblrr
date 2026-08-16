# Tests

Runtime hooks stay in `scripts/`. Tests live here.

```bash
./tests/run.sh              # unit
./tests/run.sh compose      # docker compose config
./tests/run.sh all          # unit + compose + shellcheck (if installed)
make test
```

## Live integration

Opt-in only — these mutate a real install:

```bash
ASSEMBLRR_ALLOW_LIVE_TEST=1 ./tests/run.sh integration
```

Or one suite:

```bash
ASSEMBLRR_ALLOW_LIVE_TEST=1 ./tests/integration/watchdog_stall.sh
ASSEMBLRR_ALLOW_LIVE_TEST=1 ./tests/integration/media_purge_e2e.sh
```

Install dir resolution: `ASSEMBLRR_DIR`, `ASSEMBLRR_CONFIG`, then `~/assemblrr`.

| Script | What it does |
|--------|----------------|
| `watchdog_stall.sh` | Stalls qBittorrent connections; checks `vpn-watchdog` |
| `media_purge_e2e.sh` | Full delete cascade for Big Buck Bunny (TMDB 10378) via **Radarr**, **Seerr** (file + request/gateway), and **Jellyfin** APIs |

### media_purge_e2e

Requires a running stack with purge wiring (`media-purge-watch` up, `seerr-gateway` on 5055, Radarr “Media Purge” notification on).

1. Creates a synthetic hardlinked title under `media/` + `torrents/` and a local qB torrent (no indexer grab).
2. **Radarr** `DELETE /api/v3/movie/:id?deleteFiles=true` → CustomScript → qB cleanup.
3. **Seerr** `DELETE /api/v1/media/:id/file` → Radarr delete → same cascade.
4. **Seerr** `DELETE /api/v1/request/:id` **through seerr-gateway** → movie/title purge or TV season-scoped purge + request gone (checks `X-Assemblrr-Request-Delete-Purge`).
5. **Jellyfin** `DELETE /Items/:id` → filesystem delete → `media-purge-watch` → full purge.
6. Asserts Radarr row, `media/`, `torrents/`, and qB torrent are all gone (other titles untouched).

Offline unit for the gateway (no Docker stack): `./tests/unit/test_seerr_gateway.sh` or `python3 scripts/seerr-gateway.py --self-test`.

See also: `docs/seerr-delete-request.md` (behavior + how to retire when Seerr does this natively).

Optional env: `API_HOST`, `QBIT_HOST` (defaults `127.0.0.1` / `127.0.0.1:8081`).
