# Bazarr, Seerr, Recyclarr, and FlareSolverr deployment

Media services adds only Bazarr, Seerr, and FlareSolverr as long-running services. Recyclarr remains an on-demand validation job. It does not add subtitle providers, indexers, requests, media, downloads, torrents, or Recyclarr profile choices.

## Interface

```sh
scripts/deploy/media-services.sh --help
scripts/deploy/media-services.sh --check
sudo --preserve-env=SSH_CONNECTION scripts/deploy/media-services.sh --apply
sudo --preserve-env=SSH_CONNECTION scripts/deploy/media-services.sh --verify
```

`--check` is non-mutating. It validates the existing five services, all nine intended image locks, storage readiness, protected credentials, exact Compose model, and loopback-only override.

`--apply` completes the pending Jellyfin wizard without adding a library, pulls only the four Media services images, starts only Bazarr, Seerr, and FlareSolverr, configures their authenticated internal connections, generates Recyclarr configuration atomically, runs only the official `sync --preview`, and invokes the full verifier. Repeated application is idempotent. A critical memory/swap failure stops only the three newly added long-running services.

`--verify` proves exactly eight healthy long-running containers and nine locked images; preservation of the original five container identities, start times, and restart counts; empty application state; exact mounts and bindings; API-key uniqueness; firewall state; closed Docker TCP API; and an unchanged external rsync process identity.

## Private access

The base services publish no ports. `compose/media-services-loopback.yaml` binds Bazarr at `127.0.0.1:6767` and Seerr at `127.0.0.1:5055`. A generic operator tunnel is:

```sh
ssh -N -L 6767:127.0.0.1:6767 -L 5055:127.0.0.1:5055 user@host
```

FlareSolverr has no published port. Its `http://flaresolverr:8191` endpoint is reachable only on the application network. Prowlarr receives exactly one proxy with a dedicated `flaresolverr` tag and has zero indexers.

## Application contracts

- Jellyfin is named `VeinFin`, uses English and the configured country, has exactly one administrator, and has zero libraries. Media services does not start a library scan.
- Bazarr receives only the movie, TV, and anime library subtrees. It uses Forms authentication, connects to `sonarr:8989` and `radarr:7878`, has no subtitle provider, and has zero wanted/history activity.
- Seerr receives only its configuration mount. It connects to `jellyfin:8096`, `sonarr:8989`, and `radarr:7878`, uses the exact established root folders, disables automatic sync/search behavior, imports no additional users, and has zero requests.
- Each application API key is unique and stored in a root-readable mode-`0600` file. Secret values and credential-bearing URLs are never logged.

The upstream FlareSolverr image declares an anonymous `/config` volume. Compose supplies no bind, named volume, media, torrent, secret, or Docker-socket mount; runtime verification permits only that exact image-declared anonymous volume. The container is otherwise unprivileged, uses no host networking or added capability, and remains host-unpublished.

## Recyclarr safety

`${RUNTIME_ROOT}/config/recyclarr` is mode `0700`; generated `recyclarr.yml` is mode `0600` and written by atomic replacement. Upstream Recyclarr stores required state under `/config`, so that protected mount is writable. `${CONFIG_ROOT}/recyclarr:/data` holds regenerable resources and logs. The root filesystem stays read-only and no media, torrent, or Docker socket is mounted.

Media services runs only `sync --preview` against `http://sonarr:8989` and `http://radarr:7878`. It does not select or apply quality profiles, custom formats, naming rules, scores, or real synchronization.

## Recovery and boundaries

After interruption, rerun `--check`, then `--apply`; atomic secret/config writes and idempotent API reconciliation preserve completed work. Use `--verify` after stabilization. The resource guard requires at least 512 MiB available memory and rejects more than 512 MiB used swap; VeinFin still recommends at least 12 GiB RAM for the full future stack.

Media services does not deploy Caddy, public HTTPS, DNS changes, the control panel, Who's Watching, plugins, subtitle providers, indexers, content, requests, downloads, or any HTTPS deployment work. It does not inspect or modify real media or control the operator's external copy process.
