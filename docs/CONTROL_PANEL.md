# Private control panel

Control panel setup deploys two small custom containers. `veinfin-panel` serves the private responsive dashboard on TLS port `3000`; `veinfin-agent` is an unexposed lifecycle adapter on a separate internal Docker network. Only the agent mounts `/var/run/docker.sock`. The panel has no socket mount and cannot address Docker directly.

The agent compiles an exact allowlist for Caddy, Jellyfin, qBittorrent, Sonarr, Radarr, Prowlarr, Bazarr, Seerr, FlareSolverr, and the on-demand Recyclarr container. It accepts only status/stats, start, stop, and restart. Runtime Compose project/service labels must also match. Panel and agent are deliberately absent from the allowlist. There are no create, delete, exec, shell, image, volume, network, Compose, log, or arbitrary-container endpoints.

## Authentication

The existing management username and password are reused. The panel mounts only a salted PBKDF2-HMAC-SHA256 password hash with 600,000 iterations; it never receives the plaintext password. The browser sends the plaintext only in the normal TLS login request. Sessions are memory-only, expire after eight hours, and use a `Secure`, `HttpOnly`, `SameSite=Strict`, host-only cookie. State-changing calls require a session-specific CSRF token and exact Origin. Login failures are rate-limited. Logout invalidates the server-side session.

The panel uses a generated private TLS key and self-signed management certificate because the private LAN endpoint is not the public Jellyfin hostname. Operators may explicitly trust that local certificate. Visit URLs never contain credentials. Jellyfin opens through its configured public HTTPS hostname; qBittorrent, Sonarr, Radarr, Prowlarr, Bazarr, and Seerr use their configured private host and port. Caddy, FlareSolverr, the agent, and Recyclarr have no Visit button.

## Exposure and hardening

The panel and management application ports bind to the configured specific LAN address and remain available on loopback for protected host verification. The Docker-aware firewall permits them only from configured management CIDRs. Public exposure remains Caddy TCP `443`; TCP `80`, UDP `443`, FlareSolverr `8191`, the agent `9000`, and Docker API ports remain unavailable.

Both custom containers use the same locally built immutable image ID, run as UID/GID `65532`, drop all capabilities, set `no-new-privileges`, and use read-only root filesystems with small temporary filesystems. The agent receives only the Docker socket group as a supplemental group. The panel-agent network is internal; a separate panel-only bridge exists solely so Docker can publish the allowlisted management port.

## Deployment and recovery

```sh
scripts/deploy/control-panel.sh --check
sudo --preserve-env=SSH_CONNECTION scripts/deploy/control-panel.sh --apply
sudo --preserve-env=SSH_CONNECTION scripts/deploy/control-panel.sh --verify
```

Apply protects the existing environment, firewall configuration, installed firewall helper, and container baseline under ignored root-only runtime backup state. It builds twice with normalized timestamps and refuses non-identical results. The management-only firewall transition retains the timed rollback gate. Verify authenticates the panel, rejects an invalid password and CSRF token, checks the exact inventory and credential-free links, and performs one controlled FlareSolverr restart on first completion. Repeated apply and verify are read-only.

The reviewed Python build base is pinned in `config/images.lock`. The generated local image ID, password hash, agent secret, TLS key, certificate, rendered environment, backups, resource record, and completion markers are ignored deployment state. Experimental plugins are not included.
