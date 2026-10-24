# Container contract

Every image is locked to a reviewed stable release tag plus immutable multi-architecture manifest digest. Floating tags are prohibited; the authoritative values and update procedure are in [IMAGE_PINS.md](IMAGE_PINS.md) and `config/images.lock`.

| Compose service | Image repository | Tag variable | Provenance/rationale |
| --- | --- | --- | --- |
| reverse-proxy | `caddy` | `CADDY_IMAGE_TAG` | Official Caddy image; focused automatic HTTPS reverse proxy. |
| jellyfin | `jellyfin/jellyfin` | `JELLYFIN_IMAGE_TAG` | Official Jellyfin image; minimizes intermediary packaging. |
| qbittorrent | `lscr.io/linuxserver/qbittorrent` | `QBITTORRENT_IMAGE_TAG` | LinuxServer supplies consistent non-root `PUID`/`PGID`, `TZ`, and `UMASK` conventions. |
| sonarr | `lscr.io/linuxserver/sonarr` | `SONARR_IMAGE_TAG` | LinuxServer consistency across the media-writing applications. |
| radarr | `lscr.io/linuxserver/radarr` | `RADARR_IMAGE_TAG` | LinuxServer consistency across the media-writing applications. |
| prowlarr | `lscr.io/linuxserver/prowlarr` | `PROWLARR_IMAGE_TAG` | LinuxServer consistency with Sonarr/Radarr administration. |
| bazarr | `lscr.io/linuxserver/bazarr` | `BAZARR_IMAGE_TAG` | LinuxServer identity and permissions conventions for subtitle writes. |
| seerr | `ghcr.io/seerr-team/seerr` | `SEERR_IMAGE_TAG` | Upstream project image. |
| recyclarr | `ghcr.io/recyclarr/recyclarr` | `RECYCLARR_IMAGE_TAG` | Upstream project image; modeled as an explicit one-shot profile. |
| flaresolverr | `ghcr.io/flaresolverr/flaresolverr` | `FLARESOLVERR_IMAGE_TAG` | Upstream project image; private application-network endpoint only. |
| veinfin-panel | Local reproducible build | Generated immutable image ID | Minimal standard-library Python panel; never receives the Docker socket. |
| veinfin-agent | Same local reproducible build | Generated immutable image ID | Restricted, unexposed Docker lifecycle adapter with a compiled service allowlist. |

The panel build base is locked by digest as `PANEL_BUILD_BASE` in `config/images.lock`. Control panel setup builds it twice with normalized timestamps, requires identical image IDs, and records the selected ID only in ignored deployment state. Experimental plugin material is excluded from the default installer unless a separate acceptance process explicitly promotes it to the supported feature set.

Repository provenance is checked against official project releases and registries. Every lock review must repeat that check, confirm a stable release, and verify that the multi-architecture manifest includes Linux amd64.

## Runtime policy

- Long-running services use `restart: unless-stopped`; Recyclarr is an explicit one-shot exception.
- All scaffolded services use bounded `json-file` logs.
- `init: true` is enabled where the image does not provide its own init. The LinuxServer qBittorrent image is an explicit exception because its s6 overlay must remain PID 1.
- `no-new-privileges:true` is applied to all services.
- The reverse proxy and Recyclarr have read-only root filesystems with explicit writable mounts/tmpfs. Recyclarr's protected `/config` mount is writable because upstream stores required state beside its configuration.
- No service is privileged or uses host networking, a fixed IP, a `container_name`, or embedded credentials. Only the restricted, unexposed lifecycle agent mounts the Docker socket; the panel never does.
- Dependencies use health readiness only where traffic is immediately required; no arbitrary sleeps are present.

## Health contract

The Compose health checks are candidates to be validated against the exact locked images. They do not prove application integration or authentication readiness.

| Service | Candidate signal | Open validation |
| --- | --- | --- |
| Caddy | `caddy version` plus external HTTPS/certificate validation | Validated with the locked image during HTTPS deployment. |
| Jellyfin | HTTP `/health` | Validated with the locked 12.3 image during Jellyfin deployment. |
| qBittorrent | Web root responds | Validated with the locked 5.3.0 LinuxServer image during qBittorrent deployment; authenticated API verification is performed by the deployment script. |
| Sonarr/Radarr/Prowlarr | HTTP `/ping` | Validated with the locked images during ARR deployment; authenticated API verification proves integration readiness. |
| Bazarr | Web root responds | Validated with the locked image during Media services; authenticated API verification proves configuration readiness. |
| Seerr | HTTP `/api/v1/settings/public` | Validated with the locked image during Media services. |
| FlareSolverr | HTTP `/` | Validated as lightweight liveness during Media services; the service remains host-unpublished. |
| Recyclarr | Process exit code | `sync --preview` is validated on demand; it is not a daemon and Media services does not apply profiles. |

The installer renders and statically validates the resolved configuration. Runtime health, hardening, and least-privilege compatibility are validated only when each service's deployment operation is authorized.
