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
| Containers | `jellyfin`/`emby`/`plex` (your choice), `qbittorrent`, `sonarr`, `radarr`, `prowlarr`, `bazarr`, `seerr`, `seerr-gateway`, `media-purge-watch`, `recyclarr` — plus `gluetun`, `deunhealth`, `vpn-watchdog` when VPN is enabled; older installs may still have `portainer` |
| Docker network | `assemblrr_network` |
| Install directory (config, secrets, compose files) | `~/assemblrr` (or the path you chose) |
| Media directory (your movies/TV/downloads) | `~/assemblrr-media` (or the path you chose) |
| CLI command | `~/.local/bin/assemblrr` |
| CLI library modules | `~/.local/bin/lib/*.sh` |
| Runtime config | `<install>/.assemblrr-config` (written when the install tree is first bootstrapped — early in setup, not only at the end) |
| Discovery pointer | `~/.assemblrr-config` (points at `INSTALL_DIRECTORY` so the CLI can find non-default paths) |
| Logs | `/tmp/assemblrr-*.log` |
| Legacy (old installs) | `~/assemblrr_services.txt` — unused; safe to delete; `uninstall` removes it |

No named Docker volumes are used — all state lives in the install and media
directories above.

### Mid-setup / abort

Setup installs the operator CLI as soon as the install path is known (VPN test
path or after you choose directories). If you stop setup early (Ctrl+C, failed
VPN, closed terminal):

1. Prefer **`assemblrr uninstall`** (or `assemblrr uninstall --force` to keep
   media without prompts) if `~/.local/bin` is on your `PATH`.
2. If the shell says `command not found`, try a **new terminal**, or run the
   binary directly: `~/.local/bin/assemblrr uninstall --force`.
3. If the PATH CLI is missing but the install tree exists, use **Option 2**.
4. If there is no install tree / no runtime config, use **Option 3**.

`--force` alone **never** deletes your media directory; pass `--media` only if
you intend to delete movies/TV/downloads as well.

### Which option applies?

| Situation | Use |
|---|---|
| CLI works (`assemblrr` on PATH, or `~/.local/bin/assemblrr`) | Option 1 |
| CLI not on PATH, but `<install>/cli.sh` and `<install>/.assemblrr-config` exist (finished **or** mid-setup abort after bootstrap) | Option 2 |
| No runtime config, incomplete tree, `Permission denied` on `config/`, or CLI cannot find the install | Option 3 |

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

If a new shell has not picked up `~/.local/bin` yet:

```bash
~/.local/bin/assemblrr uninstall --force
```

## Option 2 — Install tree present, PATH CLI missing

Setup always copies `cli.sh` into the install directory when it bootstraps the
tree. If `<install>/.assemblrr-config` exists (default: `~/assemblrr`):

```bash
bash ~/assemblrr/cli.sh uninstall
# or non-interactive, keep media:
bash ~/assemblrr/cli.sh uninstall --force
```

If that errors with “could not find installation” or there is no
`.assemblrr-config`, use Option 3.

## Option 3 — Manual removal (failed or incomplete setup)

Every step is independent; run whichever apply. **Media is left alone** unless
you deliberately remove it in step 3.

**1. Remove containers and the network:**

```bash
docker rm -f jellyfin emby plex qbittorrent sonarr radarr prowlarr bazarr \
    seerr seerr-gateway media-purge-watch recyclarr portainer \
    gluetun deunhealth vpn-watchdog 2>/dev/null
# portainer: only if an older install still has it
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
rm -f ~/.local/bin/lib/*.sh
rmdir ~/.local/bin/lib 2>/dev/null    # only removed if now empty
rm -f ~/assemblrr_services.txt 2>/dev/null   # legacy cheat-sheet
rm -f ~/.assemblrr-config 2>/dev/null        # discovery pointer
```

**5. Optional — remove the Docker images:**

```bash
# VPN mode also pulls qmcgaw/gluetun and qmcgaw/deunhealth;
# swap jellyfin for emby/plex if you chose a different media server
docker rmi lscr.io/linuxserver/jellyfin lscr.io/linuxserver/qbittorrent \
    lscr.io/linuxserver/sonarr lscr.io/linuxserver/radarr \
    lscr.io/linuxserver/prowlarr \
    ghcr.io/seerr-team/seerr ghcr.io/recyclarr/recyclarr alpine:3
# older installs: docker rmi portainer/portainer-ce
```

## Windows / WSL2

Run any of the options above inside your WSL2 distro. If you used the dev
scripts, `.\platform\windows\bootstrap-dev.ps1 -Full -Clean` also uninstalls
the existing WSL2 installation before setting up again.
