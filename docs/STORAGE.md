# Storage and import contract

## Host roots

| Variable | Purpose | Expected backing storage |
| --- | --- | --- |
| `CONFIG_ROOT` | Mutable service configuration, databases, metadata, caches, logs, certificates | Operator-selected local path |
| `MEDIA_ROOT` | Torrents and media libraries | Existing operator-provided filesystem |
| `RUNTIME_ROOT` | Generated orchestration config, secrets, and installer state | Protected local path |

The installer never formats, partitions, initializes, repairs, or automatically mounts storage. The operator supplies an existing `MEDIA_ROOT`.

`install.sh --check` reports storage checks only when `${MEDIA_ROOT}` exists, is its own mounted filesystem, and contains all six expected torrent/library directories. Failure is reported without creating, mounting, formatting, repairing, or changing the path. Passing these checks is not a deployment-ready result. Repository tests use explicit temporary roots and never create the example media path.

## Media mounts

Every media-aware container uses the same `/data` namespace. Sonarr and Radarr deliberately receive the broader root because hardlinks require download sources and library destinations to exist beneath one container mount.

| Service | Host source | Container target | Mode/intent |
| --- | --- | --- | --- |
| Jellyfin | `${MEDIA_ROOT}/library` | `/data/library` | Read-only |
| qBittorrent | `${MEDIA_ROOT}/torrents` | `/data/torrents` | Read-write |
| Radarr | `${MEDIA_ROOT}` | `/data` | Read-write; one mount for movie hardlinks |
| Sonarr | `${MEDIA_ROOT}` | `/data` | Read-write; one mount for TV/anime hardlinks |
| Bazarr | each `${MEDIA_ROOT}/library/*` subtree | matching `/data/library/*` target | Read-write for subtitle files |
| Prowlarr, FlareSolverr, Seerr | None | None | No media access |
| Recyclarr | Protected generated configuration and state | `/config` | Read-write because Recyclarr stores required state beside its configuration; host directory is `0700` and generated config is `0600` |
| Reverse proxy | None | None | No media access |

Recyclarr's separate `/data` mount at `${CONFIG_ROOT}/recyclarr` contains regenerable resources and logs. Its container root filesystem remains read-only, it has no media mount, and Media services invokes only `sync --preview`.

qBittorrent deployment verified qBittorrent's writable torrent-only mount and exact category paths. ARR deployment verified the single broad `/data` mount in Sonarr/Radarr and proved cross-tree hardlinks with isolated temporary files that were removed afterward. Other services retain narrower access and receive no media mount unless required.

## Download and import relationships

```text
qBittorrent category movies -> /data/torrents/movies
qBittorrent category tv     -> /data/torrents/tv
qBittorrent category anime  -> /data/torrents/anime

Radarr root folder          -> /data/library/movies
Sonarr TV root folder       -> /data/library/tv
Sonarr anime root folder    -> /data/library/anime
```

All media-writing services use the same `PUID`, `PGID`, and compatible `UMASK`. ARR deployment enabled Completed Download Handling and hardlinks in Sonarr/Radarr. Remote-path mappings are absent because paths already agree.

A torrent or download link may be removed only after successful import and completion of the configured seed policy. Unknown or unimported data is never deleted automatically. Future monitoring must identify failed imports, permission failures, unmatched releases, stuck torrents, and orphaned downloads. Reconciliation must default to dry-run before any deletion.
