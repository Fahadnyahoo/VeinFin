# Public Jellyfin HTTPS

HTTPS deployment deploys only the locked Caddy image and exposes Jellyfin through one public TCP 443 listener. DNS and router configuration remain operator-owned and are never changed by VeinFin.

## Interface

```sh
scripts/deploy/https.sh --help
scripts/deploy/https.sh --check --hostname media.example.org
sudo --preserve-env=SSH_CONNECTION scripts/deploy/https.sh --apply --hostname media.example.org
sudo --preserve-env=SSH_CONNECTION scripts/deploy/https.sh --verify
```

`--check` is read-only. It requires the hostname to resolve to the host's current public IPv4, verifies TCP 443 readiness, all eight existing containers, internal Jellyfin health, the installed firewall, the immutable Caddy lock, and resolved Compose hardening.

`--apply` records protected container/listener/rsync baselines, atomically updates the ignored target environment, renders the protected Caddyfile, pulls and starts only Caddy, and enables only public TCP 443 through the rollback-protected firewall transition. It leaves the five-minute rollback armed. Run `--verify` from a separate SSH session before the timer expires.

`--verify` validates the certificate chain, hostname, validity, persistent renewal storage, HTTPS response and headers, arbitrary-Host rejection, exact listener changes, firewall state, empty application state, and all original container fingerprints. It cancels rollback only after those checks pass.

## TLS and proxy contract

Caddy uses public ACME with TLS-ALPN-01 through TCP 443. HTTP-01 and automatic HTTP redirects are explicitly disabled, and HTTP/3 is disabled so UDP 443 is not needed. No DNS API, second proxy, internal CA, or self-signed certificate is configured.

Only the configured hostname routes to `jellyfin:8096` on the private `proxy` network. Caddy's reverse proxy supports Jellyfin's WebSocket upgrades. Responses add HSTS, `nosniff`, and a conservative referrer policy while suppressing the `Server` header. There is no catch-all virtual host.

## Runtime hardening and storage

Caddy runs as upstream UID/GID `1000:1000`, with `no-new-privileges`, a read-only root filesystem, all capabilities dropped, and only `NET_BIND_SERVICE` added. It has no media, application-secret, or Docker-socket mount.

- `${RUNTIME_ROOT}/config/caddy/Caddyfile` is read-only in the container and mode `0600` on the host.
- `${CONFIG_ROOT}/caddy/data` stores ACME account and renewal material persistently.
- `${CONFIG_ROOT}/caddy/config` stores Caddy runtime configuration persistently.
- Host directories are mode `0700`; private key files may not grant group or other access.

The deployment never prints certificate private keys or ACME account data.

## Firewall and exposure

The live firewall update accepts only the transition that enables public TCP 443. Installed management CIDRs, protected LANs, SSH policy, management-port closure, Docker API denial, and container egress restrictions must remain equal. TCP 80, UDP 443, TCP 2375/2376, and all management ports remain blocked from public access. Jellyfin 8096 remains loopback-bound for private administration and is never directly public.

If DNS does not match the current public IPv4, TCP 443 is occupied, certificate issuance fails, or the forwarding path is unavailable, deployment stops without an HTTP, self-signed, alternate-port, or DNS-API fallback. On an interrupted first apply, do not disable the firewall timer; allow rollback, reconnect, diagnose, and rerun the guarded workflow.

HTTPS deployment does not configure libraries, scans, media, indexers, subtitle providers, plugins, Who's Watching, the control panel, hardware transcoding, router settings, DNS records, storage, or Library setup functionality.
