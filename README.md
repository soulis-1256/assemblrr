# assemblrr

> **Self-hosted media automation, set up in minutes — not a weekend.**

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Linux%20%7C%20WSL2-orange.svg)](#installation)
[![Stack](https://img.shields.io/badge/Stack-Jellyfin%2012.4%20%2B%20*arr-green.svg)](#the-stack)
[![Discussions](https://img.shields.io/github/discussions/soulis-1256/assemblrr)](https://github.com/soulis-1256/assemblrr/discussions)

assemblrr is an automated setup and management suite for self-hosted media stacks. It provisions, wires, and maintains a complete ecosystem (media server, download clients, indexers, request portal, subtitles, quality profiles, and optional overlays) with minimal friction.

[Features](#features) • [The Stack](#the-stack) • [Optional Overlays](#optional-overlays) • [Installation](#installation) • [CLI Usage](#cli-usage) • [Service Ports](#service-ports) • [Documentation](#documentation) • [Development](#development)

---

## Features

- **Guided Multi-Platform Setup:** Interactive installer for bare-metal Linux and Windows (via automated WSL2 bridging), with Express, Manual, Reconfigure (`--reconfigure`), and Restore modes.
- **Automated Service Wiring:** Auto-configures and interconnects Radarr, Sonarr, Prowlarr, qBittorrent, Bazarr, Seerr, Recyclarr, and Jellyfin (`12.4+` with `Authorization: MediaBrowser` auth) — plus optional SABnzbd and Byparr.
- **VPN-First Networking:** Built-in Gluetun integration routes torrent traffic through your VPN with start-up validation and a cooldown-guarded routing watchdog (`vpn-watchdog`).
- **Unified Operator CLI:** Manage the stack (`start`, `stop`, `restart`, `status`, `health`, `config edit`, `config apply`, `upgrade`, `backup`, `restore`, `purge`, `uninstall`) from your terminal.
- **Safe Rollback Upgrades:** `assemblrr upgrade` backs up managed files, applies atomic staged updates + migrations, validates resolved Docker Compose config before stamping, and rolls back automatically if validation fails.
- **Hardlink-Optimized Storage:** Atomic moves and hardlink-friendly layout across `/data/torrents`, `/data/usenet`, and `/data/media`, plus TRaSH Guides profile sync via Recyclarr.
- **Authenticated Request-Delete Gateway:** `seerr-gateway` verifies caller permissions (`GET /api/v1/auth/me`) before draining in-flight downloads and cleaning library/season files safely.

---

## The Stack

assemblrr provides an officially supported core stack with pinned container versions:

| Service | Category | Default Port | Description |
|---|---|---|---|
| **[Jellyfin](https://jellyfin.org/)** (`12.4`) | Media Server | `8096` | Open-source media streaming platform |
| **[qBittorrent](https://www.qbittorrent.org/)** (`5.3.0`) | Torrent Client | `8081` | Torrent client isolated behind VPN (or direct access) |
| **[Sonarr](https://sonarr.tv/)** | TV Management | `8989` | Smart PVR & series download automation |
| **[Radarr](https://radarr.video/)** | Movie Management | `7878` | Movie collection manager and automation |
| **[Prowlarr](https://prowlarr.com/)** | Indexer Sync | `9696` | Centralized indexer manager syncing to *arr apps |
| **[Seerr](https://github.com/seerr-team/seerr)** | Request Portal | `5055` | Media discovery & requests behind authenticating `seerr-gateway` |
| **[Bazarr](https://www.bazarr.media/)** | Subtitles | `6767` | Automatic subtitle manager for Sonarr and Radarr |
| **[Recyclarr](https://recyclarr.dev/)** | Quality Profiles | — | Syncs recommended TRaSH Guides quality profiles & custom formats |
| **[Gluetun](https://github.com/qdm12/gluetun)** *(Optional)* | VPN & Killswitch | — | Secure VPN tunnel with `deunhealth` & `vpn-watchdog` |

### Optional Overlays

Enable during `Manual` setup or toggle anytime via `assemblrr config edit`:

| Overlay File | Env Key | Description |
|---|---|---|
| [`compose/vuetorrent.yaml`](compose/vuetorrent.yaml) | `QBIT_UI=vuetorrent` | Modern VueTorrent theme inside qBittorrent (:8081) *(default)* |
| [`compose/qui.yaml`](compose/qui.yaml) | `QBIT_UI=qui` | Fast Go+React standalone qBittorrent WebUI (`7476`; `:8081` redirects automatically) |
| [`compose/gpu-intel.yaml`](compose/gpu-intel.yaml) | `GPU_TRANSCODING=amd` / `intel` | AMD VAAPI / Intel QSV (`/dev/dri`) hardware transcoding + Jellyfin auto-wiring |
| [`compose/gpu-nvidia.yaml`](compose/gpu-nvidia.yaml) | `GPU_TRANSCODING=nvidia` | NVIDIA NVENC/NVDEC GPU reservation + Jellyfin auto-wiring *(auto-enabled when detected)* |
| [`compose/byparr.yaml`](compose/byparr.yaml) | `BYPARR_ENABLED=y` | Byparr headless-browser HTTP proxy wired into Prowlarr (`byparr` tag) |
| [`compose/usenet.yaml`](compose/usenet.yaml) | `USENET_ENABLED=y` | SABnzbd (`8085`) wired into Sonarr, Radarr, and Prowlarr (requires your own NNTP account) |

> [!TIP]
> Need self-managed extras (Plex, Emby, Lidarr, Komodo Periphery)? Copy [`compose/examples/custom.yaml.example`](compose/examples/custom.yaml.example) to `compose/custom.yaml`. Custom services use `.30+` IPs on `assemblrr_network` and are left untouched by upgrades.

---

## Installation

### Linux / WSL2

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/soulis-1256/assemblrr/main/platform/linux/bootstrap.sh)
```

### Windows (PowerShell)

Ensure Docker Desktop is running with WSL2 integration enabled, then run PowerShell and execute:

```powershell
irm https://raw.githubusercontent.com/soulis-1256/assemblrr/main/platform/windows/bootstrap.ps1 | iex
```

### Advanced Options

**Custom branch, tag, or commit SHA:**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/soulis-1256/assemblrr/main/platform/linux/bootstrap.sh) --ref dev
```
```powershell
$env:ASSEMBLRR_REF = "dev"; irm https://raw.githubusercontent.com/soulis-1256/assemblrr/main/platform/windows/bootstrap.ps1 | iex
```

**Restore on a clean host from backup:**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/soulis-1256/assemblrr/main/platform/linux/bootstrap.sh) --restore /path/to/assemblrr-backup.tar.gz
```

> [!IMPORTANT]
> **Already installed?** Use `assemblrr upgrade` to update, `assemblrr config edit` to change settings/overlays, or `assemblrr uninstall` to remove.

---

## CLI Usage

```bash
assemblrr <command> [options]
```

### Stack Control
| Command | Description |
|---|---|
| `assemblrr start [service]` | Start all (or named) services and wait for readiness |
| `assemblrr stop [service]` | Stop running services |
| `assemblrr restart [service]` | Restart running services |
| `assemblrr destroy [service]` | Stop and remove containers/network (keeps config & media) |

### Status & Inspection
| Command | Description |
|---|---|
| `assemblrr status` | Operator dashboard displaying service states, health, and URLs |
| `assemblrr status --docker` | Raw `docker compose ps` table |
| `assemblrr health` | Compact health pass/fail check across catalog services |
| `assemblrr logs [service]` | Tail container logs |
| `assemblrr check-vpn` | Compare host exit IP against Gluetun tunnel IP |

### Configuration & Maintenance
| Command | Description |
|---|---|
| `assemblrr config show` | Show active configuration & resolved compose overlays |
| `assemblrr config edit` | Interactive picker for VPN, quality, overlays (VueTorrent/GPU/Byparr/Usenet), auth, etc. |
| `assemblrr config apply` | Re-run non-interactive service API wiring (`alias: config wire`) |
| `assemblrr upgrade` | Upgrade managed files, apply migrations, validate & rebuild stack (`--check`, `--from DIR`, `--ref REF`, `--skip-stack`) |
| `assemblrr update-containers` | Rebuild local sidecars and pull any custom overlay images |
| `assemblrr purge ...` | Remove a movie/series/season across *arr, library disk, qBittorrent, and SABnzbd |
| `assemblrr backup <dir>` | Create a `0600` backup archive |
| `assemblrr restore <file.tar.gz>` | Validate archive and restore config/secrets |
| `assemblrr uninstall` | Clean removal (preserves media unless `--media` is passed) |

---

## Service Ports

| Service | Host Port | Default URL | Notes |
|---|---|---|---|
| **Jellyfin** | `8096` | `http://localhost:8096` | Media streaming frontend |
| **Seerr (Gateway)** | `5055` | `http://localhost:5055` | Media requests + delete-request purge |
| **Bazarr** | `6767` | `http://localhost:6767` | Subtitle manager |
| **Sonarr** | `8989` | `http://localhost:8989` | TV show manager |
| **Radarr** | `7878` | `http://localhost:7878` | Movie manager |
| **Prowlarr** | `9696` | `http://localhost:9696` | Indexer manager |
| **qBittorrent** | `8081` | `http://localhost:8081` | Torrent Web UI (VueTorrent, Stock, or auto-redirect to `qui`) |
| **qui** *(opt.)* | `7476` | `http://localhost:7476` | Standalone qBittorrent WebUI (`QBIT_UI=qui`) |
| **SABnzbd** *(opt.)* | `8085` | `http://localhost:8085` | Usenet downloader (`USENET_ENABLED=y`) |

---

## Configuration & Layout

```text
~/assemblrr/
├── .env                       # Environment variables generated by setup
├── .assemblrr-config          # Install metadata + active UI/feature settings
├── .assemblrr-channel         # Active upgrade git ref (default: main)
├── .assemblrr-version         # Recorded upgrade version stamp
├── .assemblrr-migrations      # Applied migration IDs
├── secrets/                   # 0700 dir of 0600 service passwords & VPN keys
├── compose/
│   ├── base.yaml              # Core service definitions
│   ├── vpn.yaml               # Gluetun VPN network + watchdog overlay
│   ├── direct-access.yaml     # Non-VPN overlay
│   ├── vuetorrent.yaml        # Optional VueTorrent WebUI overlay
│   ├── qui.yaml               # Optional qui standalone qBittorrent WebUI overlay
│   ├── gpu-intel.yaml         # Optional Intel/AMD VAAPI GPU overlay
│   ├── gpu-nvidia.yaml        # Optional NVIDIA NVENC GPU overlay
│   ├── byparr.yaml            # Optional Byparr HTTP solver proxy overlay
│   ├── usenet.yaml            # Optional SABnzbd Usenet overlay
│   └── custom.yaml            # User-defined custom services (untouched by upgrade)
├── config/                    # Persistent service appdata
├── migrations/                # Idempotent upgrade migrations
└── scripts/                   # Sidecar watchdog, purge & gateway hooks
```

---

## Documentation

- **[TRaSH Guides & Quality Profiles](docs/trash-guides.md):** Quality profile sync and custom format notes.
- **[Seerr Delete Request](docs/seerr-delete-request.md):** Gateway RBAC auth, queue drain, and season-scoped purge architecture.
- **[Komodo Integration](docs/komodo.md):** Running and monitoring assemblrr stacks via Komodo.
- **[API Reference](docs/api-reference.md):** Jellyfin 12 `MediaBrowser` auth headers, *arr/SABnzbd/Byparr endpoints.
- **[Uninstall Guide](docs/uninstall.md):** Complete removal walkthrough and directory inventory.
- **[Security Policy](SECURITY.md) • [Contributing](CONTRIBUTING.md) • [Changelog](CHANGELOG.md) • [Legal Notice](NOTICE)**

---

## Development

```bash
make test                 # Unit tests + compose validation + shellcheck lint
make test-unit            # Offline shell + Python unit suites
make test-compose         # Docker Compose validation across overlay matrix
make lint                 # Run shellcheck across shell scripts
```

See [tests/README.md](tests/README.md) for the test suite layout, including the offline NNTP/Newznab Usenet mock harness.

---

## Community & Legal

assemblrr is infrastructure automation tooling for self-hosted applications. It does **not** include, host, index, or distribute copyrighted media content or external subscriptions. Users are solely responsible for complying with applicable laws in their jurisdiction. See [NOTICE](NOTICE).

Join discussions on **[GitHub Discussions](https://github.com/soulis-1256/assemblrr/discussions)**.

---

## License

- Inspired in early versions by [YAMS](https://yams.media/), now independently architected and modularized.
- Licensed under the **[GNU General Public License v3.0 or later](LICENSE)**.
