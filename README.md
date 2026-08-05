# assemblrr

> [!NOTE]
> **Developer’s note — vision & roadmap**  
> Assemblrr is infrastructure for self-hosted media *automation* (install, wire services, operate the stack). It does **not** provide media, indexers, or content. What you request, download, and host is entirely your responsibility and must comply with the laws that apply to you.
>
> Future directions and ideas shall be discussed with the community **[here](https://github.com/soulis-1256/assemblrr/discussions/1)**

A lightweight media server stack via Docker. Cross-platform, VPN-aware, and built with failsafe shell scripting.

## Features & Philosophy

- **100% Docker Native:** No messy host installations. Uses native Docker Compose overlays instead of finicky sed replacements.
- **Built for Stability:** Bash scripts enforce strict safety (set -euo pipefail), active dependency checking, and shared VPN orchestration loops.
- **Fail-Safe Backups:** Built-in CLI backup & restore features snapshot your configuration before merging to prevent data corruption.
- **Secure Networking:** First-class Gluetun VPN integration. All traffic from download clients strictly routes through the VPN context.

## The Stack

### Core (included, auto-configured)
- **Media Server:** Jellyfin (recommended), Emby, or Plex
- **Download Client:** qBittorrent
- **Managers:** Sonarr, Radarr
- **Indexing:** Prowlarr
- **Request Management:** Seerr
- **Quality Profiles:** Recyclarr
- **Management:** Portainer

### Optional (via `compose/custom.yaml`)
- **Music Manager:** Lidarr
- **Usenet Downloader:** SABnzbd
- **Subtitles:** Bazarr
- **Update Notifications:** Watchtower

Deployed only — not auto-configured. Set them up in each service’s UI.

## Installation

### Linux / WSL2

bash / zsh:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/soulis-1256/assemblrr/main/platform/linux/bootstrap.sh)
```

fish (no `<(...)` process substitution — use `psub` instead):

```fish
bash (curl -fsSL https://raw.githubusercontent.com/soulis-1256/assemblrr/main/platform/linux/bootstrap.sh | psub)
```

### Windows (PowerShell)

Ensure Docker Desktop is running before execution.

```powershell
irm https://raw.githubusercontent.com/soulis-1256/assemblrr/main/platform/windows/bootstrap.ps1 | iex
```

## Usage (CLI)

After install, the CLI is on your `PATH` as `assemblrr`. Run `assemblrr <command>`:

| Command | Description |
|---|---|
| `start` | Start all services (with VPN verification) |
| `stop` | Stop all services |
| `restart` | Restart all services |
| `status` | Show container status |
| `health` | Show healthcheck status of all services |
| `logs [service]` | Follow logs (all services, or one) |
| `config` | Show current configuration |
| `configure` | Auto-configure APIs (Radarr, Prowlarr) using jq |
| `reconfigure` | Re-run the setup wizard |
| `backup /target/dir` | Snapshot configuration |
| `restore /backup.tar.gz` | Restore from a backup archive |
| `update-containers` | Pull latest images and restart (offers a backup first) |
| `update-cli` | Update the CLI to the latest version |
| `check-vpn` | Poll VPN health |
| `uninstall` | Remove everything (asks before deleting data) |

## Uninstall

`assemblrr uninstall` stops and removes the containers, network, CLI, and installation directory. Your media is kept unless you explicitly delete it. If the CLI is missing or the installation is broken, you can still run the bundled CLI directly (`bash ~/assemblrr/cli.sh uninstall`) or remove everything by hand.

See [docs/uninstall.md](docs/uninstall.md) for the complete removal guide, including a full inventory of what an installation creates.

## Configuration & Architecture

Configuration lives in your installation directory (default: `~/assemblrr`).

- `.env`: Generated at install from [`.env.example`](.env.example) (all variables are documented there). Credentials live under `secrets/`, not in `.env`.
- `compose/base.yaml`: Core services.
- `compose/vpn.yaml` / `compose/direct-access.yaml`: Networking overlays.
- `compose/custom.yaml`: Optional services (from the example under `compose/examples/`).
- `config/`: Persistent service data.

## Development

### Windows (powershell)

```powershell
git clone https://github.com/soulis-1256/assemblrr.git
cd assemblrr
.\platform\windows\bootstrap-dev.ps1 -Full        # Full setup (copies files to WSL2 and runs setup.sh)
.\platform\windows\bootstrap-dev.ps1 -Full -Clean # Uninstalls the existing installation, then does a full setup
.\platform\windows\bootstrap-dev.ps1 -Update      # Sync changed files to WSL2 (no setup re-run, useful for cli changes)
```

### Linux/WSL2

```bash
git clone https://github.com/soulis-1256/assemblrr.git
cd assemblrr
bash bin/setup.sh
```

### Tests

```bash
make test                 # unit + compose config + shellcheck (if installed)
make test-unit            # pure shell unit tests (no Docker)
make test-compose         # docker compose config validation
make test-integration     # live qBittorrent + vpn-watchdog (opt-in)
```

Live integration mutates a running stack — requires `ASSEMBLRR_ALLOW_LIVE_TEST=1`. See [tests/README.md](tests/README.md).

## Acknowledgments

Originally inspired by [YAMS](https://yams.media/) ([rogsme/yams](https://github.com/rogsme/yams)); Assemblrr has since been rewritten and expanded into its own project.

### License
GNU General Public License v3.0
