# Deployment components

`install.sh --install` applies the stack as named, resumable components. Each component records a configuration fingerprint and is verified before later work continues.

| Component | Responsibility |
| --- | --- |
| Configuration | Validate settings, generate local secrets, and render protected runtime files. |
| Host | Install the pinned Docker Engine and Compose packages on supported Debian systems. |
| Storage | Verify the operator-provided media root without creating or mounting filesystems. |
| Firewall | Enforce host-input and Docker-forwarding policy with rollback protection. |
| Jellyfin | Deploy the media server with persistent configuration and read-only library access. |
| qBittorrent | Deploy the download client with private management access and categorized paths. |
| ARR services | Deploy and integrate Sonarr, Radarr, and Prowlarr. |
| Media services | Deploy Bazarr, Seerr, FlareSolverr, and the on-demand Recyclarr job. |
| HTTPS | Deploy Caddy and expose Jellyfin on public TCP 443 only. |
| Libraries | Create configured Jellyfin libraries and validate the controlled initial scan. |
| Indexers and subtitles | Configure reviewed public indexers and subtitle-language defaults. |
| Quality profiles | Apply reviewed Recyclarr quality policies. |
| Download lifecycle | Apply seeding, completed-download, hardlink, and fail-safe deletion policy. |
| Control panel | Deploy the private panel and restricted Docker lifecycle agent. |
| Final verification | Verify health, exposure, security boundaries, and component fingerprints. |

The installer does not deploy experimental plugins. It does not manage disks, DNS providers, routers, unrelated services, or operator backups.

## Resume behavior

Every completed component has a root-only marker containing a hash of its relevant configuration and source files. A repeated installation verifies matching components. If an input changes, only the affected component is reapplied and verified.

## Failure behavior

Deployment scripts validate prerequisites before mutation, preserve protected backups where application state changes, and stop on failed post-apply verification. Consult the component-specific document before using a rollback command.
