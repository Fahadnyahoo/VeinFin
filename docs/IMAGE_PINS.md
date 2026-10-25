# Image pin policy

VeinFin uses an explicit release tag plus the immutable digest of its multi-architecture manifest. This keeps the human-readable upstream version while ensuring that a registry tag change cannot silently alter an installation.

## Verified lock

Verification date: 2026-10-24. Every manifest listed below included Linux amd64.

| Service | Repository | Version | Manifest digest | Official source |
| --- | --- | --- | --- | --- |
| Caddy | `caddy` | `2.11.7-alpine` | `sha256:eb4d35b7452d1ab6171fbdbe8d9275b2301dad6dad92115d91e19fb9b24d510f` | Caddy release and Docker Hub official image |
| Jellyfin | `jellyfin/jellyfin` | `10.11.11` | `sha256:aefb67e6a7ff1debdd154a78a7bbb780fd0c873d8639210a7f6a2016ad2b35db` | Jellyfin release and Docker Hub official image |
| qBittorrent | `lscr.io/linuxserver/qbittorrent` | `5.3.0_v2.1.2-ls484` | `sha256:e887804fa9de4c60f5f0fb1f3a7e4febe40a8f69fe736f70c4e8589b1f868dab` | LinuxServer registry image labels and manifest |
| Sonarr | `lscr.io/linuxserver/sonarr` | `4.0.20.3014-ls1` | `sha256:889dcc58c6aea859033985894b519b2e6b1e55d92527ed123f9f52e42ae7c97b` | LinuxServer registry image labels and manifest |
| Radarr | `lscr.io/linuxserver/radarr` | `6.4.4.10685-ls323` | `sha256:fc0ae3c50f8128b97e84381903ec8d6845c3a569641cb7117c124376cccb57c1` | LinuxServer registry image labels and manifest |
| Prowlarr | `lscr.io/linuxserver/prowlarr` | `2.6.5.5623-ls165` | `sha256:b3b00047ed20f6ce2b16780145cb6a0acb51c9e28ea6aa6f5dcd33c7034f1797` | LinuxServer registry image labels and manifest |
| Bazarr | `lscr.io/linuxserver/bazarr` | `v1.6.2-ls369` | `sha256:946dc8c5bb5331418eac60050cf40a63cb8f66ac039841dda493870e3559799c` | LinuxServer registry image labels and manifest |
| Seerr | `ghcr.io/seerr-team/seerr` | `v3.5.1` | `sha256:d8fab675b55ad293ded98fd71efcfd46054cbad9746534ae1cc4794a88c0b3be` | Seerr release and GHCR manifest |
| Recyclarr | `ghcr.io/recyclarr/recyclarr` | `8.8.0` | `sha256:b1fbb929ba718fdbdac2c1fc25b32b0ae916d7a5a0892c2068c9bfae6f1a9209` | Recyclarr release and GHCR manifest |
| FlareSolverr | `ghcr.io/flaresolverr/flaresolverr` | `v3.5.2` | `sha256:c80ae007ce2ccdcd217a12426e4f039ef763ff90738c808d38810c3e59323767` | FlareSolverr release and GHCR manifest |
| Panel build base | `python` | `3.13.17-alpine3.24` | `sha256:fa0bb0d0cd7c7d6cef30a69094d32ac2b71c7304c87c6107fec100e1ee4eda02` | Docker Official Image registry |

The machine-readable copy is `config/images.lock`. Static tests require the lock, `.env.example`, and Compose references to agree. `scripts/verify-image-lock.rb` performs a non-mutating registry check and reports tag digest drift or loss of Linux amd64 support; it never updates the lock.

The panel base was verified on 2026-10-24. Control panel setup performs two independent no-network builds with normalized timestamps and requires identical image IDs. The panel and agent then use that local immutable image ID; no floating custom tag is accepted at runtime.

Official release sources reviewed on 2026-10-23:

- [Caddy releases](https://github.com/caddyserver/caddy/releases) and [Docker Official Image tags](https://hub.docker.com/_/caddy/tags)
- [Jellyfin 10.11.11 release](https://github.com/jellyfin/jellyfin/releases/tag/v10.11.11) and [official container tags](https://hub.docker.com/r/jellyfin/jellyfin/tags)
- LinuxServer releases for [qBittorrent](https://github.com/linuxserver/docker-qbittorrent/releases), [Sonarr](https://github.com/linuxserver/docker-sonarr/releases), [Radarr](https://github.com/linuxserver/docker-radarr/releases), [Prowlarr](https://github.com/linuxserver/docker-prowlarr/releases), and [Bazarr](https://github.com/linuxserver/docker-bazarr/releases), with manifests from the official LinuxServer registry
- [Seerr releases](https://github.com/seerr-team/seerr/releases), [Recyclarr releases](https://github.com/recyclarr/recyclarr/releases), and [FlareSolverr releases](https://github.com/FlareSolverr/FlareSolverr/releases), with manifests from each project's official GHCR namespace

Sonarr's stable rebuild sequence intentionally reset from `4.0.20.3014-ls329` to `4.0.20.3014-ls1`. The selected `ls1` release is the newer official stable rebuild published on 2026-10-20, not the historical first rebuild.

## Review and update procedure

Updates are never automatic. A maintainer must:

1. Review the official project release and migration/security notes.
2. Confirm the tag in the project's official registry.
3. Inspect the multi-architecture manifest and confirm Linux amd64 support.
4. Record the exact manifest digest and verification date.
5. Update `config/images.lock` and the matching `.env.example` value together.
6. Run `scripts/verify-image-lock.rb` and all repository tests, then validate health and rollback only in an authorized deployment environment.

The installer validates exact lock equality but never checks for or applies image updates automatically.
