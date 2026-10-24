# Controlled Sonarr adoption

Sonarr adoption adopts one existing series into Sonarr without changing its media. It uses Sonarr's authenticated loopback API, an exact lookup identity supplied through protected runtime state, an existing quality profile, the existing Anime root, and the existing Anime tag/download-client routing.

## Interface

Run on the Debian target:

```sh
sudo --preserve-env=SSH_CONNECTION scripts/deploy/sonarr-adoption.sh --check
sudo --preserve-env=SSH_CONNECTION scripts/deploy/sonarr-adoption.sh --apply
sudo --preserve-env=SSH_CONNECTION scripts/deploy/sonarr-adoption.sh --verify
```

`--check` is read-only. It verifies the manifest, nine healthy zero-restart containers, Jellyfin's Library setup result, Sonarr/Radarr/qBittorrent/Prowlarr/Seerr state, the qBittorrent connection, Completed Download Handling, hardlink imports, disabled renaming, HTTPS, listeners, and firewall.

`--apply` records protected infrastructure baselines, takes a consistent SQLite backup plus `config.xml`, snapshots every existing file's relative path, byte size, and nanosecond timestamp, and adds the lookup-verified series. It sets series type `anime`, monitoring `none`, and all automatic searches false. It requires observing Sonarr's new automatic post-add `RefreshSeries` and waits for that command to finish before invoking the local `RescanSeries` command. Validation requires six consecutive exact expected file counts. Repeated apply is verification-only.

`--verify` confirms the exact series identity and settings, unmonitored episodes, contiguous absolute episode-to-file mapping, files confined to the declared series directory, unchanged media snapshot, zero torrents, no active search/RSS command, unchanged Jellyfin state, and unchanged container/listener/firewall/HTTPS baselines.

## Protected manifest

The ignored, root-owned, mode-`0600` `runtime/state/sonarr_adoption-series.conf` contains:

- `LOOKUP_TERM`: a Sonarr lookup term;
- `EXPECTED_TVDB_ID`: the identity selected from the lookup response;
- `QUALITY_PROFILE`: an already-existing Sonarr profile name;
- `SERIES_PATH`: the existing container-visible directory below `/data/library/anime`;
- `HOST_SERIES_PATH`: its existing host path below `/srv/media/library/anime`;
- `EXPECTED_FILES`: the exact expected episode-file count.

Tracked files contain no media title, filename, inventory, private address, deployment hostname, API key, or credential.

## Backup and rollback

The first apply creates ignored `runtime/backups/sonarr_adoption-sonarr-before/`, mode `0700`, containing root-owned mode-`0600` `sonarr.db`, `config.xml`, and backup metadata. SQLite's online backup API creates a consistent database copy without stopping Sonarr.

If post-adoption validation fails, the helper deletes only the newly created Sonarr series entry with `deleteFiles=false`, verifies the media snapshot, and leaves the backup for review. An interrupted adoption leaves a protected start marker and blocks automatic retry. Restoring the database backup would require stopping only Sonarr and therefore remains a separately reviewed recovery action; this workflow does not restart any container automatically.

## Deliberate limits

Sonarr adoption does not rename, move, copy, hardlink, delete, retimestamp, or rewrite media. It does not modify quality profiles, naming rules, download clients, Completed Download Handling, indexers, providers, plugins, subtitle languages, requests, Jellyfin libraries, Caddy, firewall rules, DNS, or storage. Metadata may describe later episodes, but monitoring is disabled and only the declared existing episode files may be recognized. No torrent, RSS search, interactive search, or automatic download is initiated.
