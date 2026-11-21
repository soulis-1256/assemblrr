# Changelog

## [Unreleased] — Stack Revival & Modular Hardening

### Added
- **Five opt-in service overlays** (`compose/*.yaml`, selectable during manual setup or `assemblrr config edit`):
  - `vuetorrent.yaml`: VueTorrent (`v2.37.0`) WebUI mod for qBittorrent (`QBIT_UI=vuetorrent`, `VUETORRENT_ENABLED=y`).
  - `qui.yaml`: qui (`v1.36.0`) standalone qBittorrent WebUI on `:7476` with automatic `:8081` redirect and shared stack credentials (`QBIT_UI=qui`).
  - `gpu-intel.yaml` / `gpu-nvidia.yaml`: Intel/AMD VAAPI (`/dev/dri`) and NVIDIA NVENC hardware transcoding for Jellyfin (`GPU_TRANSCODING=amd|intel|nvidia`) with live `vainfo` codec probing.
  - `byparr.yaml`: Byparr (`3.1.1`) headless-browser HTTP solver proxy wired as a Prowlarr `FlareSolverr` proxy tagged `byparr` (`BYPARR_ENABLED=y`), with automatic tagging and re-enabling of disabled indexers.
  - `usenet.yaml`: SABnzbd (`5.1.3`) Usenet downloader wired automatically into Sonarr, Radarr, and Prowlarr via `lib/usenet.sh` (`USENET_ENABLED=y`).
- **Interactive `assemblrr config edit` & `assemblrr status` operator dashboard**: live `[active]` status badges across every section/submenu, `Esc`-to-previous-menu navigation with zero scrollback stacking, no-op restart skip when settings are unchanged, and unified service readiness & URL table.
- **Resilient torrent & watchdog automation**: persistent qBittorrent session cookie reuse in `vpn-watchdog`, 1000-session / 30-day WebUI session limits, automatic repair of zero-width obfuscated tracker URLs, and 3-minute automatic failover for 0%-progress 0-seed grabs in Radarr/Sonarr.
- **Offline Usenet CI test harness**: `tests/fixtures/mock_nntp.py`, `tests/fixtures/mock_newznab.py`, and `tests/integration/usenet_mock_e2e.sh` (zero paid subscriptions required).
- **Komodo deployment documentation**: `docs/komodo.md`.
- **Legal & community docs**: `NOTICE`, `SECURITY.md`, `CONTRIBUTING.md`, `CHANGELOG.md`, SPDX license headers across scripts.
- **GitHub Actions CI**: `.github/workflows/ci.yml` (`bash -n`, `shellcheck`, `py_compile`, unit & compose validation).
- **Migration 004** (`migrations/004_jellyfin_12_and_stack_revival.sh`): prepares `config/sabnzbd`, backfills new feature flags, and prints upgrade notes for Jellyfin 12.4.

### Changed
- **Upgraded core container image pins**:
  - Jellyfin `10.11.11` -> `12.4ubu2604-ls60` (removed `--profile jellyfin` gate; migrated API auth headers from legacy `X-Emby-Token` to `Authorization: MediaBrowser`).
  - qBittorrent `5.2.3` -> `5.3.0`
  - Sonarr `4.0.19.2979-ls321` -> `4.0.20.3014-ls6`
  - Radarr `6.3.0.10514-ls313` -> `7.0.3.10918-ls328`
  - Prowlarr `2.5.2.5491-ls156` -> `3.0.2.5780-ls169`
  - Bazarr `1.6.0` -> `1.6.2`
  - Seerr `v3.4.1` -> `v3.5.2`
  - Recyclarr `8.7.1` -> `8.8.1`
  - Deunhealth pinned by immutable SHA-256 digest; Gateway Python bumped to `3.12.16-alpine`; sidecar base images bumped to `alpine:3.24.4`.
- **Core architecture modularized**:
  - Split `lib/core.sh` into `log.sh`, `tty.sh`, `paths.sh`, `fs.sh`, `docker.sh`, `languages.sh` (keeping `lib/core.sh` as a backward-compatible facade).
  - Split `lib/arr.sh` into `qbit.sh`, `arr_common.sh`, `arr_quality.sh`, `prowlarr.sh`, `arr_import.sh`, and extracted `lib/recyclarr.sh` (keeping `lib/arr.sh` as a facade).
  - Removed broken Emby/Plex stubs from `compose/base.yaml` and core setup (moved reference examples into `compose/examples/custom.yaml.example` with non-colliding `.30+` IPs).
  - Standardized multi-select `fzf` TUI controls (`Tab=toggle`, `Enter=confirm`), added `--preview` for Prowlarr indexers, and added version compatibility checks for older `fzf` releases (`0.29+`).
- **Upgrade engine**: added atomic pre-apply staging & rollback on Compose validation failure, self-re-exec after copying managed files, `.assemblrr-channel` persistence, and migration function isolation (`unset -f` before `source`).

### Security & Bug Fixes
- **P0 — `scripts/seerr-gateway.py`**: fixed confused-deputy authorization bypass by verifying caller permissions via `GET /api/v1/auth/me` before invoking Radarr/Sonarr deletions; refused upstream 5xx fail-open behavior; added `GatewayConfig` DI and body size cap; extracted mock tests out of production script into `tests/unit/test_seerr_gateway_suite.py`.
- **P0 — `lib/config_edit.sh`**: fixed `_config_edit_all` missing `--reconfigure`, non-`fzf` picker menu output corrupting stdout capture, and quote escaping / `0600` permission preservation in `config_set_kv`.
- **P0 — `scripts/media-purge.sh`**: fixed `--tmdb`/`--tvdb` re-exec dropping `--dry-run`/`--qb-only`, tightened `qb_match_season_jq` lookahead boundaries so audio codecs (`DTS5.1`) no longer trigger bogus seasons, switched to `Authorization: MediaBrowser` + `/ScheduledTasks` check, and added SABnzbd cleanup support.
- **P1 — `lib/paths.sh`, `lib/bazarr.sh`, `lib/prompts.sh`**: removed unsafe `eval`/`source` in `safe_source`, fixed `curl -F` injection risk via `--form-string`, removed borrowed OpenSubtitles API key, fixed Gluetun VPN slugs (`private internet access`, `ivpn`), and replaced Windows `wmic` with PowerShell `Get-PSDrive`.
- **P1 — Sidecars (`vpn-watchdog.sh`, `media-purge-watch.sh`, `jellyfin-refresh.sh`)**: added restart cooldown & active-swarm guard in `vpn-watchdog.sh`, upgrade-history recency window & whole-TV-show Sonarr hold checks in `media-purge-watch.sh`, and atomic lock reclamation in `jellyfin-refresh.sh`.
