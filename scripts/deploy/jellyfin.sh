#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=${VEINFIN_REPO_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd -P)}
BASE_COMPOSE=$REPO_ROOT/compose.yaml
LOOPBACK_COMPOSE=$REPO_ROOT/compose/jellyfin-loopback.yaml
QBITTORRENT_LOOPBACK_COMPOSE=$REPO_ROOT/compose/qbittorrent-loopback.yaml
ARR_LOOPBACK_COMPOSE=$REPO_ROOT/compose/arr-loopback.yaml
IMAGE_LOCK=$REPO_ROOT/config/images.lock
ENV_EXAMPLE=$REPO_ROOT/.env.example
ENV_FILE=${VEINFIN_ENV_FILE:-$REPO_ROOT/.env}
DEPLOY_ROOT=${VEINFIN_DEPLOY_ROOT:-$REPO_ROOT}
CONFIG_ROOT=${VEINFIN_CONFIG_ROOT:-/var/lib/veinfin}
MEDIA_ROOT=${VEINFIN_MEDIA_ROOT:-/srv/media}
RUNTIME_ROOT=$DEPLOY_ROOT/runtime
PROJECT_NAME=${VEINFIN_PROJECT_NAME:-veinfin}
LOOPBACK_PORT=8096
ACTIVE_TEMP=

info() { printf 'INFO: %s\n' "$*"; }
pass() { printf 'PASS: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [ -n "${ACTIVE_TEMP:-}" ] && [ -f "$ACTIVE_TEMP" ]; then rm -f -- "$ACTIVE_TEMP"; fi
}
trap cleanup EXIT HUP INT TERM

usage() {
  cat <<'EOF'
VeinFin Jellyfin-only deployment

Usage:
  scripts/deploy/jellyfin.sh --help
  scripts/deploy/jellyfin.sh --check
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/jellyfin.sh --apply
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/jellyfin.sh --verify

Modes:
  --check   Non-mutating readiness checks using a temporary, non-secret env file.
  --apply   Create protected config/cache directories, validate Compose, pull
            only the locked Jellyfin image, and start only Jellyfin with --no-deps.
  --verify  Prove container identity, health, mounts, loopback-only binding,
            listener isolation, storage readiness, and firewall health.

Bootstrap access is available only through host loopback. From an operator
workstation, use a tunnel such as:
  ssh -N -L 8096:127.0.0.1:8096 user@host

This workflow does not run the Jellyfin wizard, create an administrator,
configure a library, scan media, enable discovery/GPU access, or start any
other Compose service.
EOF
}

require_root() { [ "$EUID" -eq 0 ] || die "$1 must run as root (use sudo)"; }

as_root() {
  if [ "$EUID" -eq 0 ]; then
    "$@"
  else
    command -v sudo >/dev/null 2>&1 || die "sudo is required for Docker inspection"
    sudo -n --preserve-env=SSH_CONNECTION "$@"
  fi
}

docker_cmd() { as_root docker "$@"; }

compose_cmd() {
  local env_file=$1
  shift
  docker_cmd compose --project-directory "$REPO_ROOT" --env-file "$env_file" -f "$BASE_COMPOSE" -f "$LOOPBACK_COMPOSE" -f "$QBITTORRENT_LOOPBACK_COMPOSE" -f "$ARR_LOOPBACK_COMPOSE" "$@"
}

valid_path() {
  [ -n "$1" ] && [[ $1 == /* ]] && [ "$1" != / ] && [[ $1 =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ /$1/ != */../* ]] && [[ /$1/ != */./* ]]
}

file_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then stat -c '%a' "$1"; else stat -f '%Lp' "$1"; fi
}

runtime_identity() {
  local user_name
  if [ -n "${VEINFIN_RUNTIME_USER:-}" ]; then
    user_name=$VEINFIN_RUNTIME_USER
  elif [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    user_name=$SUDO_USER
  elif [ "$EUID" -ne 0 ]; then
    user_name=$(id -un)
  else
    die "cannot determine the non-root runtime SSH user; invoke through sudo"
  fi
  RUNTIME_UID=$(id -u "$user_name")
  RUNTIME_GID=$(id -g "$user_name")
  [[ $RUNTIME_UID =~ ^[0-9]+$ && $RUNTIME_GID =~ ^[0-9]+$ ]] || die "runtime UID/GID are invalid"
  [ "$RUNTIME_UID" -gt 0 ] && [ "$RUNTIME_GID" -gt 0 ] || die "Jellyfin must not run as root"
}

require_commands() {
  local name
  for name in awk chmod chown cmp curl cut dirname docker findmnt grep id install mktemp mv sed sleep sort ss stat tr; do
    command -v "$name" >/dev/null 2>&1 || die "required command missing: $name"
  done
  docker_cmd compose version >/dev/null 2>&1 || die "Docker Compose plugin is unavailable"
  docker_cmd info >/dev/null 2>&1 || die "Docker daemon is unavailable"
  pass "Docker Engine and Compose are available"
}

load_image_pin() {
  local count service repository tag digest
  count=$(awk -F'|' '$1 == "JELLYFIN_IMAGE_TAG" {n++} END {print n+0}' "$IMAGE_LOCK")
  [ "$count" -eq 1 ] || die "Jellyfin image lock is missing or duplicated"
  JELLYFIN_REPOSITORY=$(awk -F'|' '$1 == "JELLYFIN_IMAGE_TAG" {print $2}' "$IMAGE_LOCK")
  JELLYFIN_TAG=$(awk -F'|' '$1 == "JELLYFIN_IMAGE_TAG" {print $3}' "$IMAGE_LOCK")
  JELLYFIN_DIGEST=$(awk -F'|' '$1 == "JELLYFIN_IMAGE_TAG" {print $4}' "$IMAGE_LOCK")
  JELLYFIN_PIN=$JELLYFIN_TAG@$JELLYFIN_DIGEST
  JELLYFIN_IMAGE=$JELLYFIN_REPOSITORY:$JELLYFIN_PIN
  [ "$JELLYFIN_REPOSITORY" = jellyfin/jellyfin ] || die "Jellyfin image repository is not official"
  [[ $JELLYFIN_DIGEST =~ ^sha256:[0-9a-f]{64}$ ]] || die "Jellyfin image digest is invalid"
  grep -Fq 'image: jellyfin/jellyfin:${JELLYFIN_IMAGE_TAG:?Set JELLYFIN_IMAGE_TAG}' "$BASE_COMPOSE" || die "base Compose Jellyfin image contract changed"
  grep -Fxq "JELLYFIN_IMAGE_TAG=$JELLYFIN_PIN" "$ENV_EXAMPLE" || die "Jellyfin example pin does not match the lock"
  QBITTORRENT_REPOSITORY=$(awk -F'|' '$1 == "QBITTORRENT_IMAGE_TAG" {print $2}' "$IMAGE_LOCK")
  QBITTORRENT_TAG=$(awk -F'|' '$1 == "QBITTORRENT_IMAGE_TAG" {print $3}' "$IMAGE_LOCK")
  QBITTORRENT_DIGEST=$(awk -F'|' '$1 == "QBITTORRENT_IMAGE_TAG" {print $4}' "$IMAGE_LOCK")
  QBITTORRENT_IMAGE=$QBITTORRENT_REPOSITORY:$QBITTORRENT_TAG@$QBITTORRENT_DIGEST
  [[ $QBITTORRENT_DIGEST =~ ^sha256:[0-9a-f]{64}$ ]] || die "qBittorrent image lock is invalid"
  for service in SONARR RADARR PROWLARR; do
    repository=$(awk -F'|' -v key="${service}_IMAGE_TAG" '$1 == key {print $2}' "$IMAGE_LOCK")
    tag=$(awk -F'|' -v key="${service}_IMAGE_TAG" '$1 == key {print $3}' "$IMAGE_LOCK")
    digest=$(awk -F'|' -v key="${service}_IMAGE_TAG" '$1 == key {print $4}' "$IMAGE_LOCK")
    [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || die "$service image lock is invalid"
    printf -v "${service}_IMAGE" '%s:%s@%s' "$repository" "$tag" "$digest"
  done
  pass "Jellyfin image pin matches the official-image lock"
}

validate_loopback_override() {
  [ "$(grep -Ec '^[[:space:]]+host_ip:[[:space:]]+127\.0\.0\.1$' "$LOOPBACK_COMPOSE")" -eq 1 ] || die "Jellyfin override must have exactly one loopback host_ip"
  [ "$(grep -Ec '^[[:space:]]+target:[[:space:]]+8096$' "$LOOPBACK_COMPOSE")" -eq 1 ] || die "Jellyfin override must target TCP 8096 exactly once"
  [ "$(grep -Ec '^[[:space:]]+published:[[:space:]]+"?8096"?$' "$LOOPBACK_COMPOSE")" -eq 1 ] || die "Jellyfin override must publish TCP 8096 exactly once"
  [ "$(grep -Ec '^[[:space:]]+protocol:[[:space:]]+tcp$' "$LOOPBACK_COMPOSE")" -eq 1 ] || die "Jellyfin override must use TCP"
  if grep -Eq 'host_ip:[[:space:]]*(0\.0\.0\.0|::|\[::\])' "$LOOPBACK_COMPOSE"; then die "wildcard Jellyfin binding is forbidden"; fi
  pass "Jellyfin bootstrap override is exactly loopback-only TCP 8096"
}

check_paths() {
  local component current=
  valid_path "$CONFIG_ROOT" || die "config root is unsafe"
  valid_path "$MEDIA_ROOT" || die "media root is unsafe"
  valid_path "$DEPLOY_ROOT" || die "deployment root is unsafe"
  IFS=/ read -r -a components <<<"${CONFIG_ROOT#/}"
  for component in "${components[@]}"; do
    current=$current/$component
    [ ! -L "$current" ] || die "config-root path contains a symlink"
  done
  [ ! -e "$CONFIG_ROOT" ] || [ -d "$CONFIG_ROOT" ] || die "config root exists but is not a directory"
  pass "config and deployment roots are safe"
}

check_media() {
  local target options path
  [ -d "$MEDIA_ROOT" ] || die "media root does not exist"
  target=$(findmnt -n -T "$MEDIA_ROOT" -o TARGET 2>/dev/null || true)
  [ "$target" = "$MEDIA_ROOT" ] || die "media root is not its own mounted filesystem"
  options=$(findmnt -n -T "$MEDIA_ROOT" -o OPTIONS 2>/dev/null || true)
  case ",$options," in *,rw,*) ;; *) die "media root is not mounted read-write on the host" ;; esac
  for path in library library/movies library/tv library/anime; do
    [ -d "$MEDIA_ROOT/$path" ] || die "required media directory is missing: $path"
  done
  pass "media root is a read-write mounted filesystem with required library directories"
}

existing_jellyfin_id() {
  docker_cmd ps -aq --filter "label=com.docker.compose.project=$PROJECT_NAME" --filter 'label=com.docker.compose.service=jellyfin'
}

existing_qbittorrent_id() {
  docker_cmd ps -aq --filter "label=com.docker.compose.project=$PROJECT_NAME" --filter 'label=com.docker.compose.service=qbittorrent'
}

check_container_scope() {
  local intended qbittorrent id all_ids service allowed
  intended=$(existing_jellyfin_id)
  qbittorrent=$(existing_qbittorrent_id)
  [ "$(printf '%s\n' "$intended" | awk 'NF {n++} END {print n+0}')" -le 1 ] || die "more than one project Jellyfin container exists"
  [ "$(printf '%s\n' "$qbittorrent" | awk 'NF {n++} END {print n+0}')" -le 1 ] || die "more than one project qBittorrent container exists"
  allowed=$(for service in jellyfin qbittorrent sonarr radarr prowlarr; do docker_cmd ps -aq --filter "label=com.docker.compose.project=$PROJECT_NAME" --filter "label=com.docker.compose.service=$service"; done)
  all_ids=$(docker_cmd ps -aq)
  for id in $all_ids; do
    printf '%s\n' "$allowed" | grep -Fxq "$id" || die "a container outside the ARR deployment runtime exists"
  done
  pass "container scope contains only intended Jellyfin and optional qBittorrent"
}

check_image_scope() {
  local expected_id qbittorrent_id id service image_var image_id allowed
  expected_id=$(docker_cmd image inspect --format '{{.Id}}' "$JELLYFIN_IMAGE" 2>/dev/null || true)
  qbittorrent_id=$(docker_cmd image inspect --format '{{.Id}}' "$QBITTORRENT_IMAGE" 2>/dev/null || true)
  allowed="$expected_id\n$qbittorrent_id\n"
  for service in SONARR RADARR PROWLARR; do image_var=${service}_IMAGE; image_id=$(docker_cmd image inspect --format '{{.Id}}' "${!image_var}" 2>/dev/null || true); [ -z "$image_id" ] || allowed="$allowed$image_id\n"; done
  for id in $(docker_cmd images -q --no-trunc | sort -u); do printf '%b' "$allowed" | grep -Fxq "$id" || die "an image outside the ARR deployment runtime exists"; done
  pass "image scope contains only locked Jellyfin and optional qBittorrent"
}

check_port() {
  local intended
  if ss -H -lnt "sport = :$LOOPBACK_PORT" | grep -q .; then
    intended=$(existing_jellyfin_id)
    [ -n "$intended" ] || die "TCP 8096 is occupied by something other than the intended container"
  fi
  pass "TCP 8096 is available or belongs to the intended Jellyfin container"
}

timezone_value() {
  if [ -r /etc/timezone ]; then
    tr -d '\r\n' </etc/timezone
  else
    printf 'Etc/UTC\n'
  fi
}

render_env() {
  local timezone
  timezone=$(timezone_value)
  printf '# Managed by VeinFin Jellyfin deployment. Contains no generated credentials.\n'
  awk -v project="$PROJECT_NAME" -v tz="$timezone" -v uid="$RUNTIME_UID" -v gid="$RUNTIME_GID" -v config="$CONFIG_ROOT" -v media="$MEDIA_ROOT" -v runtime="$RUNTIME_ROOT" -v jellyfin_pin="$JELLYFIN_PIN" '
    /^COMPOSE_PROJECT_NAME=/ {$0="COMPOSE_PROJECT_NAME=" project}
    /^TZ=/ {$0="TZ=" tz}
    /^PUID=/ {$0="PUID=" uid}
    /^PGID=/ {$0="PGID=" gid}
    /^CONFIG_ROOT=/ {$0="CONFIG_ROOT=" config}
    /^MEDIA_ROOT=/ {$0="MEDIA_ROOT=" media}
    /^RUNTIME_ROOT=/ {$0="RUNTIME_ROOT=" runtime}
    /^PUBLIC_HOSTNAME=/ {$0="PUBLIC_HOSTNAME=local.invalid"}
    /^PUBLIC_BIND_IP=/ {$0="PUBLIC_BIND_IP=127.0.0.1"}
    /^MANAGEMENT_BIND_IP=/ {$0="MANAGEMENT_BIND_IP=127.0.0.1"}
    /^MANAGEMENT_URL_HOST=/ {$0="MANAGEMENT_URL_HOST=localhost"}
    /^MANAGEMENT_ALLOWED_CIDRS=/ {$0="MANAGEMENT_ALLOWED_CIDRS=127.0.0.1/32"}
    /^ENABLE_JELLYFIN_DISCOVERY=/ {$0="ENABLE_JELLYFIN_DISCOVERY=false"}
    /^ENABLE_HARDWARE_TRANSCODING=/ {$0="ENABLE_HARDWARE_TRANSCODING=false"}
    /^TRANSCODING_DEVICE=/ {$0="TRANSCODING_DEVICE="}
    /^JELLYFIN_IMAGE_TAG=/ {$0="JELLYFIN_IMAGE_TAG=" jellyfin_pin}
    {print}
  ' "$ENV_EXAMPLE"
}

temporary_env() {
  ACTIVE_TEMP=$(mktemp /tmp/veinfin-jellyfin-env.XXXXXX)
  chmod 0600 "$ACTIVE_TEMP"
  render_env >"$ACTIVE_TEMP"
}

validate_compose() {
  local env_file=$1 rendered
  compose_cmd "$env_file" config --quiet
  rendered=$(compose_cmd "$env_file" config)
  printf '%s\n' "$rendered" | grep -Fq 'host_ip: 127.0.0.1' || die "resolved Compose does not bind Jellyfin to loopback"
  if printf '%s\n' "$rendered" | grep -Eq 'host_ip:[[:space:]]+(0\.0\.0\.0|::|\[::\])'; then die "resolved Compose contains a wildcard binding"; fi
  pass "resolved Compose configuration is valid and loopback-only"
}

run_checks() {
  require_commands
  runtime_identity
  load_image_pin
  validate_loopback_override
  check_paths
  check_media
  check_container_scope
  check_image_scope
  check_port
  temporary_env
  validate_compose "$ACTIVE_TEMP"
}

atomic_write_env() {
  local directory
  directory=$(dirname "$ENV_FILE")
  install -d -m 0755 "$directory"
  [ ! -L "$ENV_FILE" ] || die "refusing symlinked target environment file"
  [ ! -e "$ENV_FILE" ] || { [ -f "$ENV_FILE" ] && grep -q '^# Managed by VeinFin Jellyfin deployment\.' "$ENV_FILE"; } || die "refusing to replace an unowned target environment file"
  ACTIVE_TEMP=$(mktemp "$directory/.veinfin-jellyfin-env.XXXXXX")
  chmod 0600 "$ACTIVE_TEMP"
  render_env >"$ACTIVE_TEMP"
  chown root:root "$ACTIVE_TEMP"
  mv -f "$ACTIVE_TEMP" "$ENV_FILE"
  ACTIVE_TEMP=
}

prepare_directories() {
  install -d -m 0755 "$CONFIG_ROOT"
  [ ! -L "$CONFIG_ROOT/jellyfin" ] || die "refusing symlinked Jellyfin config directory"
  install -d -o "$RUNTIME_UID" -g "$RUNTIME_GID" -m 0700 "$CONFIG_ROOT/jellyfin" "$CONFIG_ROOT/jellyfin/config" "$CONFIG_ROOT/jellyfin/cache"
  install -d -m 0700 "$RUNTIME_ROOT" "$RUNTIME_ROOT/state"
  pass "protected Jellyfin config, cache, and state directories are ready"
}

snapshot_listeners() {
  ss -H -lntu | awk '{print $1, $5}' | sort -u
}

record_listener_baseline() {
  local baseline
  baseline=$RUNTIME_ROOT/state/jellyfin-listeners-before.txt
  [ ! -L "$baseline" ] || die "refusing symlinked listener baseline"
  if [ -e "$baseline" ]; then
    [ -f "$baseline" ] && [ "$(file_mode "$baseline")" = 600 ] || die "listener baseline permissions are unsafe"
    return 0
  fi
  ACTIVE_TEMP=$(mktemp "$RUNTIME_ROOT/state/.listeners-before.XXXXXX")
  chmod 0600 "$ACTIVE_TEMP"
  snapshot_listeners >"$ACTIVE_TEMP"
  mv -f "$ACTIVE_TEMP" "$baseline"
  ACTIVE_TEMP=
}

verify_listener_delta() {
  local baseline current
  baseline=$RUNTIME_ROOT/state/jellyfin-listeners-before.txt
  [ -f "$baseline" ] && [ ! -L "$baseline" ] && [ "$(file_mode "$baseline")" = 600 ] || die "protected listener baseline is missing or unsafe"
  if grep -Fxq "tcp 127.0.0.1:$LOOPBACK_PORT" "$baseline"; then die "listener baseline was captured after Jellyfin started"; fi
  current=$(mktemp /tmp/veinfin-jellyfin-listeners.XXXXXX)
  ACTIVE_TEMP=$current
  snapshot_listeners | awk -v jellyfin="tcp 127.0.0.1:$LOOPBACK_PORT" -v qbittorrent='tcp 127.0.0.1:8080' '$0 != jellyfin && $0 != qbittorrent && $0 != "tcp 127.0.0.1:8989" && $0 != "tcp 127.0.0.1:7878" && $0 != "tcp 127.0.0.1:9696"' >"$current"
  cmp -s "$baseline" "$current" || die "host listeners changed beyond loopback-only Jellyfin"
  rm -f "$current"
  ACTIVE_TEMP=
  pass "listener delta contains only loopback TCP 8096"
}

wait_for_health() {
  local id=$1 attempt health
  attempt=0
  while [ "$attempt" -lt 36 ]; do
    health=$(docker_cmd inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "$id")
    [ "$health" = healthy ] && return 0
    [ "$health" != unhealthy ] || die "Jellyfin reported unhealthy"
    attempt=$((attempt + 1))
    sleep 5
  done
  die "Jellyfin did not become healthy within three minutes"
}

verify_mounts() {
  local id=$1 mounts expected_config expected_cache expected_library
  mounts=$(docker_cmd inspect --format '{{range .Mounts}}{{println .Source "|" .Destination "|" .RW}}{{end}}' "$id")
  expected_config="$CONFIG_ROOT/jellyfin/config | /config | true"
  expected_cache="$CONFIG_ROOT/jellyfin/cache | /cache | true"
  expected_library="$MEDIA_ROOT/library | /data/library | false"
  printf '%s\n' "$mounts" | grep -Fxq "$expected_config" || die "Jellyfin config mount is missing or not writable"
  printf '%s\n' "$mounts" | grep -Fxq "$expected_cache" || die "Jellyfin cache mount is missing or not writable"
  printf '%s\n' "$mounts" | grep -Fxq "$expected_library" || die "Jellyfin library mount is missing or not read-only"
  [ "$(printf '%s\n' "$mounts" | awk 'NF {n++} END {print n+0}')" -eq 3 ] || die "Jellyfin has an unexpected mount"
  if printf '%s\n' "$mounts" | grep -qi torrent; then die "Jellyfin must not receive a torrent mount"; fi
  docker_cmd exec "$id" sh -c 'test -w /config && test -w /cache && test -r /data/library && test ! -w /data/library' || die "in-container mount permissions are unsafe"
  pass "config/cache are writable and the library is read-only with no torrent mount"
}

verify_port_binding() {
  local id=$1 bindings listeners
  bindings=$(docker_cmd inspect --format '{{range $port, $entries := .NetworkSettings.Ports}}{{range $entries}}{{println $port "|" .HostIp "|" .HostPort}}{{end}}{{end}}' "$id")
  [ "$bindings" = '8096/tcp | 127.0.0.1 | 8096' ] || die "Jellyfin host binding is not exactly 127.0.0.1:8096"
  listeners=$(ss -H -lnt "sport = :$LOOPBACK_PORT")
  [ "$(printf '%s\n' "$listeners" | awk 'NF {n++} END {print n+0}')" -eq 1 ] || die "TCP 8096 does not have exactly one listener"
  printf '%s\n' "$listeners" | awk '$4 == "127.0.0.1:8096" {ok=1} END {exit !ok}' || die "TCP 8096 is not loopback-only"
  pass "host TCP 8096 is bound only to 127.0.0.1"
}

verify_closed_ports() {
  if ss -H -lnt 'sport = :80 or sport = :443 or sport = :3000 or sport = :5055 or sport = :6767 or sport = :2375 or sport = :2376' | grep -q .; then
    die "an unrelated application, public, or Docker API port is listening"
  fi
  pass "public, management, and Docker API TCP ports remain closed"
}

run_verify() {
  local id qbittorrent_id all_count expected_count service image running health devices qbittorrent_binding arr_count=0 arr_id arr_image_var arr_port arr_binding
  require_commands
  runtime_identity
  load_image_pin
  check_media
  id=$(existing_jellyfin_id)
  [ -n "$id" ] && [ "$(printf '%s\n' "$id" | awk 'NF {n++} END {print n+0}')" -eq 1 ] || die "exactly one intended Jellyfin container is required"
  qbittorrent_id=$(existing_qbittorrent_id)
  [ "$(printf '%s\n' "$qbittorrent_id" | awk 'NF {n++} END {print n+0}')" -le 1 ] || die "more than one qBittorrent container exists"
  expected_count=1; [ -z "$qbittorrent_id" ] || expected_count=2
  for service in sonarr radarr prowlarr; do arr_id=$(docker_cmd ps -aq --filter "label=com.docker.compose.project=$PROJECT_NAME" --filter "label=com.docker.compose.service=$service"); [ -z "$arr_id" ] || arr_count=$((arr_count + 1)); done
  { [ "$arr_count" -eq 0 ] || [ "$arr_count" -eq 3 ]; } || die "ARR deployment services must be all absent or all present"
  expected_count=$((expected_count + arr_count))
  all_count=$(docker_cmd ps -aq | awk 'NF {n++} END {print n+0}')
  [ "$all_count" -eq "$expected_count" ] || die "a container other than Jellyfin/qBittorrent exists"
  [ "$(docker_cmd images -q --no-trunc | sort -u | awk 'NF {n++} END {print n+0}')" -eq "$expected_count" ] || die "an image other than Jellyfin/qBittorrent exists"
  service=$(docker_cmd inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$id")
  [ "$service" = jellyfin ] || die "deployed container is not the Jellyfin Compose service"
  image=$(docker_cmd inspect --format '{{.Config.Image}}' "$id")
  [ "$image" = "$JELLYFIN_IMAGE" ] || die "running Jellyfin image does not match the lock"
  running=$(docker_cmd inspect --format '{{.State.Running}}' "$id")
  health=$(docker_cmd inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "$id")
  [ "$running" = true ] && [ "$health" = healthy ] || die "Jellyfin is not running and healthy"
  devices=$(docker_cmd inspect --format '{{json .HostConfig.Devices}}' "$id")
  [ "$devices" = '[]' ] || [ "$devices" = null ] || die "Jellyfin unexpectedly has a host device"
  if [ -n "$qbittorrent_id" ]; then
    [ "$(docker_cmd inspect --format '{{.Config.Image}}|{{.State.Running}}|{{.State.Health.Status}}' "$qbittorrent_id")" = "$QBITTORRENT_IMAGE|true|healthy" ] || die "qBittorrent identity or health is invalid"
    qbittorrent_binding=$(docker_cmd inspect --format '{{range $port, $entries := .NetworkSettings.Ports}}{{range $entries}}{{println $port "|" .HostIp "|" .HostPort}}{{end}}{{end}}' "$qbittorrent_id")
    [ "$qbittorrent_binding" = '8080/tcp | 127.0.0.1 | 8080' ] || die "qBittorrent binding is not loopback-only"
  elif ss -H -lnt 'sport = :8080' | grep -q .; then
    die "TCP 8080 is occupied without qBittorrent"
  fi
  if [ "$arr_count" -eq 3 ]; then
    for service in sonarr radarr prowlarr; do
      case "$service" in sonarr) arr_image_var=SONARR_IMAGE; arr_port=8989;; radarr) arr_image_var=RADARR_IMAGE; arr_port=7878;; prowlarr) arr_image_var=PROWLARR_IMAGE; arr_port=9696;; esac
      arr_id=$(docker_cmd ps -aq --filter "label=com.docker.compose.project=$PROJECT_NAME" --filter "label=com.docker.compose.service=$service")
      [ "$(docker_cmd inspect --format '{{.Config.Image}}|{{.State.Running}}|{{.State.Health.Status}}' "$arr_id")" = "${!arr_image_var}|true|healthy" ] || die "$service identity or health is invalid"
      arr_binding=$(docker_cmd inspect --format '{{range $port,$entries:=.NetworkSettings.Ports}}{{range $entries}}{{println $port "|" .HostIp "|" .HostPort}}{{end}}{{end}}' "$arr_id")
      [ "$arr_binding" = "$arr_port/tcp | 127.0.0.1 | $arr_port" ] || die "$service binding is unsafe"
    done
  fi
  verify_mounts "$id"
  verify_port_binding "$id"
  verify_closed_ports
  verify_listener_delta
  curl -fsS "http://127.0.0.1:$LOOPBACK_PORT/health" >/dev/null || die "Jellyfin loopback health endpoint is unavailable"
  [ -x /usr/local/sbin/veinfin-firewall ] || die "VeinFin firewall verifier is unavailable"
  as_root /usr/local/sbin/veinfin-firewall --verify >/dev/null || die "VeinFin firewall verification failed"
  pass "Jellyfin identity, image, running state, health, and firewall are valid"
}

run_check() {
  run_checks
  rm -f -- "$ACTIVE_TEMP"; ACTIVE_TEMP=
  info "Read-only Jellyfin check passed; no persistent file, image, network, or container was created"
}

run_apply() {
  local id
  require_root "--apply"
  run_checks
  rm -f -- "$ACTIVE_TEMP"; ACTIVE_TEMP=
  prepare_directories
  record_listener_baseline
  atomic_write_env
  validate_compose "$ENV_FILE"
  compose_cmd "$ENV_FILE" pull jellyfin
  compose_cmd "$ENV_FILE" up -d --no-deps jellyfin
  id=$(existing_jellyfin_id)
  [ -n "$id" ] || die "Compose did not create the Jellyfin container"
  wait_for_health "$id"
  run_verify
  pass "Jellyfin-only deployment completed"
}

if [ "${VEINFIN_JELLYFIN_LIBRARY_ONLY:-0}" = 1 ]; then
  return 0 2>/dev/null || exit 0
fi

[ "$#" -eq 1 ] || { usage; exit 2; }
case "$1" in
  --help) usage ;;
  --check) run_check ;;
  --apply) run_apply ;;
  --verify) run_verify ;;
  *) usage; exit 2 ;;
esac
