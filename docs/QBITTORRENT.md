# qBittorrent-only deployment

qBittorrent deployment deploys and bootstraps only the locked LinuxServer qBittorrent image alongside the existing Jellyfin container. It does not add torrents, configure RSS/search plugins, publish a peer port, enable VPN routing, or start an automation service.

## Interface

```sh
scripts/deploy/qbittorrent.sh --help
scripts/deploy/qbittorrent.sh --check
sudo --preserve-env=SSH_CONNECTION scripts/deploy/qbittorrent.sh --apply
sudo --preserve-env=SSH_CONNECTION scripts/deploy/qbittorrent.sh --verify
```

`--check` is read-only. It validates Docker/Compose, the existing Jellyfin container, exact image locks, storage readiness, safe roots, target-local credential state, TCP 8080 availability, the loopback override, and resolved Compose configuration.

`--apply` creates only the qBittorrent config directory and required torrent directories, preserves or securely generates the shared management password, pulls only qBittorrent, and starts only `qbittorrent` with `--no-deps`. It captures the first-start temporary password into a protected transient file without displaying it, uses the authenticated Web API to apply the configured username/password and settings, creates the three categories, recreates only qBittorrent to discard the old container log, and verifies that obsolete/default authentication fails. Repeated apply preserves the same password and state.

`--verify` proves the exact two-container contract, image identities, health, mounts, paths, categories, empty torrent list, authentication protections, absence of peer-port publication, loopback listener delta, Docker API closure, and firewall state.

The LinuxServer image supplies s6-overlay as its own PID 1. The qBittorrent service therefore deliberately omits Docker's separate `init: true`; enabling both prevents this locked image from starting.

## Private access

The base Compose service publishes no qBittorrent port. `compose/qbittorrent-loopback.yaml` binds only host `127.0.0.1:8080` to container TCP 8080. Use an operator-side tunnel:

```sh
ssh -N -L 8080:127.0.0.1:8080 user@host
```

Open `http://127.0.0.1:8080` locally. URLs never contain credentials. No TCP/UDP peer port is host-published, and UPnP/NAT-PMP is disabled.

## Authentication lifecycle

The configured `MANAGEMENT_USERNAME` and `${RUNTIME_ROOT}/secrets/management-password` are shared with applications that support this verified login contract. The password file, credential summary, bootstrap state, generated `.env`, API cookies, and bootstrap request bodies use restrictive permissions. Temporary cookies and first-start credentials exist only in a root-only `/run` directory and are deleted when the command exits.

Normal repeated apply never rotates the password. Rotation remains an explicit installer action. To propagate an intentionally rotated password to an existing qBittorrent, retain the prior value in a root-readable mode-`0600` file and use:

```sh
sudo --preserve-env=SSH_CONNECTION scripts/deploy/qbittorrent.sh --apply \
  --previous-password-file /path/to/protected-previous-password
```

Only the path, never the password, is supplied as an argument. Remove the operator-managed previous-password file after successful verification.

## Storage and categories

The exact container mounts are:

- `${CONFIG_ROOT}/qbittorrent:/config` read-write;
- `${MEDIA_ROOT}/torrents:/data/torrents` read-write.

qBittorrent receives no library path. The configured paths are:

```text
default       /data/torrents
incomplete    /data/torrents/incomplete
movies        /data/torrents/movies
tv            /data/torrents/tv
anime         /data/torrents/anime
```

The categories map `movies`, `tv`, and `anime` to the matching paths. This preserves the shared `/data` namespace required by future Sonarr/Radarr hardlinks without granting qBittorrent library access. Automatic watch folders, RSS processing, automatic tracker injection, and automatic deletion actions remain disabled.

Download lifecycle setup's intended share-limit and cleanup policy is documented in [`DOWNLOAD_LIFECYCLE.md`](DOWNLOAD_LIFECYCLE.md), but it is not deployed or supported yet. The controlled validation rolled its settings back after the synthetic fixture gate failed.

## Verified upstream contracts

The bootstrap uses the official [qBittorrent WebUI API](https://github.com/qbittorrent/qBittorrent/wiki/WebUI-API-%28qBittorrent-5.0%29) for cookie authentication, preferences, categories, version, and the empty torrent list. First-start temporary-password behavior and container variables follow the official [LinuxServer qBittorrent image documentation](https://docs.linuxserver.io/images/docker-qbittorrent/). Image provenance and digest review remain recorded in `docs/IMAGE_PINS.md`.

The locked qBittorrent 5.3 build returns HTTP `204` plus a port-scoped SID cookie for successful login, rather than the documented HTTP `200` response body. The bootstrap accepts either authenticated login response shape but still requires the session cookie. Mutating API calls must return the documented HTTP `200` status.
