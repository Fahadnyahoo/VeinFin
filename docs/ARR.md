# Sonarr, Radarr, and Prowlarr deployment

Controlled adoption of an existing series after the empty ARR deployment bootstrap is
documented in [`SONARR_ADOPTION.md`](SONARR_ADOPTION.md).

ARR deployment deploys only the locked Sonarr, Radarr, and Prowlarr images alongside the existing Jellyfin and qBittorrent containers. It does not add a torrent, movie, series, indexer, remote path mapping, or FlareSolverr connection and does not scan or import existing media.

## Interface

```sh
scripts/deploy/arr.sh --help
scripts/deploy/arr.sh --check
sudo --preserve-env=SSH_CONNECTION scripts/deploy/arr.sh --apply
sudo --preserve-env=SSH_CONNECTION scripts/deploy/arr.sh --verify
```

`--check` is read-only. It validates the five reviewed image identities, mounted storage and required paths, the two existing healthy services, protected management credentials, qBittorrent's empty bootstrapped state, loopback ports, and resolved Compose model.

`--apply` creates only protected application config directories, pulls and starts only Sonarr, Radarr, and Prowlarr with `--no-deps`, captures their generated API keys, applies Forms authentication, configures the integrations below, and runs the full verifier. A bootstrap or verification failure stops only those three new services.

`--verify` checks exact containers, images, mounts, paths, loopback listeners, authentication, API-key uniqueness, download-client tests, Prowlarr application tests, empty content/indexer state, firewall state, Docker API closure, resource pressure, and a temporary hardlink proof.

## Private access and authentication

The base Compose file publishes none of the three management ports. `compose/arr-loopback.yaml` binds only:

```text
Sonarr    127.0.0.1:8989
Radarr    127.0.0.1:7878
Prowlarr  127.0.0.1:9696
```

Use generic operator-side tunnels such as `ssh -N -L 8989:127.0.0.1:8989 user@host`. Equivalent tunnels apply to ports 7878 and 9696. Visit URLs never contain credentials.

All three applications use Forms authentication with authentication required for every address. Local-address bypass is not enabled. They share the protected management username/password, while their application-generated API keys remain unique and are stored separately as root-readable mode-`0600` files below `${RUNTIME_ROOT}/secrets/`.

## Storage and download clients

Sonarr and Radarr each receive the whole media root as one writable `/data` mount. Prowlarr receives no media mount.

- Sonarr roots: `/data/library/tv` and `/data/library/anime`.
- Radarr root: `/data/library/movies`.
- Sonarr TV client: `qbittorrent:8080`, category `tv`, no tag.
- Sonarr Anime client: `qbittorrent:8080`, category `anime`, restricted by the `anime` tag.
- Radarr client: `qbittorrent:8080`, category `movies`.

Completed Download Handling and hardlinks instead of copies are enabled. No remote path mapping exists because qBittorrent, Sonarr, and Radarr agree on `/data` paths.

Completed-download removal support does not authorize deletion of unknown or unimported data. Removal is safe only after an import succeeds and qBittorrent reports the configured seed policy complete. A torrent payload may remain visible under `/data/torrents` while seeding; when the imported library file is a hardlink, that second path does not consume a second full copy of the file.

Download lifecycle setup's intended proof is described in [`DOWNLOAD_LIFECYCLE.md`](DOWNLOAD_LIFECYCLE.md), but the controlled validation did not complete and its API changes were rolled back. The Download lifecycle setup failed-download removal setting is therefore not presented as deployed.

## Prowlarr applications

Prowlarr has exactly two application connections:

- Sonarr at `http://sonarr:8989` using Sonarr's unique API key.
- Radarr at `http://radarr:7878` using Radarr's unique API key.

Both connection tests pass. No indexer or FlareSolverr proxy is configured.

## Hardlink and resource validation

Verification creates a uniquely named test directory beneath each of `${MEDIA_ROOT}/torrents` and `${MEDIA_ROOT}/library`, links one temporary file between them, proves matching device and inode values, proves source edits through the link, and removes both directories. It never reads or changes real media.

The verifier rejects less than 512 MiB available host memory or more than 512 MiB used swap. On that failure, apply stops only the three ARR deployment services. VeinFin's broader recommendation remains at least 12 GiB RAM for the complete future stack.

## Upstream contracts

API requests are built from the live schemas provided by the exact locked applications. Authentication and integration behavior follow the official [Sonarr settings documentation](https://github.com/Servarr/Wiki/blob/master/sonarr/settings.md), [Prowlarr settings documentation](https://github.com/Servarr/Wiki/blob/master/prowlarr/settings.md), and official [Radarr OpenAPI definition](https://github.com/Radarr/Radarr/blob/develop/src/Radarr.Api.V3/openapi.json). Image provenance remains recorded in `docs/IMAGE_PINS.md`.
