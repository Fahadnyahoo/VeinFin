#!/usr/bin/env bash
set -euo pipefail

DOCKER_REPOSITORY_URL=https://download.docker.com/linux/debian
DOCKER_KEY_URL=https://download.docker.com/linux/debian/gpg
DOCKER_KEY_FINGERPRINT=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
SUPPORTED_CODENAME=trixie
SUPPORTED_ARCHITECTURE=amd64
HOST_ROOT=${VEINFIN_HOST_ROOT:-}
OS_RELEASE_FILE=${VEINFIN_OS_RELEASE:-${HOST_ROOT}/etc/os-release}
KEYRING_PATH=${HOST_ROOT}/etc/apt/keyrings/docker.asc
SOURCE_PATH=${HOST_ROOT}/etc/apt/sources.list.d/docker.sources
DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
CONFLICTING_PACKAGES=(docker.io docker-compose docker-doc docker-buildx podman-docker podman containerd runc)
ACTIVE_TEMP=

info() { printf 'INFO: %s\n' "$*"; }
pass() { printf 'PASS: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [ -n "${ACTIVE_TEMP:-}" ] && [ -f "$ACTIVE_TEMP" ]; then
    rm -f -- "$ACTIVE_TEMP"
  fi
  if [ -n "${SOCKETS_BEFORE_FILE:-}" ] && [ -f "$SOCKETS_BEFORE_FILE" ]; then
    rm -f -- "$SOCKETS_BEFORE_FILE"
  fi
  if [ -n "${SOCKETS_AFTER_FILE:-}" ] && [ -f "$SOCKETS_AFTER_FILE" ]; then
    rm -f -- "$SOCKETS_AFTER_FILE"
  fi
  if [ -n "${DOWNLOADED_KEY_FILE:-}" ] && [ -f "$DOWNLOADED_KEY_FILE" ]; then
    rm -f -- "$DOWNLOADED_KEY_FILE"
  fi
  if [ -n "${RELEASE_FILE:-}" ] && [ -f "$RELEASE_FILE" ]; then
    rm -f -- "$RELEASE_FILE"
  fi
}
trap cleanup EXIT HUP INT TERM

usage() {
  cat <<'EOF'
VeinFin Debian container-runtime preparation

Usage:
  prepare-debian.sh --help
  prepare-debian.sh --check
  sudo prepare-debian.sh --apply

Modes:
  --help   Show this help without changing the host.
  --check  Validate Debian 13 amd64 and report runtime conflicts; never mutates.
  --apply  Configure Docker's official APT repository, install the required
           Engine/Buildx/Compose packages, and enable Docker through systemd.

The script never removes conflicting packages or Docker data, enables the TCP
API, changes firewall/storage configuration, adds users to the docker group,
pulls images, starts containers, configures Swarm, upgrades the distribution,
or reboots. Administrative Docker access remains through sudo.
EOF
}

load_platform() {
  [ -r "$OS_RELEASE_FILE" ] || die "cannot read OS release metadata"
  # shellcheck disable=SC1090
  . "$OS_RELEASE_FILE"
  HOST_OS_ID=${ID:-}
  HOST_OS_VERSION=${VERSION_ID:-}
  HOST_CODENAME=${VERSION_CODENAME:-}
  HOST_ARCHITECTURE=$(dpkg --print-architecture)
}

validate_platform() {
  load_platform
  [ "$HOST_OS_ID" = debian ] || die "unsupported distribution: expected Debian"
  [ "$HOST_OS_VERSION" = 13 ] || die "unsupported Debian version: expected 13"
  [ "$HOST_CODENAME" = "$SUPPORTED_CODENAME" ] || die "unsupported Debian codename: expected $SUPPORTED_CODENAME"
  [ "$HOST_ARCHITECTURE" = "$SUPPORTED_ARCHITECTURE" ] || die "unsupported architecture: expected $SUPPORTED_ARCHITECTURE"
  pass "supported host: Debian 13 $SUPPORTED_ARCHITECTURE"
}

installed_version() {
  dpkg-query -W -f='${Status}|${Version}\n' "$1" 2>/dev/null | awk -F'|' '$1 == "install ok installed" { print $2 }' || true
}

official_runtime_installed() {
  [ -n "$(installed_version docker-ce)" ] && [ -n "$(installed_version docker-ce-cli)" ] && [ -n "$(installed_version containerd.io)" ]
}

check_conflicting_packages() {
  found=
  for package in "${CONFLICTING_PACKAGES[@]}"; do
    version=$(installed_version "$package")
    [ -z "$version" ] || found="${found}${package}=${version} "
  done
  [ -z "$found" ] || die "conflicting runtime packages are installed: $found"
  pass "no conflicting runtime package is installed"
}

check_existing_runtime() {
  check_conflicting_packages
  if official_runtime_installed; then
    pass "official Docker packages are already installed"
    return 0
  fi

  for command_name in docker podman containerd ctr runc; do
    command -v "$command_name" >/dev/null 2>&1 && die "existing runtime command found: $command_name"
  done
  for data_path in "${HOST_ROOT}/var/lib/docker" "${HOST_ROOT}/var/lib/containerd" "${HOST_ROOT}/var/lib/containers" "${HOST_ROOT}/etc/docker"; do
    [ ! -e "$data_path" ] || die "existing runtime data or configuration found: $data_path"
  done
  pass "no existing runtime command, data, or configuration was found"
}

expected_source() {
  cat <<EOF
Types: deb
URIs: $DOCKER_REPOSITORY_URL
Suites: $SUPPORTED_CODENAME
Components: stable
Architectures: $SUPPORTED_ARCHITECTURE
Signed-By: /etc/apt/keyrings/docker.asc
EOF
}

check_existing_apt_files() {
  if [ -e "$SOURCE_PATH" ]; then
    expected_source | cmp -s - "$SOURCE_PATH" || die "existing Docker APT source conflicts with the VeinFin contract: $SOURCE_PATH"
  fi
  if [ -e "$KEYRING_PATH" ] && [ ! -f "$KEYRING_PATH" ]; then
    die "existing Docker keyring path is not a regular file: $KEYRING_PATH"
  fi
  legacy_source=${HOST_ROOT}/etc/apt/sources.list.d/docker.list
  legacy_key=${HOST_ROOT}/usr/share/keyrings/docker-archive-keyring.gpg
  [ ! -e "$legacy_source" ] || die "existing Docker APT source requires manual review: $legacy_source"
  [ ! -e "$legacy_key" ] || die "existing Docker keyring requires manual review: $legacy_key"
  pass "no conflicting Docker APT source or keyring was found"
}

snapshot_listeners() {
  ss -H -lntu | awk '{ print $1, $5 }' | sort -u
}

check_tcp_api_closed() {
  if ss -H -lnt 'sport = :2375 or sport = :2376' | grep -q .; then
    die "Docker TCP API port 2375 or 2376 is listening"
  fi
  pass "Docker TCP API ports 2375 and 2376 are closed"
}

run_check() {
  validate_platform
  check_existing_runtime
  check_existing_apt_files
  check_tcp_api_closed
  if getent group docker >/dev/null 2>&1 && id -nG | tr ' ' '\n' | grep -qx docker; then
    die "current user belongs to the docker group"
  fi
  pass "current user is not a member of the docker group"
  info "Preflight only: application deployment, storage, bootstrap, and firewall enforcement are not performed by this command"
}

write_atomic_if_absent_or_equal() {
  target=$1
  content_file=$2
  mode=$3
  if [ -e "$target" ]; then
    [ -f "$target" ] && [ ! -L "$target" ] || die "refusing non-regular or symlinked configuration path: $target"
    cmp -s "$content_file" "$target" || die "existing configuration conflicts with expected content: $target"
    chmod "$mode" "$target"
    return 0
  fi
  target_dir=$(dirname "$target")
  install -d -m 0755 "$target_dir"
  ACTIVE_TEMP=$(mktemp "$target_dir/.veinfin.tmp.XXXXXX")
  install -m "$mode" "$content_file" "$ACTIVE_TEMP"
  mv "$ACTIVE_TEMP" "$target"
  ACTIVE_TEMP=
}

install_prerequisites() {
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl gnupg
}

validate_repository_and_key() {
  [ "$DOCKER_REPOSITORY_URL" = https://download.docker.com/linux/debian ] || die "unexpected Docker repository URL"
  [ "$HOST_CODENAME" = trixie ] || die "repository codename validation failed"
  [ "$HOST_ARCHITECTURE" = amd64 ] || die "repository architecture validation failed"

  RELEASE_FILE=$(mktemp /tmp/veinfin-docker-release.XXXXXX)
  curl -fsSL "$DOCKER_REPOSITORY_URL/dists/$HOST_CODENAME/Release" -o "$RELEASE_FILE"
  grep -Eq '^Architectures: .*\bamd64\b' "$RELEASE_FILE" || die "official repository does not advertise amd64"

  DOWNLOADED_KEY_FILE=$(mktemp /tmp/veinfin-docker-key.XXXXXX)
  curl -fsSL "$DOCKER_KEY_URL" -o "$DOWNLOADED_KEY_FILE"
  key_fingerprints=$(gpg --batch --show-keys --with-colons "$DOWNLOADED_KEY_FILE" 2>/dev/null | awk -F: '$1 == "fpr" { print $10 }')
  printf '%s\n' "$key_fingerprints" | grep -qx "$DOCKER_KEY_FINGERPRINT" || die "Docker signing-key fingerprint validation failed"
  pass "official repository URL, trixie/amd64 metadata, and signing key are valid"
}

configure_repository() {
  source_temp=$(mktemp /tmp/veinfin-docker-source.XXXXXX)
  expected_source >"$source_temp"
  write_atomic_if_absent_or_equal "$KEYRING_PATH" "$DOWNLOADED_KEY_FILE" 0644
  write_atomic_if_absent_or_equal "$SOURCE_PATH" "$source_temp" 0644
  rm -f -- "$source_temp"
}

validate_package_candidates() {
  apt-get update
  for package in "${DOCKER_PACKAGES[@]}"; do
    policy=$(apt-cache policy "$package")
    candidate=$(printf '%s\n' "$policy" | awk '/Candidate:/ { print $2 }')
    [ -n "$candidate" ] && [ "$candidate" != '(none)' ] || die "no installable candidate for $package"
    case "$policy" in
      *"$DOCKER_REPOSITORY_URL"*) ;;
      *) die "$package candidate is not offered by the official Docker repository" ;;
    esac
  done
  pass "required Docker package candidates come from the official repository"
}

verify_runtime() {
  systemctl is-enabled --quiet docker.service || die "Docker service is not enabled"
  systemctl is-active --quiet docker.service || die "Docker service is not active"
  docker version >/dev/null
  docker compose version >/dev/null
  docker info >/dev/null
  check_tcp_api_closed
  [ -S /var/run/docker.sock ] || die "Docker Unix socket is unavailable"
  [ "$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null)" = unix:///var/run/docker.sock ] || die "Docker client is not using the local Unix socket"
  [ "$(docker info --format '{{.Swarm.LocalNodeState}}')" = inactive ] || die "Docker Swarm must remain inactive"
  [ -z "$(docker ps -aq)" ] || die "a container exists after runtime preparation"
  [ -z "$(docker images -q)" ] || die "an image exists after runtime preparation"
  pass "Docker is enabled, active, Unix-socket-only, empty, and not in Swarm mode"
  info "Storage driver: $(docker info --format '{{.Driver}}')"
  info "Cgroup version: $(docker info --format '{{.CgroupVersion}}')"
}

run_apply() {
  [ "$EUID" -eq 0 ] || die "--apply must run as root (use sudo)"
  validate_platform
  check_existing_runtime
  check_existing_apt_files
  check_tcp_api_closed
  original_user=${SUDO_USER:-}
  if [ -n "$original_user" ] && id -nG "$original_user" | tr ' ' '\n' | grep -qx docker; then
    die "invoking user already belongs to the docker group"
  fi

  SOCKETS_BEFORE_FILE=$(mktemp /tmp/veinfin-sockets-before.XXXXXX)
  SOCKETS_AFTER_FILE=$(mktemp /tmp/veinfin-sockets-after.XXXXXX)
  snapshot_listeners >"$SOCKETS_BEFORE_FILE"

  install_prerequisites
  validate_repository_and_key
  configure_repository
  validate_package_candidates
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${DOCKER_PACKAGES[@]}"
  systemctl enable --now docker.service
  verify_runtime

  snapshot_listeners >"$SOCKETS_AFTER_FILE"
  cmp -s "$SOCKETS_BEFORE_FILE" "$SOCKETS_AFTER_FILE" || die "a TCP or UDP listener changed during Docker preparation"
  if [ -n "$original_user" ] && id -nG "$original_user" | tr ' ' '\n' | grep -qx docker; then
    die "invoking user was added to the docker group"
  fi
  pass "no TCP/UDP listener changed and the invoking user's groups are unchanged"
  info "Runtime preparation complete; VeinFin is not deployment-ready"
}

if [ "${VEINFIN_PREPARE_LIBRARY_ONLY:-0}" = 1 ]; then
  return 0 2>/dev/null || exit 0
fi

[ "$#" -eq 1 ] || { usage; exit 2; }
case "$1" in
  --help) usage ;;
  --check) run_check ;;
  --apply) run_apply ;;
  *) usage; exit 2 ;;
esac
