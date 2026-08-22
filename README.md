# assemblrr

> **Self-hosted media automation, set up in minutes — not a weekend.**

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Linux%20%7C%20WSL2-orange.svg)](#installation)
[![Stack](https://img.shields.io/badge/Stack-Jellyfin%20%2B%20*arr-green.svg)](#the-stack)
[![Discussions](https://img.shields.io/github/discussions/soulis-1256/assemblrr)](https://github.com/soulis-1256/assemblrr/discussions)

assemblrr is an automated setup and management suite for self-hosted media stacks. It provisions, wires, and maintains a complete ecosystem (media server, torrent client, indexers, request management, subtitles, and quality profiles) with zero manual work.

[Features](#features) • [The Stack](#the-stack) • [Installation](#installation) • [CLI Usage](#cli-usage) • [Default Ports](#service-ports) • [Documentation](#documentation) • [Development](#development)

---

## Features

- **Guided Multi-Platform Setup:** Interactive installer for bare-metal Linux and Windows (via automated WSL2 bridging).
- **Automated Service Wiring:** Auto-configures and interconnects Radarr, Sonarr, Prowlarr, qBittorrent, Bazarr, Seerr, Recyclarr, and Jellyfin out of the box.
- **VPN-First Networking:** Built-in Gluetun integration routes download traffic through your VPN, complete with start-up validation and a stalled-routing watchdog.
- **Unified Operator CLI:** Manage the stack (`start`, `stop`, `restart`, `status`), change settings, take backups, and run updates directly from your terminal.
- **Hardlink-Optimized Storage:** Atomic moves and hardlink-friendly directory layout with automated TRaSH Guides quality profile sync via Recyclarr.
- **Granular Media Purge:** Single-command cleanup (`assemblrr purge`) that cleanly removes titles across *arr apps, the disk, and matching torrents simultaneously.

---

## The Stack

assemblrr provides an officially supported, fully-automated **express stack**:

| Service | Category | Default Port | Description |
|---|---|---|---|
| **[Jellyfin](https://jellyfin.org/)** | Media Server | `8096` | Open-source media streaming platform |
| **[qBittorrent](https://www.qbittorrent.org/)** | Download Client | `8081` | Torrent client isolated behind VPN (or direct access) |
| **[Sonarr](https://sonarr.tv/)** | TV Management | `8989` | Smart PVR & series download automation |
| **[Radarr](https://radarr.video/)** | Movie Management | `7878` | Movie collection manager and automation |
| **[Prowlarr](https://prowlarr.com/)** | Indexer Sync | `9696` | Centralized indexer proxy syncing to *arr apps |
| **[Seerr](https://github.com/seerr-team/seerr)** | Request Management | `5055` | Media discovery and user request gateway |
| **[Bazarr](https://www.bazarr.media/)** | Subtitles | `6767` | Automatic subtitle downloader for Sonarr and Radarr |
| **[Recyclarr](https://recyclarr.dev/)** | Quality Profiles | — | Syncs recommended TRaSH Guides quality profiles & custom formats |
| **[Gluetun](https://github.com/qdm12/gluetun)** *(Optional)* | VPN & Killswitch | — | Secure VPN tunnel with health watchdog for download traffic |

> [!TIP]
> **Custom & Extended Services:** You can easily add custom containers (e.g. Plex, Emby, SABnzbd, Portainer) via `compose/custom.yaml` or optional compose profiles. Official automated wiring and CLI maintenance workflows target the core stack above.

---

## Installation

### Linux / WSL2

Run the one-line bootstrap installer in your terminal (requires `bash` and `curl`):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/soulis-1256/assemblrr/main/platform/linux/bootstrap.sh)
```

### Windows (PowerShell)

Ensure Docker Desktop is running, then launch PowerShell as Administrator and run:

```powershell
irm https://raw.githubusercontent.com/soulis-1256/assemblrr/main/platform/windows/bootstrap.ps1 | iex
```

> [!NOTE]
> The Windows installer automatically bridges the stack into your default WSL2 Linux distribution.

### Advanced Options

#### Fish Shell

```fish
bash (curl -fsSL https://raw.githubusercontent.com/soulis-1256/assemblrr/main/platform/linux/bootstrap.sh | psub)
```

#### Custom Branch or Tag

**Linux / WSL2:**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/soulis-1256/assemblrr/main/platform/linux/bootstrap.sh) --ref dev
# or:
ASSEMBLRR_REF=dev bash <(curl -fsSL https://raw.githubusercontent.com/soulis-1256/assemblrr/main/platform/linux/bootstrap.sh)
```

**Windows (PowerShell):**
```powershell
$env:ASSEMBLRR_REF = "dev"; irm https://raw.githubusercontent.com/soulis-1256/assemblrr/main/platform/windows/bootstrap.ps1 | iex
```

> [!IMPORTANT]
> **Already installed?** Use `assemblrr upgrade` to update or `assemblrr uninstall` to remove. Do not re-run the bootstrap script on an existing installation.

---

## CLI Usage

Once installed, the `assemblrr` command-line interface is available on your system `PATH`:

```bash
assemblrr <command> [options]
```

### Stack Control

| Command | Description |
|---|---|
| `assemblrr start [service]` | Start all services (or a specific service) with VPN verification |
| `assemblrr stop [service]` | Stop all running services (or a specific service) |
| `assemblrr restart [service]` | Restart all services (or a specific service) |
| `assemblrr destroy [service]` | Teardown and reset container state |

### Status & Inspection

| Command | Description |
|---|---|
| `assemblrr status` | Operator dashboard displaying service states, health, and access URLs |
| `assemblrr status --docker` | Raw `docker compose ps` output |
| `assemblrr health` | Compact health check pass/fail summary for all containers |
| `assemblrr logs [service]` | Tail and follow logs for all containers or a specific service |
| `assemblrr check-vpn` | Verify VPN connectivity, assigned IP, and tunnel health |

### Configuration & Wiring

| Command | Description |
|---|---|
| `assemblrr config` | List all available configuration options |
| `assemblrr config show` | Display active environment configuration |
| `assemblrr config edit` | Interactive wizard to update settings (VPN, indexers, credentials, etc.) |
| `assemblrr config apply` | Re-run automated service wiring (alias: `config wire`) |

### Maintenance, Backups & Cleanup

| Command | Description |
|---|---|
| `assemblrr backup <path>` | Create a timestamped configuration backup archive |
| `assemblrr restore <file.tar.gz>` | Restore configuration from a backup archive |
| `assemblrr update-containers` | Pull the latest Docker images and restart the stack (prompts for backup first) |
| `assemblrr upgrade` | Upgrade assemblrr core scripts, apply migrations, and update wiring |
| `assemblrr upgrade --check` | Dry-run: preview upcoming file changes and migrations |
| `assemblrr upgrade --skip-stack`| Apply CLI and script updates without restarting running containers |
| `assemblrr purge` | Delete a title across Sonarr/Radarr, filesystem, and active qBittorrent torrents |
| `assemblrr uninstall` | Cleanly remove the entire stack (preserves media unless `--media` is passed) |

---

## Service Ports

When running the default stack, the following ports are mapped on `http://localhost:<PORT>`:

| Service | Port | Default URL | Purpose |
|---|---|---|---|
| **Jellyfin** | `8096` | `http://localhost:8096` | Media streaming frontend |
| **qBittorrent** | `8081` | `http://localhost:8081` | Torrent Web UI |
| **Sonarr** | `8989` | `http://localhost:8989` | TV show manager |
| **Radarr** | `7878` | `http://localhost:7878` | Movie collection manager |
| **Prowlarr** | `9696` | `http://localhost:9696` | Indexer management |
| **Seerr** | `5055` | `http://localhost:5055` | Media request portal (via gateway) |
| **Bazarr** | `6767` | `http://localhost:6767` | Subtitle manager |

---

## Configuration & Layout

Configuration and persistent state live in your installation directory (default: `~/assemblrr`):

```text
~/assemblrr/
├── .env                  # Environment variables generated during setup (see .env.example)
├── secrets/              # Authenticated credentials and VPN keys (kept separate from .env)
├── compose/
│   ├── base.yaml         # Core service definitions
│   ├── vpn.yaml          # VPN network overlay (Gluetun)
│   ├── direct-access.yaml# Direct networking overlay (non-VPN)
│   └── custom.yaml       # User-defined custom services
├── config/               # Persistent database and appdata for all services
└── scripts/              # Internal watchdog and gateway sidecar scripts
```

---

## Documentation

- **[TRaSH Guides & Quality Profiles](docs/trash-guides.md):** Quality profile synchronization and custom format handling.
- **[Seerr Delete Request](docs/seerr-delete-request.md):** In-flight download cancellation workflow and gateway architecture.
- **[Uninstall Guide](docs/uninstall.md):** Complete removal walkthrough and resource inventory.
- **[API Reference](docs/api-reference.md):** Upstream API endpoints and integration notes.

---

## Development

### Setting Up a Development Environment

**Linux / WSL2:**
```bash
git clone https://github.com/soulis-1256/assemblrr.git
cd assemblrr
bash bin/setup.sh
```

**Windows (PowerShell):**
```powershell
git clone https://github.com/soulis-1256/assemblrr.git
cd assemblrr
.\platform\windows\bootstrap-dev.ps1 -Full        # Full setup (copies files to WSL2 and runs setup.sh)
.\platform\windows\bootstrap-dev.ps1 -Full -Clean # Clean install (uninstalls previous setup first)
.\platform\windows\bootstrap-dev.ps1 -Update      # Fast sync for local script/CLI edits
```

### Running Tests

```bash
make test                 # Run all unit tests, compose validation, and shellcheck
make test-unit            # Pure shell unit tests (no Docker required)
make test-compose         # Docker Compose syntax and configuration validation
make test-integration     # Live integration tests (requires ASSEMBLRR_ALLOW_LIVE_TEST=1)
make lint                 # Run shellcheck on all scripts
```

See [tests/README.md](tests/README.md) for testing guidelines and environment flags.

---

## Community & Legal

assemblrr is infrastructure automation tooling designed to wire together and manage self-hosted applications. It does not provide, index, host, or distribute media content. Users are solely responsible for complying with applicable laws and licensing regulations in their jurisdiction.

Join discussions, request features, and connect with the community on **[GitHub Discussions](https://github.com/soulis-1256/assemblrr/discussions)**.

---

## Acknowledgments & License

- Originally inspired by [YAMS](https://yams.media/) ([rogsme/yams](https://github.com/rogsme/yams)); assemblrr has since been completely re-architected and expanded into an independent platform.
- Licensed under the **[GNU General Public License v3.0](LICENSE)**.
