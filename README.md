# assemblrr

> [!NOTE]
> **Developer’s note — vision & roadmap**  
> assemblrr is infrastructure for self-hosted media *automation* (install, wire services, operate the stack). It does **not** provide media, indexers, or content. What you request, download, and host is entirely your responsibility and must comply with the laws that apply to you.
>
> Future directions and ideas shall be discussed with the community **[here](https://github.com/soulis-1256/assemblrr/discussions/1)**

Self-hosted media automation, set up in minutes, not a weekend.

## Features

- **Guided Multi-Platform Install:** Interactive wizard for Linux or Windows (via WSL2).
- **Automated Service Wiring:** Automatically configures and connects Radarr, Sonarr, Prowlarr, qBittorrent, Bazarr, Seerr, Recyclarr, and your media server post-install.
- **VPN-First Architecture:** Gluetun integration forces download client traffic through the VPN, complete with start-time verification and a stalled-routing watchdog.
- **Built-in Operator CLI:** Manage the stack (`start`, `stop`, `status`), edit configurations, snapshot backups, and update containers from the command line.
- **Optimized Media Layout:** Built-in hardlinks-friendly structure for Jellyfin/Emby/Plex with out-of-the-box TRaSH Guides quality profiles.

## The Stack
- **Media Server:** Jellyfin (recommended), Emby, or Plex
- **Download Client:** qBittorrent
- **Managers:** Sonarr, Radarr
- **Subtitles:** Bazarr (auto-wired to Sonarr/Radarr; optional OpenSubtitles.com)
- **Indexing:** Prowlarr
- **Request Management:** Seerr (delete request fully removes media via `seerr-gateway`; see [docs/seerr-delete-request.md](docs/seerr-delete-request.md))
- **Quality Profiles:** Recyclarr
- **Management:** Built-in `assemblrr` CLI (`status`, `logs`, `start`/`stop`, …)

## Installation

### Linux / WSL2

*Note: `bash` must be installed to run the setup script.*

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
| `status` | Operator dashboard: service state + URLs (`--docker` for raw compose ps) |
| `health` | Compact healthcheck pass/fail for all containers |
| `logs [service]` | Follow logs (all services, or one) |
| `config` | List config subcommands |
| `config show` | Show current configuration |
| `config edit` | Re-run the setup wizard (current values as defaults) |
| `backup /target/dir` | Snapshot configuration |
| `restore /backup.tar.gz` | Restore from a backup archive |
| `update-containers` | Pull latest images and restart (offers a backup first) |
| `update-cli` | Update the CLI to the latest version |
| `upgrade` | Upgrade from git `main` (or `--from DIR`): files, migrations, stack restart, service wiring |
| `upgrade --check` | Dry-run: show which managed files and migrations would run |
| `check-vpn` | Poll VPN health |
| `uninstall` | Remove everything (asks before deleting data) |


## Configuration & Architecture

Configuration lives in your installation directory (default: `~/assemblrr`).

- `.env`: Generated at install from [`.env.example`](.env.example) (all variables are documented there). Credentials live under `secrets/`, not in `.env`.
- `compose/base.yaml`: Core services.
- `compose/vpn.yaml` / `compose/direct-access.yaml`: Networking overlays.
- `compose/custom.yaml`: Optional services (from the example under `compose/examples/`).
- `config/`: Persistent service data.

## Documentation

- **[TRaSH Guides & Quality Profiles](docs/trash-guides.md):** Details on how assemblrr handles quality profiles and what to do when community guide IDs change.
- **[Seerr delete request → full purge](docs/seerr-delete-request.md):** How `seerr-gateway` makes “delete request” remove media/torrents, and how to retire it if Seerr gains this natively.
- **[Uninstall Guide](docs/uninstall.md):** Complete removal guide, including a full inventory of what an installation creates.
- **[API Reference](docs/api-reference.md):** Official API documentation links for all services in the stack.

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

Originally inspired by [YAMS](https://yams.media/) ([rogsme/yams](https://github.com/rogsme/yams)); assemblrr has since been rewritten and expanded into its own project.

### License
GNU General Public License v3.0
