# Seerr “Delete request” → full media purge

assemblrr product intent: when a user deletes a Seerr **request**, the stack
should also remove the title from Radarr/Sonarr, library files under `media/`,
and the qBittorrent torrent/data under `torrents/` (hardlink-aware).

Stock Seerr does **not** do that. `DELETE /api/v1/request/:id` only removes the
request row. The path that frees library files is
`DELETE /api/v1/media/:id/file` (Seerr calls *arr with `deleteFiles: true`).

## What assemblrr does

A thin reverse proxy, **`seerr-gateway`**, publishes host port **5055**. Seerr
listens only on the Docker network. Almost all traffic is proxied unchanged.

On **`DELETE /api/v1/request/:id`** only (when purge is enabled):

1. `GET /api/v1/request/:id` — capture linked `media.id` and `is4k` (same auth headers as the client)
2. `DELETE /api/v1/media/:mediaId/file?is4k=…` — Seerr → *arr delete with files → assemblrr purge hooks (qB)
3. `DELETE /api/v1/request/:id` — drop the request row (response returned to the client)

If media was never linked, step 2 is skipped; the request is still deleted.
Auth failures on step 1 are returned to the client with no deletes.

| Piece | Role |
|-------|------|
| `scripts/seerr-gateway.py` | Reverse proxy + request-delete intercept |
| `compose/base.yaml` → `seerr-gateway` | Publishes 5055; `seerr` is internal only |
| `scripts/arr-purge-hook.sh` / `media-purge.sh` | qB + disk cleanup after *arr delete |

Env:

| Variable | Default | Meaning |
|----------|---------|---------|
| `SEERR_DELETE_REQUEST_PURGE` | `1` | `1` = intercept delete-request; `0`/`false`/`off` = pure passthrough (stock Seerr) |
| `SEERR_UPSTREAM` | `http://seerr:5055` | Upstream Seerr (container) |

Debug response headers on intercepted deletes:

- `X-Assemblrr-Request-Delete-Purge: 1`
- `X-Assemblrr-Purge-Detail: …` (e.g. `media_file_deleted:7:204`, `no_media`)

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
# Offline unit (mock Seerr):
python3 scripts/seerr-gateway.py --self-test
# or
./tests/unit/test_seerr_gateway.sh

# Live (opt-in; real install):
ASSEMBLRR_ALLOW_LIVE_TEST=1 ./tests/integration/media_purge_e2e.sh
```

The live suite includes **delete request through the gateway** → full cascade,
and documents that stock Seerr request-delete alone does not wipe files.
