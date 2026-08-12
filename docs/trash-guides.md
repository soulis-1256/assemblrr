# Quality Profiles & TRaSH Guides

assemblrr uses [Recyclarr](https://recyclarr.dev/) to sync [TRaSH Guides](https://trash-guides.info/) quality profiles and custom formats into Radarr and Sonarr.

**Subtitles:** Bazarr is wired separately (not via Recyclarr). On first install and every `assemblrr upgrade`, assemblrr applies [TRaSH Bazarr suggested scoring](https://trash-guides.info/Bazarr/Bazarr-suggested-scoring/) (series min score 90, movies 80, auto-sync thresholds 96/86). Subtitle providers are chosen interactively from the running Bazarr image (fzf multi-select; nothing enabled unless you pick it). OpenSubtitles.com is enabled only when you saved credentials during setup.

**Both resolutions are always installed** as assemblrr-named profiles (movies: **assemblrr HD Bluray + WEB** + **assemblrr UHD Bluray + WEB**; TV: **assemblrr WEB-1080p** + **assemblrr WEB-2160p**). The setup question only picks Seerr’s *default* for movie requests — the other profile stays available in the quality dropdown. Stock Radarr/Sonarr profiles (Any, HD-1080p, …) also appear there; that is normal.

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
