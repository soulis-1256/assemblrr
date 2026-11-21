# Running assemblrr with Komodo

[Komodo](https://komo.do/) can deploy and monitor assemblrr's Compose stack once `setup` (or a manual `.env` + `secrets/` setup) has initialized the install directory.

## How Compose Overlays Fit Komodo

assemblrr keeps its stack modular under `compose/`:

- **Always required:** `compose/base.yaml` + **one** network mode (`compose/vpn.yaml` or `compose/direct-access.yaml`)
- **Optional feature overlays:**
  - `compose/vuetorrent.yaml` (`VUETORRENT_ENABLED=y`)
  - `compose/gpu-intel.yaml` (`GPU_TRANSCODING=intel`) or `compose/gpu-nvidia.yaml` (`GPU_TRANSCODING=nvidia`)
  - `compose/byparr.yaml` (`BYPARR_ENABLED=y`)
  - `compose/usenet.yaml` (`USENET_ENABLED=y`)
- **Custom services:** `compose/custom.yaml` (always appended last; see [`compose/examples/custom.yaml.example`](../compose/examples/custom.yaml.example) for a `komodo-periphery` service block on `.33`)

## Recommended Komodo Stack Configuration

1. Run `assemblrr` setup (or `restore`) once on the target host so `.env`, `secrets/`, `config/`, and `scripts/` exist with proper `PUID`/`PGID` permissions.
2. Point a **Komodo Stack** at your install directory (e.g. `~/assemblrr`) with **File Paths** matching your enabled overlays, in order:
   ```text
   compose/base.yaml
   compose/vpn.yaml
   compose/vuetorrent.yaml
   compose/gpu-intel.yaml
   compose/byparr.yaml
   compose/usenet.yaml
   compose/custom.yaml
   ```
   *(Omit any overlay you did not enable, or replace `compose/vpn.yaml` with `compose/direct-access.yaml`.)*
3. Configure **Env File Path**: `.env` (or paste generated `.env` values into Komodo's environment editor without duplicating secret files from `secrets/`).
4. Keep **Project Directory** set to the install root (`INSTALL_DIRECTORY`) so relative secret and config paths resolve correctly.

## Upgrades & Re-wiring

- Use `assemblrr upgrade --skip-stack` (from CLI) if you let Komodo handle `docker compose up -d --build`, or run `assemblrr upgrade` normally and let Komodo re-sync state.
- Whenever you add a service or change API credentials, run `assemblrr config apply` to re-run idempotent `*arr` / Jellyfin / Bazarr / Seerr / SABnzbd wiring.
