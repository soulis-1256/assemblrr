# Seerr “Delete request” → media purge

assemblrr product intent: when a user deletes a Seerr **request**, the stack
should also remove **that request’s** library files under `media/` and the
matching qBittorrent torrent/data under `torrents/` (hardlink-aware).

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

1. `GET /api/v1/request/:id` — capture linked `media.id`, `is4k`, type, and
   requested season numbers (same auth headers as the client).
2. Purge files:
   - **Movie**, or a TV request that covers every remaining on-disk/monitored
     season (specials count as remaining) → `DELETE /api/v1/media/:mediaId/file?is4k=…`
     (Seerr → *arr `deleteFiles` → assemblrr purge hooks / qB).
   - **TV subset of seasons** → Sonarr `DELETE /episodefile/{id}` for those
     seasons only, then unmonitor them. Seerr title-level file-delete is
     **not** called, so `/data/media/tv/Show` is not wiped. `media-purge-watch`
     then season-scopes qB cleanup when that season folder empties.
3. `DELETE /api/v1/request/:id` — drop the request row (response returned to
   the client).

If media was never linked, step 2 is skipped; the request is still deleted.
Auth failures on step 1 are returned to the client with no deletes.
If a TV request has no season list, the Sonarr API key is missing, or a
season-scoped Sonarr call fails, the gateway returns **502** and does
**not** delete the request (it never title-deletes on uncertainty).

| Piece | Role |
|------|------|
| `scripts/seerr-gateway.py` | Reverse proxy + request-delete intercept (season-aware for TV) |
| `compose/base.yaml` → `seerr-gateway` | Publishes 5055; `seerr` is internal only; reads Sonarr API key |
| `scripts/arr-purge-hook.sh` / `media-purge.sh` | qB + disk cleanup; `--seasons` for partial TV |
| `scripts/media-purge-watch.sh` | inotify: empty season folder → `--seasons` purge (even if other seasons are only monitored/downloading); movie / series-root delete → title purge |

### Title-level delete in Seerr (not season-safe)

Seerr’s own **bulk delete / “remove from library” / delete files** on a TV
card is `DELETE /api/v1/media/:id/file`. That always removes the **entire
series** from Sonarr (`deleteFiles: true`). assemblrr does **not** intercept
that path: it means “this title”.

A recycle bin at `/data/media/.recycle` (Sonarr/Radarr, 7-day cleanup) makes a
mistaken title delete recoverable for library files. The series-delete hook
then removes the matching qB torrent **and** leftover folders under
`torrents/tv` / `torrents/movies` (Completed Download Handling often drops the
qB row first, which used to leave the download directory behind).

### Purge safety (qB)

`media-purge.sh` prefers under-delete over collateral damage:

1. *arr history download hashes that still exist in qB **and** match the library folder key (`Title (YYYY)`)
2. Exact folder-key match on torrent name / content path (no bare short-title prefix)
3. Refuse ambiguous multi-matches
4. **Season purge:** torrent must name one of the requested seasons (`S01` /
   `Season 1`) and must **not** also name another season. Packs like
   `Show.S01.S02.COMPLETE` and ranges like `Show.S01-03` are left alone
   when deleting S01 only. A torrent with no season token is left alone.
   Folder-key matching uses the same title-boundary rules as title-level
   (short keys such as `Oz` are skipped).

See `media-purge.sh --match-self-test`.

Env:

| Variable | Default | Meaning |
|----------|---------|---------|
| `SEERR_DELETE_REQUEST_PURGE` | `1` | `1` = intercept delete-request; `0`/`false`/`off` = pure passthrough (stock Seerr) |
| `MEDIA_PURGE_WATCH` | `1` | `1` = inotify watcher on library video deletes; `0` = disable watcher only |
| `SEERR_UPSTREAM` | `http://seerr:5055` | Upstream Seerr (container) |
| `SONARR_URL` | `http://sonarr:8989` | Used by the gateway for TV season deletes |
| `SONARR_CONFIG` | `/config/sonarr/config.xml` | API key source when `SONARR_API_KEY` is unset |

Debug response headers on intercepted deletes:

- `X-Assemblrr-Request-Delete-Purge: 1`
- `X-Assemblrr-Purge-Detail: …` (e.g. `media_file_deleted:7:204`,
  `seasons_deleted:6:10:1:3`, `no_media`)

Health (gateway only, not Seerr):

- `GET /_assemblrr/health` — process up
- `GET /_assemblrr/ready` — upstream Seerr public settings reachable

## Why not a Seerr fork

Forking Seerr for one product preference is ongoing merge cost. The gateway
owns only this behavior and stays a small managed script.

## When Seerr adds this natively — **must adjust**

If a future Seerr/Overseerr release deletes media (or offers a setting to) on
request delete, **this gateway intercept becomes wrong or redundant** (double
delete races, confusing semantics). Do the following:

1. **Confirm** upstream behavior in Seerr release notes / source:
   - Does `DELETE /api/v1/request/:id` call *arr with `deleteFiles`?
   - Is it always on, or a setting?
   - Is it season-scoped for TV?
2. **Short term:** set `SEERR_DELETE_REQUEST_PURGE=0` in the install `.env`
   (or compose environment) and restart `seerr-gateway`. Traffic stays on 5055;
   intercept is off. Verify once that stock delete-request still meets product
   intent with your purge hooks.
3. **Long term (preferred once native behavior is permanent and correct):**
   - Remove the `seerr-gateway` service from `compose/base.yaml`
   - Publish `5055:5055` on `seerr` again
   - Drop `scripts/seerr-gateway.py` from `lib/managed_files.sh` and the repo
   - Update this doc, `lib/services.sh` (catalog back to `seerr|Seerr|5055`),
     `docs/uninstall.md`, and live tests that assert gateway headers
   - Remove any mention of `SEERR_DELETE_REQUEST_PURGE`
4. **Do not** leave the intercept enabled “just in case” after Seerr already
   purges on request delete — that can double-call *arr delete paths.

Track ownership: this file and `scripts/seerr-gateway.py` header comment.

## Tests

```bash
# Offline unit (mock Seerr + mock Sonarr):
python3 scripts/seerr-gateway.py --self-test
# or
./tests/unit/test_seerr_gateway.sh

# qB season matcher + watch helpers:
./tests/unit/test_media_purge_match.sh
./tests/unit/test_media_purge_watch.sh

# Live (opt-in; real install):
ASSEMBLRR_ALLOW_LIVE_TEST=1 ./tests/integration/media_purge_e2e.sh
```

The live suite includes **delete request through the gateway** → full cascade
for a **movie**, and documents that stock Seerr request-delete alone does not
wipe files.
