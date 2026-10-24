# VeinFin

VeinFin installs a security-focused Jellyfin media stack on Debian using Docker Compose. It includes Jellyfin, Caddy, qBittorrent, Sonarr, Radarr, Prowlarr, Bazarr, Seerr, FlareSolverr, Recyclarr, and a private service-control panel.

## Install

```sh
git clone <repository-url>
cd VeinFin
./install.sh --generate-config
sudo --preserve-env=SSH_CONNECTION ./install.sh --install
sudo --preserve-env=SSH_CONNECTION ./install.sh --verify
```

Review [the installation guide](docs/INSTALLER.md) and `.env.example` before installing. The operator must provide a supported Debian host, a correctly resolving public hostname, an active SSH session, and an existing mounted media directory.

## Security defaults

- Public exposure is limited to Jellyfin over HTTPS on TCP 443.
- Administrative applications and the control panel are restricted to configured management networks.
- Secrets are generated locally and excluded from Git.
- Container images are pinned to reviewed immutable digests.
- The control panel never mounts the Docker socket; a separate restricted agent handles approved lifecycle operations.
- VeinFin never partitions, formats, repairs, or mounts storage and never changes DNS or router settings.
- Experimental plugins are disabled and excluded from installation.

## Commands

```sh
./install.sh --help
./install.sh --check
./install.sh --dry-run
./install.sh --generate-config
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
- [Security](docs/SECURITY.md)
- [Storage](docs/STORAGE.md)
- [Ports](docs/PORTS.md)
- [Image pins](docs/IMAGE_PINS.md)
- [Optional and deferred features](docs/ROADMAP.md)

## Development

Tests are self-contained and do not deploy by default. See [tests/README.md](tests/README.md). Runtime state, credentials, media inventories, and deployment-specific values must never be committed.
