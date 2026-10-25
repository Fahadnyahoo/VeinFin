# VeinFin security model

## Exposure policy

The default is closed unless access is explicitly required.

| Endpoint | Expected exposure | Notes |
| --- | --- | --- |
| Reverse proxy, TCP 443 | Public | Sole public VeinFin ingress; HTTPS deployment terminates trusted HTTPS with Caddy. |
| Jellyfin, TCP 8096 | Internal or host-loopback bootstrap only | Base Compose publishes nothing; the dedicated bootstrap override binds only `127.0.0.1` for an SSH tunnel. |
| Sonarr 8989, Radarr 7878, Prowlarr 9696 | Host loopback and allowlisted LAN management | Control panel setup adds specific-address publications protected by source CIDRs. |
| Bazarr 6767 | Host loopback and allowlisted LAN management | Forms authentication remains required. |
| qBittorrent Web UI, TCP 8080 | Host loopback and allowlisted LAN management | No peer port is published. |
| Seerr management, TCP 5055 | Host loopback and allowlisted LAN management | Private only. |
| VeinFin control panel, TCP 3000 | Allowlisted LAN management | TLS, authenticated sessions, CSRF, exact Origin, and rate limiting. |
| FlareSolverr, TCP 8191 | Required container network only | Internal service port; no host port. |
| Recyclarr | No inbound UI exposure | Configuration-only service. |
| Docker API/socket proxy, including 2375/2376 | Required internal consumers only | Never public; expose minimum operations. |

VeinFin does not create router mappings or manage DNS. Compose binding cannot enforce source-client allowlists; the host firewall enforces target-local management CIDRs before management ports may be enabled.

Docker creates packet-filtering and forwarding rules for bridge networking. Published container ports can bypass ordinary host-firewall input-rule assumptions, so VeinFin filters forwarded traffic first through a dedicated chain linked from `DOCKER-USER`. Host input and Docker forwarding default closed; public HTTPS and management forwarding require separate explicit flags. Container-initiated traffic to protected IPv4 and connected IPv6 LAN prefixes is denied while internet replies and required Docker-internal traffic remain available. Docker administration remains on the local Unix socket through `sudo`; ports 2375 and 2376 stay closed. See [FIREWALL.md](FIREWALL.md).

## Secrets

- Commit `.env.example`, never a populated `.env`.
- The installer generates installation-specific secrets, validates required values, and applies permission mode `600` to `.env`.
- Passwords, tokens, application API keys, provider credentials, VPN keys, private keys, TLS private keys, and secret-bearing generated configuration are never committed or printed.
- The installer generates one human-facing management password. The qBittorrent deployment bootstrap applies it to qBittorrent without exposing the first-start temporary password; any service-specific stored hash is application-managed.
- Application API keys are absent until a verified bootstrap creates or captures them. Once real keys exist, they remain unique per application.
- URLs do not contain passwords. Browser password managers may handle ordinary login forms.
- The control panel mounts only a strong salted password hash and generated agent/session-channel secret. It never exposes credentials in page source, Visit URLs, labels, or logs.
- Third-party plugin repositories receive no unrelated secrets, and uncontrolled automatic plugin updates are prohibited.

Generated secret directories use mode `0700`; individual secret files and the credential summary use mode `0600`. Existing secrets are preserved during normal and `--force` configuration regeneration. Rotation occurs only with `--rotate-secrets`. Writes use a same-directory temporary file followed by atomic replacement, so an interruption cannot expose a truncated final file. A later rerun safely replaces any incomplete generation attempt.

Noninteractive `--input` and `--set` accept non-secret settings only. They reject generated and provider secret keys, avoiding command-line or shell-source exposure. Secret values are never written to installer logs.

## Least privilege

Container networks and volumes are scoped to actual service needs. Media access follows the matrix in [ARCHITECTURE.md](ARCHITECTURE.md). The control panel has no Docker socket. Its separate unexposed agent validates a compiled service allowlist plus runtime Compose labels and permits only status, stats, start, stop, and restart. Neither component can manage itself, and no arbitrary Docker endpoint is proxied.

Third-party Jellyfin modifications require review, pinned releases, archive and extracted-file hashes, staged compatibility testing, and protected rollback. Only entries in `config/plugins.lock` plus the exact `config/legacy-ui-assets.lock` asset are supported; the installer accepts no arbitrary repository URL. The supported legacy UI deliberately uses reviewed Jellyfin Web transformation and local script injection, blocks external script URLs, and documents its increased security and upgrade risk. Who's Watching remains excluded and unsupported.

## Storage safety

VeinFin validates the operator-provided media root but never formats, partitions, repairs, or automatically mounts storage.

Unknown or unimported downloads are never deleted automatically. Cleanup and reconciliation must offer dry-run behavior and require evidence that import and any configured seed policy completed successfully.

## Incident-safe operation

Updates are reported but not applied automatically. Releases and images use controlled version variables rather than unbounded `latest` tags. Lifecycle operations should be idempotent, auditable, and reversible, with health validation and documented rollback before broad plugin or application changes.
