# Jellyfin deployment

Library setup library creation and controlled-scan behavior is documented in
[`LIBRARIES.md`](LIBRARIES.md). The material below describes the original
Jellyfin deployment container deployment and remains the runtime foundation.

Jellyfin deployment deploys only the locked official Jellyfin image. Caddy and every download, automation, request, indexing, subtitle, plugin, and control-panel service remain absent.

## Interface

Run from a clean target-local repository snapshot:

```sh
scripts/deploy/jellyfin.sh --help
scripts/deploy/jellyfin.sh --check
sudo --preserve-env=SSH_CONNECTION scripts/deploy/jellyfin.sh --apply
sudo --preserve-env=SSH_CONNECTION scripts/deploy/jellyfin.sh --verify
```

`--check` creates only a restrictive temporary environment file and removes it before returning. It checks Docker and Compose, the image lock, the dedicated loopback override, storage mount readiness, required library directory entries, config-root safety, existing container/image scope, TCP 8096 availability, and resolved Compose configuration.

`--apply` detects the invoking SSH user's numeric UID/GID, creates the Jellyfin config and cache directories, writes a root-owned mode-`0600` local `.env`, validates Compose, pulls only Jellyfin, and runs only `jellyfin` with `--no-deps`. Repeated execution preserves application state and converges on the same container contract.

`--verify` proves that the single container is the expected Compose service using the locked image; it is running and healthy; config/cache are writable; the library is read-only; no torrent, GPU, or Docker-socket mount exists; TCP 8096 is loopback-only; unrelated ports and the Docker TCP API remain closed; the media root remains a read-write host mount; and the firewall setup firewall still verifies.

The first apply atomically records a mode-`0600` listener baseline under ignored runtime state. Later applies preserve it. Verification removes the expected Jellyfin listener and, when the qBittorrent deployment qBittorrent container exists, its exact loopback listener; it still rejects every unrelated listener change.

## Bootstrap access

The base Compose file publishes no Jellyfin port. `compose/jellyfin-loopback.yaml` is an explicit bootstrap-only override binding TCP 8096 to `127.0.0.1`. A later Caddy deployment omits this override.

Use an SSH tunnel from an operator workstation:

```sh
ssh -N -L 8096:127.0.0.1:8096 user@host
```

Then open `http://127.0.0.1:8096` locally when the initial setup process is authorized. Do not use a LAN address, wildcard bind, host networking, router mapping, or public firewall rule.

## Storage and identity

The target contract is:

- application config: `${CONFIG_ROOT}/jellyfin/config:/config` read-write;
- application cache: `${CONFIG_ROOT}/jellyfin/cache:/cache` read-write;
- media: `${MEDIA_ROOT}/library:/data/library` read-only;
- no torrent mount;
- no render device while hardware transcoding remains disabled.

The runtime UID/GID is detected on the target and stored only in the ignored target-local environment. No operator UID/GID is committed.

## Deliberate limits

The workflow does not create a Jellyfin administrator or password, complete the setup wizard, create libraries, initiate a media scan, install plugins, enable discovery or hardware transcoding, configure Caddy/HTTPS, or start another service. An active external media copy must remain untouched; directory readiness checks use only explicit `test -d` operations and never enumerate library contents.
