# Seerr “Delete request” → media purge

assemblrr product intent: when an authorized user deletes a Seerr **request**, the stack
should also remove **that request’s** library files under `media/` and the matching download
items under `torrents/` / `usenet/` (hardlink-aware).

- **Movies:** the whole title.
- **TV:** only the seasons on that request. Other seasons of the same show stay,
  including **specials** (season 0) unless that request listed them.

Stock Seerr does **not** do that. `DELETE /api/v1/request/:id` only removes the
request row. The path that frees an entire title is
`DELETE /api/v1/media/:id/file` (Seerr calls *arr with `deleteFiles: true`).
That API is **title-scoped**. It cannot delete one season.

## What assemblrr does

A thin reverse proxy, **`seerr-gateway`**, publishes host port **5055**. Seerr
listens only on the Docker network. Almost all traffic is proxied unchanged.

On **`DELETE /api/v1/request/:id`** only (when purge is enabled):

1. `GET /api/v1/auth/me` — verify caller identity & Seerr permissions (`ADMIN` or `MANAGE_REQUESTS`)
   before invoking any privileged `*arr` APIs (prevents confused-deputy deletion). Non-admin users
   cancelling their own **pending** request pass straight through to Seerr `DELETE` without touching
   downloaded files; unauthorized attempts fail closed (`401`/`403`).
2. `GET /api/v1/request/:id` — capture linked `media.id`, `is4k`, type, and
   requested season numbers (fails closed with `502` on upstream 5xx).
3. **Drain the *arr download queue first** (while the title still exists):
   `DELETE /api/v3/queue/{id}?removeFromClient=true`.
4. Purge files:
   - **Movie**, or a TV request that covers every remaining on-disk/monitored
     season (specials count as remaining) → `DELETE /api/v1/media/:mediaId/file?is4k=…`
     (Seerr → *arr `deleteFiles` → assemblrr purge hooks / qB / SABnzbd).
   - **TV subset of seasons** → Sonarr `DELETE /episodefile/{id}` for those
     seasons only, then unmonitor them. Seerr title-level file-delete is
     **not** called, so `/data/media/tv/Show` is not wiped. `media-purge-watch`
     then season-scopes download cleanup when that season folder empties.
5. `DELETE /api/v1/request/:id` — drop the request row and return the response.

| Piece | Role |
|------|------|
| `scripts/seerr-gateway.py` | Authenticating reverse proxy + request-delete intercept |
| `compose/base.yaml` → `seerr-gateway` | Publishes 5055; `seerr` is internal only; reads Sonarr/Radarr API keys |
| `scripts/arr-purge-hook.sh` / `media-purge.sh` | qB + SABnzbd + disk cleanup; `--seasons` for partial TV |
| `scripts/media-purge-watch.sh` | inotify: empty season folder → `--seasons` purge; movie / series-root delete → title purge |

### Purge safety (`media-purge.sh`)

`media-purge.sh` prefers under-delete over collateral damage:

1. *arr **queue + history** download IDs/hashes that still exist in qBittorrent or SABnzbd (`SABnzbd_nzo_*`).
2. Title + year match on release name / content path. `(2016)` and `2016` are
   the same year; indexer domain prefixes (`indexer.example - …`) are allowed; the
   token after the title must be that year so `Alpha Film Sequel Extended (2022)`
   or `Nova Comes at Night 2017` stay untouched for `Alpha Film (2016)` or `Nova (2017)`.
3. Refuse ambiguous multi-matches on the name step. Short keys (`Oz`) skipped.
4. **Season purge:** torrent must name one of the requested seasons (`S01` /
   `Season 1` / `Specials`) with strict token boundaries (ignoring codecs like `DTS5.1` or `x265`)
   and must **not** also name another season. Packs like `Sample.Show.S01.S02.COMPLETE`
   and ranges like `Sample.Show.S01-03` are left alone when deleting S01 only.

See `tests/unit/test_media_purge_match.sh`.

Env:

| Variable | Default | Meaning |
|----------|---------|---------|
| `SEERR_DELETE_REQUEST_PURGE` | `1` | `1` = intercept delete-request; `0`/`false`/`off` = pure passthrough (stock Seerr) |
| `MEDIA_PURGE_WATCH` | `1` | `1` = inotify watcher on library video deletes; `0` = disable watcher only |
| `SEERR_UPSTREAM` | `http://seerr:5055` | Upstream Seerr (container) |
| `SONARR_URL` | `http://sonarr:8989` | Used by the gateway for TV season deletes + queue drain |
| `RADARR_URL` | `http://radarr:7878` | Used by the gateway to drain in-progress movie grabs |

## When Seerr adds this natively

If a future Seerr release natively deletes media on request delete, set `SEERR_DELETE_REQUEST_PURGE=0`
or remove `seerr-gateway` from `compose/base.yaml` and publish `5055:5055` directly on `seerr`.

## Tests

```bash
# Offline gateway unit suite (mock Seerr + Sonarr + Radarr):
python3 -m unittest tests/unit/test_seerr_gateway_suite.py -v
# or
./tests/unit/test_seerr_gateway.sh

# qB season matcher + watch helpers:
./tests/unit/test_media_purge_match.sh
./tests/unit/test_media_purge_watch.sh

# Live (opt-in; real install):
ASSEMBLRR_ALLOW_LIVE_TEST=1 ./tests/integration/media_purge_e2e.sh
```
