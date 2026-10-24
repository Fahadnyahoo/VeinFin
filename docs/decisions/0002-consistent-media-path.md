# ADR 0002: Consistent `/data` media namespace

- Status: accepted
- Date: 2026-10-23

## Decision

Every media-aware service uses paths beneath `/data`. qBittorrent receives the torrent subtree, Sonarr and Radarr receive the whole media root as one `/data` mount, Jellyfin receives the library read-only, and Bazarr receives only required library subtrees.

## Rationale

Consistent paths remove the need for Docker remote-path mappings and make imports diagnosable. A single Sonarr/Radarr mount keeps torrent sources and library destinations on the same container mount so hardlinks can work. Shared UID/GID and compatible permissions support import and subtitle writes.

## Consequences

The operator-provided media filesystem must contain both `torrents/` and `library/`. Runtime hardlink verification remains required during deployment before automated cleanup is enabled.
