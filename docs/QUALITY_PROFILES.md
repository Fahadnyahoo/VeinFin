# Quality profiles and Recyclarr synchronization

Quality profile setup manages exactly three future-content quality profiles through the pinned Recyclarr 8.8.0 one-shot container. Recyclarr remains disabled by default through its Compose profile and has no schedule, listener, media mount, or long-running container. The policy source is `config/quality-policy.json`; runtime API keys and generated YAML never enter tracked files.

## Operator workflow

Run each command on the deployed Debian checkout as root:

```sh
sudo --preserve-env=SSH_CONNECTION scripts/deploy/quality-profiles.sh --check
sudo --preserve-env=SSH_CONNECTION scripts/deploy/quality-profiles.sh --preview
sudo --preserve-env=SSH_CONNECTION scripts/deploy/quality-profiles.sh --apply
sudo --preserve-env=SSH_CONNECTION scripts/deploy/quality-profiles.sh --verify
```

`--check` is read-only. `--preview` creates a protected backup, generates `runtime/config/recyclarr/quality_profiles.yml` atomically with mode `0600`, runs Recyclarr's official preview, and records only a sanitized structured summary. `--apply` refuses to proceed unless that summary matches the unchanged generated configuration and reviewed resource revisions. The first apply performs one sync and changes only future Seerr defaults; later applies are verification-only. `--rollback` removes the managed API resources and restores Seerr's prior connection defaults without touching media. Database restoration is deliberately not automated because it requires a separately guarded container stop.

## Managed policy

- `VeinFin Movies 4K` allows sensible 2160p BluRay and WEB encodes, with equivalent 1080p fallbacks. It excludes Remux qualities, AV1, Dolby Vision without an HDR fallback, HLG, 3D, disc images, known low-quality releases, and upscales. HDR10 remains allowed and x265/HEVC receives a modest preference.
- `VeinFin TV 1080p SDR` allows only 1080p BluRay and WEB encodes. HDR-family releases, Dolby Vision, HLG, AV1, disc images, known low-quality releases, and upscales receive a rejecting score. Both x264 and x265 remain eligible. Every allowed quality must retain a finite existing global maximum size, so oversized releases remain ineligible without modifying the shared quality definitions.
- `VeinFin Anime 1080p SDR` has the same 1080p/SDR and finite-size ceiling, adds the reviewed anime low-quality-group rejection, rejects dub-only releases, and modestly prefers dual audio and x265. It has no subtitle-track rejection rule, so additional or embedded Arabic/English subtitle tracks do not disqualify a release.

A rejecting custom-format score is `-10000`, while every managed profile has a minimum accepted score of `0`. Preferences are deliberately small (`+100` for x265 and `+50` for anime dual audio). Quality availability supplies the resolution/source ceiling; custom formats provide compatibility and release-quality policy. Existing profiles receive no managed score and are not renamed, deleted, or selected for existing content.

Seerr's existing Radarr connection uses the movie profile for future requests. Its existing single Sonarr connection supports distinct normal and anime defaults, so normal TV uses the TV profile and anime uses the anime profile. Search prevention stays enabled, and no duplicate connection or request is created.

## Reproducible resources

The reviewed resource lock is stored beside the policy:

- Recyclarr: `8.8.0`, image digest recorded in `config/images.lock`
- Recyclarr configuration templates: `89eebadd429952069182a22930af4d768cacda36`
- TRaSH Guides: `64f542670d82e279d3d4ea67850b6753313cfd5f`

These cached official resources were reviewed on 2026-10-24. The TRaSH revision differs from the previous cache only by broadening its Radarr low-quality `HDS` release-group match to include Radarr's `10bit-HDS` parsing; that strengthens the selected rejection rule without changing its identity or score. The workflow resolves Git object IDs directly and stops if either revision differs. Updates require an explicit review and policy-lock change; the apply workflow never accepts unreviewed moving content.

## Backups and safety

`runtime/backups/quality_profiles-apps-before/` contains root-only, mode-`0700` protected Sonarr, Radarr, and Seerr online SQLite backups, configuration copies, the API snapshot, and Recyclarr configuration/resource state. Files are mode `0600`, and each database passes `PRAGMA integrity_check`. Existing backups are preserved. Quality profile setup also compares container identities, start times, restart counts, listeners, firewall rules, HTTPS certificate identity, Indexer and subtitle setup Prowlarr/Bazarr state, queues/history, Seerr requests, qBittorrent torrents, the adopted-series assignment, and the protected media size/timestamp snapshot.

Quality profile setup does not search, grab, download, import, scan, rename, move, delete, upgrade, or assign existing content. It does not schedule Recyclarr, restart a long-running container, expose a port, alter a download client/indexer/root folder/tag/naming/media-management setting, change Who's Watching experimental material, or begin Download lifecycle setup.
