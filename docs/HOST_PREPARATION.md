# Debian host preparation

VeinFin currently supports Debian 13 (`trixie`) on amd64. Host preparation uses Docker's official Debian APT repository and installs only the prerequisites plus `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, and `docker-compose-plugin`.

## Commands

```sh
scripts/host/prepare-debian.sh --help
scripts/host/prepare-debian.sh --check
sudo scripts/host/prepare-debian.sh --apply
```

`--check` is non-mutating and rejects unsupported hosts, conflicting runtime packages, existing unrecognized runtime data, conflicting Docker repository files, TCP API listeners, and membership in the `docker` group.

`--apply` validates the official repository metadata and signing-key fingerprint before atomically creating `/etc/apt/keyrings/docker.asc` and the `Signed-By` source definition. It installs the required packages without a distribution upgrade, enables Docker through systemd, and verifies an empty, Unix-socket-only engine. Repeated execution accepts the same official configuration and package installation.

Docker administration intentionally continues through `sudo`. The script never adds a user to the `docker` group because group membership grants root-equivalent control through the daemon.

No convenience installer or remote shell pipeline is used. The script does not remove packages or data, configure the TCP API or Swarm, pull images, run containers, publish ports, change storage, change firewall policy, or reboot.

## Docker and firewall behavior

Starting Docker creates its own packet-filtering and forwarding rules for bridge networking. Published container ports bypass assumptions made by ordinary host-firewall input rules. After runtime preparation and before any VeinFin container starts, configure and independently verify the Docker-aware policy described in [FIREWALL.md](FIREWALL.md). The runtime-preparation command itself still makes no firewall change.

## Remaining work

Successful host preparation alone is not deployment readiness. Operator-provided media storage, generated application configuration, verified application bootstrap, certificates, and service deployment remain unfinished. Firewall enforcement is a separate guarded step and does not imply that any application port or container is active.

Reference: [Docker Engine installation on Debian](https://docs.docker.com/engine/install/debian/) and [Docker packet filtering and firewalls](https://docs.docker.com/engine/network/packet-filtering-firewalls/).
