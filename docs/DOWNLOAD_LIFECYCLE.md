# Download lifecycle and safe cleanup

Download lifecycle setup's production lifecycle policy is deployed and verified through authenticated application APIs. It is configuration-only: no real or synthetic torrent was created during the successful deployment, and no download was performed. The optional live synthetic torrent test is deferred, excluded from the default installer, and is not a Download lifecycle setup completion requirement.

The intended lifecycle does not download external content. The tracked policy is `config/download-lifecycle-policy.json`; deployment evidence, API snapshots, and backups remain under ignored root-only runtime storage.

## Operator workflow

Run on the deployed Debian host in order:

```sh
sudo --preserve-env=SSH_CONNECTION scripts/deploy/download-lifecycle.sh --check
sudo --preserve-env=SSH_CONNECTION scripts/deploy/download-lifecycle.sh --preview
sudo --preserve-env=SSH_CONNECTION scripts/deploy/download-lifecycle.sh --apply
sudo --preserve-env=SSH_CONNECTION scripts/deploy/download-lifecycle.sh --verify
```

`--check` is read-only. `--preview` creates or preserves a consistent protected application backup and a sanitized list of proposed setting changes; it reports zero cleanup candidates and performs no deletion. `--apply` requires that preview, applies only the reviewed API configuration, verifies it, and writes the protected completion marker. Repeated apply is verification-only. `--verify` refuses to claim success without the completion marker. `--rollback` restores the pre-download-lifecycle API configuration while retaining every backup and never touching media.

## Production policy

The locked qBittorrent 5.3.0 API uses `share_limits_mode=MatchAny`, so either the ratio or time threshold is sufficient. The global limits are ratio `1.0` and seeding time `1440` minutes. `max_ratio_act=0` is the reviewed `Stop` action in the pinned version—not removal—and automatic deletion remains disabled. The exact `movies`, `tv`, and `anime` categories and their `/data/torrents/...` locations are preserved, incomplete data remains in `/data/torrents/incomplete`, UPnP/NAT-PMP and watched folders remain disabled, and the Web UI remains loopback-only.

Sonarr and Radarr retain Completed Download Handling and hardlinks. Each existing qBittorrent client removes completed downloads only through Servarr's imported, stopped, seed-goal-complete handling. Automatic removal of failed downloads is disabled so failed or unimported payloads remain for operator review. The global failed-download history handling remains enabled. Categories, tags, root folders, quality profiles, monitoring, naming, and remote-path mappings remain unchanged.

The enabled Prowlarr torrent indexer exposes ratio, seed-time, and pack-seed-time fields. Download lifecycle setup sets those fields to `1.0`, `1440`, and `1440`; qBittorrent's verified `MatchAny` global policy remains authoritative for exact OR behavior.

## Hardlink and cleanup evidence

Hardlink behavior was proven during the earlier service deployment with isolated temporary files on the live media filesystem and is covered by Download lifecycle setup's deterministic offline tests. The production verification also requires hardlink imports to remain enabled in both Sonarr and Radarr.

Cleanup is allowed only after successful import and completion of the configured seed goal. Completed Download Handling and completed-removal support provide that application-controlled path. Failed-download removal is disabled, qBittorrent automatic deletion is disabled, and unknown, failed, partial, malformed, or unimported downloads are retained for operator review.

The optional synthetic developer helper remains available only as deferred experimental material. It is not invoked by `download-lifecycle.sh`, the default installer, readiness checks, apply, or verification. The completed deployment created no validation torrent, file, category, tag, or workspace.

The fail-closed decision model for malformed responses, missing or partial import evidence, copies instead of hardlinks, active/checking/moving/queued states, unknown categories, path traversal, symlink escape, and paths outside a validation root remains covered offline. It does not authorize deletion of production data.

## Backups and preservation

`runtime/backups/download_lifecycle-apps-before/` is root-owned mode `0700`. Its files are mode `0600` and include online SQLite backups for Sonarr, Radarr, and Prowlarr; qBittorrent configuration/category/watch-folder copies; the API snapshot; and an integrity manifest. Existing backups are preserved. Database restore is a separately guarded last resort because it would require stopping a container; normal rollback uses authenticated APIs.

Download lifecycle setup verifies all nine container identities/start times/restart counts, listeners, firewall rules, HTTPS certificate identity, the protected media size/timestamp snapshot, Quality profile setup quality profiles, Indexer and subtitle setup Bazarr state, empty Seerr/Radarr/qBittorrent activity, and unchanged Sonarr series monitoring. It neither restarts containers nor searches, grabs, downloads, imports real media, scans, renames, moves, exposes ports, or starts Control panel setup.

## Reviewed upstream semantics

The setting names and per-torrent controls follow the official [qBittorrent 5.0 WebUI API](https://github.com/qbittorrent/qBittorrent/wiki/WebUI-API-%28qBittorrent-5.0%29). The pinned source maps `MatchAny` and action value `0` to stop behavior in [appcontroller.cpp](https://github.com/qbittorrent/qBittorrent/blob/master/src/webui/api/appcontroller.cpp); defaults are also visible in [sessionimpl.cpp](https://github.com/qbittorrent/qBittorrent/blob/master/src/base/bittorrent/sessionimpl.cpp). Servarr's stopped/seed-goal/import removal behavior is documented in the official [Sonarr settings guide](https://github.com/Servarr/Wiki/blob/master/sonarr/settings.md). Prowlarr's indexer setting units are defined by [IndexerTorrentBaseSettings.cs](https://github.com/Prowlarr/Prowlarr/blob/develop/src/NzbDrone.Core/Indexers/IndexerTorrentBaseSettings.cs). These contracts were verified on 2026-10-24; updates require explicit review.
