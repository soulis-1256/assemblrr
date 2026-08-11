# Uninstall & Complete Removal

assemblrr installs into your home directory by default and uses no system
packages. Everything it creates is listed below so you can verify ownership
and remove a complete or half-finished install by hand.

A **finished** install can usually be removed without sudo (Option 1–2).
A **failed setup** that already started Gluetun can leave `~/assemblrr/config`
root-owned; plain `rm -rf` then fails — use the Docker removal step in Option 3
(no sudo if your user is in the `docker` group).

## What an installation creates

| Component | Default location |
|---|---|
| Containers | `jellyfin`/`emby`/`plex` (your choice), `qbittorrent`, `sonarr`, `radarr`, `prowlarr`, `bazarr`, `seerr`, `recyclarr`, `portainer` — plus `gluetun`, `deunhealth`, `vpn-watchdog` when VPN is enabled |
| Docker network | `assemblrr_network` |
| Install directory (config, secrets, compose files) | `~/assemblrr` |
| Media directory (your movies/TV/downloads) | `~/assemblrr-media` |
| CLI command | `~/.local/bin/assemblrr` |
| CLI library modules | `~/.local/bin/lib/{core,branding,compose,vpn}.sh` |
| Runtime config | `~/assemblrr/.assemblrr-config` (written near the end of setup) |
| Service URL cheat-sheet | `~/assemblrr_services.txt` |
| Logs | `/tmp/assemblrr-*.log` |

No named Docker volumes are used — all state lives in the two directories above.

### Which option applies?

| Situation | Use |
|---|---|
| Setup finished; `assemblrr` is on your PATH | Option 1 |
| Setup finished; CLI missing from PATH but `~/assemblrr/cli.sh` and `.assemblrr-config` exist | Option 2 |
| Setup failed mid-way, no `.assemblrr-config`, `Permission denied` on `config/`, or CLI cannot find the install | Option 3 |

## Option 1 — Normal uninstall (CLI works)

```bash
assemblrr backup ~/my-backup        # optional, but recommended first
assemblrr uninstall                 # interactive prompts — read them before confirming
```

Non-interactive:

```bash
assemblrr uninstall --force         # no prompts; keeps media
assemblrr uninstall --force --media # no prompts; deletes media too
```

`--force` alone never deletes your media directory; pass `--media` to opt in.

## Option 2 — CLI missing from PATH (install is otherwise complete)

Setup copies the CLI into the install directory. If `.assemblrr-config` exists:

```bash
bash ~/assemblrr/cli.sh uninstall
```

If that errors with “could not find installation” or there is no
`.assemblrr-config`, setup never finished — use Option 3.

## Option 3 — Manual removal (failed or incomplete setup)

Every step is independent; run whichever apply. **Media is left alone** unless
you deliberately remove it in step 3.

**1. Remove containers and the network:**

```bash
docker rm -f jellyfin emby plex qbittorrent sonarr radarr prowlarr bazarr \
    seerr recyclarr portainer gluetun deunhealth vpn-watchdog 2>/dev/null
docker network rm assemblrr_network 2>/dev/null
```

**2. Delete the install directory:**

If you own the tree:

```bash
rm -rf ~/assemblrr
```

If you see `Permission denied` under `config/` (common after a VPN test that
created bind mounts as root), remove via Docker instead — same effect, no sudo,
requires membership in the `docker` group:

```bash
docker run --rm -v "$HOME:/target" alpine rm -rf /target/assemblrr
```

Or with sudo:

```bash
sudo rm -rf ~/assemblrr
```

**3. Delete the media directory — only if you really want your content gone:**

```bash
rm -rf ~/assemblrr-media    # WARNING: this is your movies/TV/downloads
```

**4. Remove the CLI files** (only if setup got far enough to install them):

```bash
rm -f ~/.local/bin/assemblrr
rm -f ~/.local/bin/lib/core.sh ~/.local/bin/lib/branding.sh \
      ~/.local/bin/lib/compose.sh ~/.local/bin/lib/vpn.sh
rmdir ~/.local/bin/lib 2>/dev/null    # only removed if now empty
rm -f ~/assemblrr_services.txt
```

**5. Optional — remove the Docker images:**

```bash
# VPN mode also pulls qmcgaw/gluetun and qmcgaw/deunhealth;
# swap jellyfin for emby/plex if you chose a different media server
docker rmi lscr.io/linuxserver/jellyfin lscr.io/linuxserver/qbittorrent \
    lscr.io/linuxserver/sonarr lscr.io/linuxserver/radarr \
    lscr.io/linuxserver/prowlarr portainer/portainer-ce \
    ghcr.io/seerr-team/seerr ghcr.io/recyclarr/recyclarr alpine:3
```

## Windows / WSL2

Run any of the options above inside your WSL2 distro. If you used the dev
scripts, `.\platform\windows\bootstrap-dev.ps1 -Full -Clean` also uninstalls
the existing WSL2 installation before setting up again.
