# Uninstall & Complete Removal

Assemblrr installs entirely into your home directory by default, uses no system
packages, and needs no sudo to remove. Everything it creates is listed below, so
you can always verify what belongs to it — and remove it completely, by hand,
even if the installation itself is broken.

## What an installation creates

| Component | Default location |
|---|---|
| Containers | `jellyfin`/`emby`/`plex` (your choice), `qbittorrent`, `sonarr`, `radarr`, `prowlarr`, `seerr`, `recyclarr`, `portainer` — plus `gluetun`, `deunhealth`, `vpn-watchdog` when VPN is enabled |
| Docker network | `assemblrr_network` |
| Install directory (config, secrets, compose files) | `~/assemblrr` |
| Media directory (your movies/TV/downloads) | `~/assemblrr-media` |
| CLI command | `~/.local/bin/assemblrr` |
| CLI library modules | `~/.local/bin/lib/{core,branding,compose,vpn}.sh` |
| Runtime config | `~/assemblrr/.assemblrr-config` (inside the install directory) |
| Service URL cheat-sheet | `~/assemblrr_services.txt` |
| PATH entries (added only if missing) | `~/.profile` and/or `~/.config/fish/config.fish` |
| Logs | `/tmp/assemblrr-*.log` |

No named Docker volumes are used — all state lives in the two directories above.

## Option 1 — Normal uninstall (CLI works)

```bash
assemblrr backup ~/my-backup        # optional, but recommended first
assemblrr uninstall                 # interactive: asks before deleting anything
```

The interactive uninstall:

- stops and removes all containers, volumes, and the Docker network
- asks before deleting the install directory (type the full path to confirm)
- asks before deleting the media directory (type the full path to confirm)

Variants:

```bash
assemblrr uninstall --force         # no prompts; deletes everything EXCEPT media
assemblrr uninstall --force --media # no prompts; deletes everything INCLUDING media
```

`--force` never deletes your media directory unless you also pass `--media` —
media is your actual content and is treated as opt-in deletion.

## Option 2 — CLI missing or installation broken

Setup copies the CLI into the install directory, so you can run it directly
without anything being on your PATH (works from fish too):

```bash
bash ~/assemblrr/cli.sh uninstall
```

If the install directory itself is gone or unreadable, use Option 3.

## Option 3 — Manual removal (nothing else works)

Every step is independent; run whichever apply.

**1. Remove containers and the network:**

```bash
docker rm -f jellyfin emby plex qbittorrent sonarr radarr prowlarr \
    seerr recyclarr portainer gluetun deunhealth vpn-watchdog 2>/dev/null
docker network rm assemblrr_network 2>/dev/null
```

**2. Delete the install directory (configuration, secrets, compose files):**

```bash
rm -rf ~/assemblrr
```

**3. Delete the media directory — only if you really want your content gone:**

```bash
rm -rf ~/assemblrr-media    # WARNING: this is your movies/TV/downloads
```

**4. Remove the CLI files:**

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

**6. PATH entries.** Uninstall keeps the `$HOME/.local/bin` PATH lines in
`~/.profile` / `~/.config/fish/config.fish`. Remove them manually if you want.

## Guarantees

Removal will never:

- touch system directories or require sudo (default home-based installation)
- delete your media directory without explicit confirmation or `--media`
- remove `~/.local/bin/lib` if it contains files that aren't Assemblrr's
- delete Docker images or the `~/.local/bin` PATH entry
- uninstall packages, because none are installed (dependencies are only
  suggested via your package manager during setup if missing)

## Windows / WSL2

Run any of the options above inside your WSL2 distro. If you used the dev
scripts, `.\platform\windows\bootstrap-dev.ps1 -Full -Clean` also uninstalls
the existing WSL2 installation before setting up again.
