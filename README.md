# assemblrr

> [!NOTE]
> **Developer’s note — vision & roadmap**  
> assemblrr is infrastructure for self-hosted media *automation* (install, wire services, operate the stack). It does **not** provide media, indexers, or content. What you request, download, and host is entirely your responsibility and must comply with the laws that apply to you.
>
> Future directions and ideas shall be discussed with the community **[here](https://github.com/soulis-1256/assemblrr/discussions/1)**

Self-hosted media automation, set up in minutes, not a weekend.

## Features & Philosophy

- **Docker-native stack:** One Compose project, overlays for VPN vs direct access, optional services via `compose/custom.yaml` — no host package installs for the *arr suite.
- **Guided install, multi-platform:** Interactive wizard (or express defaults) for Linux, WSL2, and Windows (PowerShell → WSL). Fail-fast VPN check before the rest of setup when VPN is enabled.
- **Auto-wired services:** Post-install wiring connects Radarr, Sonarr, Prowlarr, qBittorrent, Seerr, Recyclarr, and Jellyfin (libraries, auth, root folders, download clients) instead of a manual weekend of clicking.
- **Quality profiles that ship ready:** Recyclarr syncs assemblrr-named HD and UHD (and TV) profiles from TRaSH Guides; setup only picks Seerr’s default. Both resolutions stay available for overrides.
- **Request → library path:** Seerr in front of Radarr/Sonarr for a simple request UX, with hardlinks-friendly media layout for Jellyfin/Emby/Plex.
- **VPN-first downloads:** Gluetun integration, download client traffic forced through the VPN context, `check-vpn` / start-time verification, and a vpn-watchdog for stalled routing.
- **Operator CLI:** `start` / `stop` / `restart` / `status` / `health` / `logs`, `config` (show / edit / sync), `backup` / `restore`, `update-containers` / `update-cli`, and a careful `uninstall` that preserves media unless you opt in.
- **Fail-safe backups:** CLI snapshots of configuration before risky updates so you can roll back without rebuilding from scratch.
- **Secrets outside `.env`:** Service login and VPN credentials live under `secrets/`; runtime settings stay in `.assemblrr-config` and `.env`.
- **Optional extras:** Lidarr, SABnzbd, Bazarr, Watchtower via custom compose — deployed, not auto-configured.

## The Stack
- **Media Server:** Jellyfin (recommended), Emby, or Plex
- **Download Client:** qBittorrent
- **Managers:** Sonarr, Radarr
- **Indexing:** Prowlarr
- **Request Management:** Seerr
- **Quality Profiles:** Recyclarr
- **Management:** Portainer

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
| `config` | List config subcommands |
| `config show` | Show current configuration |
| `config edit` | Re-run the setup wizard (current values as defaults) |
| `config sync` | Re-wire service APIs (Radarr, Sonarr, Prowlarr, Seerr, …) |
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

## Quality Profiles & TRaSH Guides

assemblrr uses [Recyclarr](https://recyclarr.dev/) to sync [TRaSH Guides](https://trash-guides.info/) quality profiles and custom formats into Radarr and Sonarr.

**Both resolutions are always installed** as assemblrr-named profiles (movies: **assemblrr HD Bluray + WEB** + **assemblrr UHD Bluray + WEB**; TV: **assemblrr WEB-1080p** + **assemblrr WEB-2160p**). The setup question only picks Seerr’s *default* for movie requests — the other profile stays available in the quality dropdown. Stock Radarr/Sonarr profiles (Any, HD-1080p, …) also appear there; that is normal.

assemblrr deliberately **does not** apply TRaSH quality min-size limits (they can reject smaller legitimate releases), and softens hard-block custom formats (LQ / x265 / 3D scores set to 0). Tier preferences from the guides still apply when better releases exist.

**Those guides change over time.** Trash IDs, profile names, and Recyclarr YAML schema can all break without warning. When that happens you may see:

- Recyclarr sync errors (`Invalid quality profile trash_id`, `YAML error`, etc.)
- Seerr defaulting to **Any** instead of your chosen quality
- Missing Recyclarr profiles in Radarr/Sonarr (only stock profiles like Any / HD-1080p)

That is expected community-guide churn — not a VPN or Docker failure.

### What to do when it breaks

1. Check Recyclarr: `docker logs recyclarr` and/or `docker exec recyclarr recyclarr sync`
2. List current guide IDs from inside the container:
   ```bash
   docker exec recyclarr recyclarr list quality-profiles radarr
   docker exec recyclarr recyclarr list quality-profiles sonarr
   ```
3. Update the relevant pack under `templates/recyclarr/includes/` (or the live copies in your install’s `config/recyclarr/includes/`) with the new trash IDs. Root config is `templates/recyclarr/recyclarr.yml`.
4. Re-run Recyclarr, then refresh app wiring: `assemblrr config sync`

We try to keep templates current, but **plan on occasional manual updates** if you rely on TRaSH-backed profiles long-term. Official docs: [Recyclarr](https://recyclarr.dev/) · [TRaSH Guides](https://trash-guides.info/).

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
