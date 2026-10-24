# Network and port contract

Publishing a Docker port and authorizing traffic through the host firewall are separate decisions. HTTPS deployment enables only Caddy's public TCP 443 path; it does not change the router or DNS provider.

Binding a management port to `MANAGEMENT_BIND_IP` cannot enforce which remote clients may connect. Control panel setup enables the Docker-aware firewall's management policy so only configured `MANAGEMENT_ALLOWED_CIDRS` may reach those publications.

| Service | Container port | Host binding in base Compose | Class | Contract |
| --- | ---: | --- | --- | --- |
| HTTPS reverse proxy | TCP 443 | `0.0.0.0:443` from ignored target configuration | Public | Only public VeinFin port; TCP 80 and UDP 443 remain closed. |
| Jellyfin HTTP | TCP 8096 | None in base Compose; optional `127.0.0.1:8096` bootstrap override | Docker-internal or host-loopback only | Reverse proxy reaches `jellyfin:8096`; temporary direct access requires an SSH tunnel. |
| qBittorrent Web UI | TCP 8080 | None in base Compose; optional `127.0.0.1:8080` bootstrap override | Host-loopback only | Private SSH tunnel; no password in Visit URL. |
| Sonarr | TCP 8989 | None in base Compose; ARR deployment override uses `127.0.0.1:8989` | Host-loopback only | Private SSH tunnel. |
| Radarr | TCP 7878 | None in base Compose; ARR deployment override uses `127.0.0.1:7878` | Host-loopback only | Private SSH tunnel. |
| Prowlarr | TCP 9696 | None in base Compose; ARR deployment override uses `127.0.0.1:9696` | Host-loopback only | Private SSH tunnel; Media services configures its internal FlareSolverr proxy. |
| Bazarr | TCP 6767 | None in base Compose; Media services override uses `127.0.0.1:6767` | Host-loopback only | Private SSH tunnel. |
| Seerr | TCP 5055 | None in base Compose; Media services override uses `127.0.0.1:5055` | Host-loopback only | Private SSH tunnel. |
| Recyclarr | None | None | Docker-internal | One-shot profile, no web interface. |
| FlareSolverr | TCP 8191 | None | Docker-internal | Application network only. |
| Jellyfin auto-discovery | UDP 7359 | Optional discovery override | Optional LAN discovery | Disabled unless override is explicitly included. |
| Jellyfin DLNA/SSDP | UDP 1900 | None | Unresolved optional discovery | Bridge-mode multicast compatibility requires later testing. |
| VeinFin control panel | TCP 3000 | Specific management address plus loopback | Private allowlisted management | TLS dashboard; never public. |
| HTTP redirect/challenge | TCP 80 | None | Disabled by default | Must not be published without a later reviewed requirement. |
| Restricted lifecycle agent | TCP 9000 | None | Internal `control` network only | Only agent mounts the Unix socket; no host publication. |
| Docker API | TCP 2375/2376 | None | Closed | Unix socket exists only on the restricted agent. |

qBittorrent peer-listening ports are not published or mapped by the current VeinFin design. DNS and router configuration remain outside VeinFin.

## Networks

| Network | Members | Purpose |
| --- | --- | --- |
| `proxy` | reverse-proxy, Jellyfin | Public HTTPS ingress to Jellyfin without publishing 8096. |
| `application` | Jellyfin and services needing application communication | Name-based private service traffic and required outbound access. |
| `control` | control panel, restricted lifecycle agent | Internal panel-to-agent traffic only. |
| `panel-ingress` | control panel only | Docker publication path for allowlisted private TCP 3000. |

Services have no fixed container addresses. The application network is not marked Docker `internal: true` because indexers, metadata services, download clients, certificate flows, and update checks require outbound connectivity. “Internal-only” means it is not a published host endpoint.
