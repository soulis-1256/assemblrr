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

## Usage (Assemblrr CLI)

The `assemblrr` command is injected into your path locally to orchestrate the Docker containers seamlessly.

```bash
assemblrr start                # Start all services (with VPN verification)
assemblrr stop                 # Stop all services
assemblrr restart              # Restart all services
assemblrr status               # Show container status
assemblrr health               # Show healthcheck status of all services
assemblrr logs [service]       # Follow logs (all services, or one)
assemblrr config               # Show current configuration
assemblrr configure            # Auto-configure APIs (Radarr, Prowlarr) using jq
assemblrr reconfigure          # Re-run the setup wizard
assemblrr backup /target/dir   # Create a safe snapshot of the configuration
assemblrr restore /backup.tar.gz  # Non-destructive config wipe and restore
assemblrr update-containers    # Pull latest images and restart (offers a backup first)
assemblrr update-cli           # Update the CLI to the latest version
assemblrr check-vpn            # Actively poll VPN health
assemblrr uninstall            # Remove everything (asks before deleting data)
```

## Uninstall

`assemblrr uninstall` stops and removes the containers, network, CLI, and installation directory. Your media is kept unless you explicitly delete it. If the CLI is missing or the installation is broken, you can still run the bundled CLI directly (`bash ~/assemblrr/cli.sh uninstall`) or remove everything by hand.

See [docs/uninstall.md](docs/uninstall.md) for the complete removal guide, including a full inventory of what an installation creates.

## Configuration & Architecture

Configuration lives in your installation directory (default: `~/assemblrr`).

- `.env`: Environment overrides (ASSEMBLRR_HOST for remote proxying, PUID/PGID, API variables).
- `compose/base.yaml`: Immutable core services.
- `compose/vpn.yaml`: Gluetun routing overlays.
- `config/`: Persistent data safe from container teardowns.

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

## Acknowledgments

Originally inspired by [YAMS](https://yams.media/) ([rogsme/yams](https://github.com/rogsme/yams)); Assemblrr has since been rewritten and expanded into its own project.

### License
GNU General Public License v3.0
