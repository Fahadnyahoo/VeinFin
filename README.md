# VeinFin

VeinFin installs a security-focused Jellyfin media stack on Debian using Docker Compose. It includes Jellyfin, Caddy, qBittorrent, Sonarr, Radarr, Prowlarr, Bazarr, Seerr, FlareSolverr, Recyclarr, and a private service-control panel.

## Install

LAN-only installations use an explicit profile and require no public DNS, ACME,
Caddy, router forwarding, or public hostname:

```sh
./install.sh --generate-config --profile lan-only --input /root/veinfin-lan.env
sudo --preserve-env=SSH_CONNECTION ./install.sh --install --profile lan-only
sudo --preserve-env=SSH_CONNECTION ./install.sh --verify --profile lan-only
```

Public HTTPS remains explicit:

```sh
./install.sh --generate-config --profile public-https --input /root/veinfin-public.env
sudo --preserve-env=SSH_CONNECTION ./install.sh --install --profile public-https
sudo --preserve-env=SSH_CONNECTION ./install.sh --verify --profile public-https
```

Review [the installation guide](docs/INSTALLER.md) and `.env.example` before installing. Both profiles require a supported Debian host, an active SSH session, and an existing mounted media directory. Only `public-https` requires a correctly resolving public hostname.

## Security defaults

- `public-https` exposes only Jellyfin HTTPS on TCP 443; `lan-only` opens no public port.
- Administrative applications and the control panel are restricted to configured management networks.
- Secrets are generated locally and excluded from Git.
- Container images are pinned to reviewed immutable digests.
- The control panel never mounts the Docker socket; a separate restricted agent handles approved lifecycle operations.
- VeinFin never partitions, formats, repairs, or mounts storage and never changes DNS or router settings.
- Twelve reviewed, version-locked Jellyfin 10.11 plugins plus pinned local KefinTweaks assets are installed by the named plugin component; Who's Watching remains disabled and excluded.

## Commands

```sh
./install.sh --help
./install.sh --check
./install.sh --dry-run --profile lan-only
./install.sh --generate-config --profile lan-only --input settings.env
sudo --preserve-env=SSH_CONNECTION ./install.sh --install
sudo --preserve-env=SSH_CONNECTION ./install.sh --verify
```

Installation is resumable and idempotent. Completed components are verified instead of being recreated.

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Installation](docs/INSTALLER.md)
- [Deployment components](docs/DEPLOYMENT.md)
- [Configuration](docs/CONFIGURATION.md)
- [Containers](docs/CONTAINERS.md)
- [Control panel](docs/CONTROL_PANEL.md)
- [Supported Jellyfin plugins](docs/PLUGINS.md)
- [Security](docs/SECURITY.md)
- [Storage](docs/STORAGE.md)
- [Ports](docs/PORTS.md)
- [Image pins](docs/IMAGE_PINS.md)
- [Optional and deferred features](docs/ROADMAP.md)

## Development

Tests are self-contained and do not deploy by default. See [tests/README.md](tests/README.md). Runtime state, credentials, media inventories, and deployment-specific values must never be committed.
