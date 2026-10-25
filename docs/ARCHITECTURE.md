# VeinFin architecture

## Scope

VeinFin targets a supported Linux Docker host and provides a reusable, version-aware, idempotent installation path. The repository contains reusable code and templates; installation-specific values and generated secrets remain in ignored local configuration.

The operator provides a hostname that already resolves correctly. VeinFin does not manage DNS or router configuration.

## Storage model

Operator-provided local storage holds Docker, images, application configuration, databases, Jellyfin metadata, artwork, transcoding cache, logs, and temporary data.

The configurable media root defaults to `/srv/media`:

```text
/srv/media/
├── torrents/
│   ├── movies/
│   ├── tv/
│   └── anime/
└── library/
    ├── movies/
    ├── tv/
    └── anime/
```

Relevant containers will see the media root consistently as `/data`. Consistent UID, GID, UMASK, paths, and hardlink-compatible filesystems are architectural requirements for reliable imports.

The operator provides an existing `MEDIA_ROOT`. VeinFin validates its availability and expected directories but never formats, partitions, repairs, or automatically mounts storage.

## Service topology

The planned stack comprises Jellyfin, Sonarr, Radarr, Prowlarr, Bazarr, qBittorrent, Seerr, Recyclarr, FlareSolverr, an HTTPS reverse proxy, selected Jellyfin plugins, and a private VeinFin control panel.

- The reverse proxy is the only public ingress and terminates HTTPS.
- Application web interfaces and the control panel remain private and restricted to configured management CIDRs.
- FlareSolverr has no public host port and is reachable only on an internal container network by consumers that need it.
- Prowlarr, FlareSolverr, Seerr, and Recyclarr receive no media-disk access.
- Jellyfin receives read-only library access plus read-write config and cache.
- qBittorrent receives torrent-directory access only.
- Radarr and Sonarr receive the media root at `/data` so torrent sources and library destinations share one container mount for hardlinks.
- Bazarr receives only subtitle-relevant library paths.
- The control panel will use a restricted Docker socket proxy, not `/var/run/docker.sock` directly.

ARR deployment captures and verifies unique Sonarr, Radarr, and Prowlarr API keys without placing them in tracked files. The configurable management username and unified password are applied only where verified; Jellyfin viewer accounts remain separate.

## Compose organization

VeinFin uses one top-level `compose.yaml` for the normal stack. This favors a predictable future `docker compose up` installation path and keeps service, network, logging, label, and security contracts visible together.

Exceptional behavior is opt-in through small override files:

- `compose/jellyfin-loopback.yaml` publishes Jellyfin TCP 8096 only on host loopback for temporary SSH-tunnel bootstrap access.
- `compose/qbittorrent-loopback.yaml` publishes qBittorrent TCP 8080 only on host loopback for private SSH-tunnel access.
- `compose/discovery.yaml` publishes Jellyfin UDP auto-discovery only when explicitly included.
- `compose/vpn.example.yaml` is documentation-only and intentionally implements no VPN service or route.

The `proxy` network contains only the reverse proxy and Jellyfin. The `application` network carries required service-to-service traffic and is not published as a host interface. Jellyfin joins both networks. Private web interfaces bind to `MANAGEMENT_BIND_IP`; only the reverse proxy publishes public TCP 443. These Docker networks permit required outbound application traffic and must not be confused with future host-firewall enforcement.

The scaffold has no direct Docker socket mount, privileged container, host networking, fixed container IP, or `container_name`. Bounded JSON-file logging and `no-new-privileges` are applied throughout. HTTPS deployment validated Caddy with an unprivileged user, read-only root filesystem, all capabilities dropped except `NET_BIND_SERVICE`, and protected persistent configuration/certificate storage.

Detailed contracts are in [CONFIGURATION.md](CONFIGURATION.md), [CONTAINERS.md](CONTAINERS.md), [PORTS.md](PORTS.md), and [STORAGE.md](STORAGE.md). Decisions and their consequences are recorded under `docs/decisions/`.

## Import reliability

The planned configuration uses the same `/data` mapping across download and library managers, Completed Download Handling, hardlinks, consistent qBittorrent categories, and compatible permissions. Automated cleanup must never remove an unknown or unimported download. A future reconciliation command will default to dry-run and report failed imports, permission errors, unmatched releases, stuck torrents, and orphaned files.

## Plugins and extensions

Third-party Jellyfin plugins must be reviewed, pinned, installed only through the named supported-plugin component, validated for compatibility, and documented for rollback. Jellyfin Enhanced, Intro Skipper, and AniList are the current immutable allowlist. Plugins that depend on unrestricted injection or direct Jellyfin Web modification remain disabled. Who's Watching was evaluated and deferred because its browser authentication and session integration could not be validated reliably. Its reviewed material is experimental, disabled by default, and excluded from the supported feature set.

The requested Jellyfin catalog is Who's Watching, AniList, AniSearch, AudioDB, Custom Tabs, File Transformation, Home Screen Sections, HoverTrailer, InPlayerEpisodePreview, Intro Skipper, JavaScript Injector, Jellyfin Enhanced, Local Posters, Media Bar Enhanced, MusicBrainz, OMDb, Studio Images, TMDb, and KefinTweaks. Inclusion in this historical catalog does not mean a plugin is installed, compatible, approved, or supported; Who's Watching is explicitly deferred.

The requested Bazarr provider catalog is Gestdown/Addic7ed proxy, Subdl, OpenSubtitles.com, subf2m.co, Embedded Subtitles, Supersubtitles, TVSubtitles, and YIFY Subtitles. Provider accounts and credentials are configured locally and never committed.

Optional VPN credentials are local-only. A VPN route may later be offered as an optional Compose profile; no subscription or credentials are assumed.

## Control panel boundary

The planned private panel will report VeinFin service health and lifecycle controls, applicable visit links, relevant recent logs, CPU and memory use, media usage and health, Jellyfin viewers and transcodes, download and import state, reverse-proxy and certificate status, and available container updates. It will not apply updates automatically, store browser passwords, expose secrets in page source, or receive an unrestricted Docker socket.
