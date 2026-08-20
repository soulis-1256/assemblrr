# Quality Profiles & TRaSH Guides

assemblrr uses [Recyclarr](https://recyclarr.dev/) to sync [TRaSH Guides](https://trash-guides.info/) quality profiles and custom formats into Radarr and Sonarr.

**Subtitles:** Bazarr is wired separately (not via Recyclarr). On first install and every `assemblrr upgrade`, assemblrr applies [TRaSH Bazarr suggested scoring](https://trash-guides.info/Bazarr/Bazarr-suggested-scoring/) (series min score 90, movies 80, auto-sync thresholds 96/86). Subtitle providers are chosen interactively from the running Bazarr image (fzf multi-select; nothing enabled unless you pick it). OpenSubtitles.com is enabled only when you saved credentials during setup.

**Both resolutions and both movie sources are always installed** as assemblrr-named profiles:

- Movies: **assemblrr HD Bluray + WEB**, **assemblrr UHD Bluray + WEB**, **assemblrr WEB-1080p**, **assemblrr WEB-2160p**
- TV: **assemblrr WEB-1080p**, **assemblrr WEB-2160p**

TRaSH has no first-class WEB-only Radarr profile. Movie WEB packs reuse the HD/UHD Bluray + WEB trash IDs as Recyclarr variants, with qualities overridden so Blu-ray is disabled and cutoff is WEB. All four stay in the Radarr/Seerr dropdown; setup only picks the default.

Setup and `config edit` ask once for resolution, then (unless you chose Any) for movie source. That pair is the default for **Radarr, Sonarr, and Seerr**:

- **Ultra-HD (4K) + Bluray + WEB:** movies → UHD Bluray + WEB, TV → WEB-2160p
- **Ultra-HD (4K) + WEB:** movies → WEB-2160p, TV → WEB-2160p
- **1080p + Bluray + WEB:** movies → HD Bluray + WEB, TV → WEB-1080p
- **1080p + WEB:** movies → WEB-1080p, TV → WEB-1080p
- **Any:** stock *arr Any (movie source is ignored)

Missing `QUALITY_SOURCE` on an older install means **bluray** (the previous default). TV is always WEB; TRaSH’s English Sonarr defaults are WEB-only.

The chosen profile is written over *arr’s stock **Any** slot (id 1) so Add Movie / Add Series opens on it. The other assemblrr profiles stay in the dropdown. Titles already in the library keep whatever profile they have. Stock *arr profiles (HD-1080p, …) still appear; that is normal.

assemblrr deliberately **does not** apply TRaSH quality min-size limits (they can reject smaller legitimate releases), and softens hard-block custom formats (LQ / x265 / 3D scores set to 0). Tier preferences from the guides still apply when better releases exist.

**Those guides change over time.** Trash IDs, profile names, and Recyclarr YAML schema can all break without warning. When that happens you may see:

- Recyclarr sync errors (`Invalid quality profile trash_id`, `YAML error`, etc.)
- Seerr defaulting to **Any** instead of your chosen quality
- Missing Recyclarr profiles in Radarr/Sonarr (only stock profiles like Any / HD-1080p)

That is expected community-guide churn — not a VPN or Docker failure.

## What to do when it breaks

1. Check Recyclarr: `docker logs recyclarr` and/or `docker exec recyclarr recyclarr sync`
2. List current guide IDs from inside the container:
   ```bash
   docker exec recyclarr recyclarr list quality-profiles radarr
   docker exec recyclarr recyclarr list quality-profiles sonarr
   ```
3. Update the relevant pack under `templates/recyclarr/includes/` (or the live copies in your install’s `config/recyclarr/includes/`) with the new trash IDs. Root config is `templates/recyclarr/recyclarr.yml`.
4. Re-run Recyclarr, then refresh the install (wiring included): `assemblrr upgrade`

We try to keep templates current, but **plan on occasional manual updates** if you rely on TRaSH-backed profiles long-term. Official docs: [Recyclarr](https://recyclarr.dev/) · [TRaSH Guides](https://trash-guides.info/).
