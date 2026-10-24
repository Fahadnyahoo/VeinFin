#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=${VEINFIN_REPO_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd -P)}
BASE_COMPOSE=$REPO_ROOT/compose.yaml
JELLYFIN_LOOPBACK_COMPOSE=$REPO_ROOT/compose/jellyfin-loopback.yaml
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
LOOPBACK_PORT=8080
BASE_URL=http://127.0.0.1:8080
ACTIVE_TEMP=
WORK_DIR=
PREVIOUS_PASSWORD_FILE=

# Reuse the installer's secure random and atomic-write primitives.
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/lib/common.sh"

info() { printf 'INFO: %s\n' "$*"; }
pass() { printf 'PASS: %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [ -n "${ACTIVE_TEMP:-}" ] && [ -f "$ACTIVE_TEMP" ]; then rm -f -- "$ACTIVE_TEMP"; fi
  if [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ]; then find "$WORK_DIR" -depth -delete 2>/dev/null || true; fi
  vf_cleanup
}
trap cleanup EXIT HUP INT TERM

usage() {
  cat <<'EOF'
VeinFin qBittorrent-only deployment and bootstrap

Usage:
  scripts/deploy/qbittorrent.sh --help
  scripts/deploy/qbittorrent.sh --check
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/qbittorrent.sh --apply
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/qbittorrent.sh --apply --previous-password-file FILE
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/qbittorrent.sh --verify

Modes:
  --check   Read-only readiness checks for the locked image, storage, existing
            Jellyfin, exact loopback override, credentials, ports, and Compose.
  --apply   Create only qBittorrent config/torrent paths, preserve or generate
            the shared management password, pull/start only qBittorrent, then
            bootstrap authentication, paths, categories, and safe preferences.
  --verify  Prove the exact two-container contract, authentication, mounts,
            paths, empty torrent list, loopback listener, and firewall state.

An explicit --previous-password-file is required to apply a rotated shared
password to an already configured qBittorrent. The file must be root-readable
and mode 0600; the password itself is never accepted as a command argument.

Private Web UI access uses a tunnel such as:
  ssh -N -L 8080:127.0.0.1:8080 user@host

This workflow never adds a torrent, enables a peer-port publication, configures
VPN/UPnP/NAT-PMP, touches the library tree, or starts another service.
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
  docker_cmd compose --project-directory "$REPO_ROOT" --env-file "$env_file" \
    -f "$BASE_COMPOSE" -f "$JELLYFIN_LOOPBACK_COMPOSE" -f "$QBITTORRENT_LOOPBACK_COMPOSE" -f "$ARR_LOOPBACK_COMPOSE" "$@"
}

file_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then stat -c '%a' "$1"; else stat -f '%Lp' "$1"; fi
}

valid_path() {
  [ -n "$1" ] && [[ $1 == /* ]] && [ "$1" != / ] && [[ $1 =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ /$1/ != */../* ]] && [[ /$1/ != */./* ]]
}

env_value() {
  local key=$1 file=${2:-$ENV_FILE}
  awk -F= -v wanted="$key" '
    $1 == wanted {count++; value=substr($0, index($0, "=") + 1)}
    END {if (count != 1) exit 1; print value}
  ' "$file"
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
  [ "$RUNTIME_UID" -gt 0 ] && [ "$RUNTIME_GID" -gt 0 ] || die "qBittorrent must not use root as its application identity"
}

require_commands() {
  local name
  for name in awk chmod chown cmp curl cut dirname docker find findmnt grep id install mktemp mv od python3 sed sleep sort ss stat tail tr; do
    command -v "$name" >/dev/null 2>&1 || die "required command missing: $name"
  done
  docker_cmd compose version >/dev/null 2>&1 || die "Docker Compose plugin is unavailable"
  docker_cmd info >/dev/null 2>&1 || die "Docker daemon is unavailable"
  pass "Docker Engine and Compose are available"
}

load_image_pins() {
  local count service repository tag digest
  count=$(awk -F'|' '$1 == "QBITTORRENT_IMAGE_TAG" {n++} END {print n+0}' "$IMAGE_LOCK")
  [ "$count" -eq 1 ] || die "qBittorrent image lock is missing or duplicated"
  QBITTORRENT_REPOSITORY=$(awk -F'|' '$1 == "QBITTORRENT_IMAGE_TAG" {print $2}' "$IMAGE_LOCK")
  QBITTORRENT_TAG=$(awk -F'|' '$1 == "QBITTORRENT_IMAGE_TAG" {print $3}' "$IMAGE_LOCK")
  QBITTORRENT_DIGEST=$(awk -F'|' '$1 == "QBITTORRENT_IMAGE_TAG" {print $4}' "$IMAGE_LOCK")
  QBITTORRENT_PIN=$QBITTORRENT_TAG@$QBITTORRENT_DIGEST
  QBITTORRENT_IMAGE=$QBITTORRENT_REPOSITORY:$QBITTORRENT_PIN
  [ "$QBITTORRENT_REPOSITORY" = lscr.io/linuxserver/qbittorrent ] || die "qBittorrent image repository is not the reviewed LinuxServer source"
  [[ $QBITTORRENT_DIGEST =~ ^sha256:[0-9a-f]{64}$ ]] || die "qBittorrent image digest is invalid"
  grep -Fq 'image: lscr.io/linuxserver/qbittorrent:${QBITTORRENT_IMAGE_TAG:?Set QBITTORRENT_IMAGE_TAG}' "$BASE_COMPOSE" || die "base Compose qBittorrent image contract changed"
  grep -Fxq "QBITTORRENT_IMAGE_TAG=$QBITTORRENT_PIN" "$ENV_EXAMPLE" || die "qBittorrent example pin does not match the lock"

  JELLYFIN_REPOSITORY=$(awk -F'|' '$1 == "JELLYFIN_IMAGE_TAG" {print $2}' "$IMAGE_LOCK")
  JELLYFIN_TAG=$(awk -F'|' '$1 == "JELLYFIN_IMAGE_TAG" {print $3}' "$IMAGE_LOCK")
  JELLYFIN_DIGEST=$(awk -F'|' '$1 == "JELLYFIN_IMAGE_TAG" {print $4}' "$IMAGE_LOCK")
  JELLYFIN_IMAGE=$JELLYFIN_REPOSITORY:$JELLYFIN_TAG@$JELLYFIN_DIGEST
  [[ $JELLYFIN_DIGEST =~ ^sha256:[0-9a-f]{64}$ ]] || die "Jellyfin image lock is invalid"
  for service in SONARR RADARR PROWLARR; do
    repository=$(awk -F'|' -v key="${service}_IMAGE_TAG" '$1 == key {print $2}' "$IMAGE_LOCK")
    tag=$(awk -F'|' -v key="${service}_IMAGE_TAG" '$1 == key {print $3}' "$IMAGE_LOCK")
    digest=$(awk -F'|' -v key="${service}_IMAGE_TAG" '$1 == key {print $4}' "$IMAGE_LOCK")
    [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || die "$service image lock is invalid"
    printf -v "${service}_IMAGE" '%s:%s@%s' "$repository" "$tag" "$digest"
  done
  pass "qBittorrent and Jellyfin image pins match the lock"
}

validate_loopback_override() {
  [ "$(grep -Ec '^[[:space:]]+host_ip:[[:space:]]+127\.0\.0\.1$' "$QBITTORRENT_LOOPBACK_COMPOSE")" -eq 1 ] || die "qBittorrent override must have exactly one loopback host_ip"
  [ "$(grep -Ec '^[[:space:]]+target:[[:space:]]+8080$' "$QBITTORRENT_LOOPBACK_COMPOSE")" -eq 1 ] || die "qBittorrent override must target TCP 8080 exactly once"
  [ "$(grep -Ec '^[[:space:]]+published:[[:space:]]+"?8080"?$' "$QBITTORRENT_LOOPBACK_COMPOSE")" -eq 1 ] || die "qBittorrent override must publish TCP 8080 exactly once"
  [ "$(grep -Ec '^[[:space:]]+protocol:[[:space:]]+tcp$' "$QBITTORRENT_LOOPBACK_COMPOSE")" -eq 1 ] || die "qBittorrent override must use TCP"
  if grep -Eq 'host_ip:[[:space:]]*(0\.0\.0\.0|::|\[::\])|network_mode:[[:space:]]*host|target:[[:space:]]*6881|published:[[:space:]]*"?6881' "$QBITTORRENT_LOOPBACK_COMPOSE"; then
    die "qBittorrent override contains a wildcard, host-network, or peer-port exposure"
  fi
  [ "$(grep -Ec '^[[:space:]]{2}[a-zA-Z0-9_-]+:$' "$QBITTORRENT_LOOPBACK_COMPOSE")" -eq 1 ] || die "qBittorrent override must contain one service"
  pass "qBittorrent bootstrap override is exactly loopback-only TCP 8080"
}

check_paths() {
  local component current=
  for path in "$CONFIG_ROOT" "$MEDIA_ROOT" "$DEPLOY_ROOT"; do valid_path "$path" || die "unsafe root path: $path"; done
  IFS=/ read -r -a components <<<"${CONFIG_ROOT#/}"
  for component in "${components[@]}"; do
    current=$current/$component
    [ ! -L "$current" ] || die "config-root path contains a symlink"
  done
  [ ! -e "$CONFIG_ROOT" ] || [ -d "$CONFIG_ROOT" ] || die "config root exists but is not a directory"
  [ "$CONFIG_ROOT" != "$MEDIA_ROOT" ] || die "config and media roots must differ"
  case "$CONFIG_ROOT/qbittorrent" in "$MEDIA_ROOT"/*) die "qBittorrent config must not reside below the media root" ;; esac
  pass "config, media, and deployment roots are safe"
}

check_media() {
  local target options path missing=0
  [ -d "$MEDIA_ROOT" ] || die "media root does not exist"
  target=$(findmnt -n -T "$MEDIA_ROOT" -o TARGET 2>/dev/null || true)
  [ "$target" = "$MEDIA_ROOT" ] || die "media root is not its own mounted filesystem"
  options=$(findmnt -n -T "$MEDIA_ROOT" -o OPTIONS 2>/dev/null || true)
  case ",$options," in *,rw,*) ;; *) die "media root is not mounted read-write on the host" ;; esac
  [ -d "$MEDIA_ROOT/torrents" ] || die "torrent root does not exist"
  for path in incomplete movies tv anime; do
    if [ ! -d "$MEDIA_ROOT/torrents/$path" ]; then info "apply will create required torrent directory: $path"; missing=$((missing + 1)); fi
  done
  pass "media root is mounted read-write and the torrent root is available ($missing subdirectories pending)"
}

existing_service_id() {
  docker_cmd ps -aq --filter "label=com.docker.compose.project=$PROJECT_NAME" --filter "label=com.docker.compose.service=$1"
}

verify_single_id() {
  local service=$1 id
  id=$(existing_service_id "$service")
  [ -n "$id" ] && [ "$(printf '%s\n' "$id" | awk 'NF {n++} END {print n+0}')" -eq 1 ] || return 1
  printf '%s\n' "$id"
}

check_existing_scope() {
  local jellyfin_id qbittorrent_id id service allowed
  jellyfin_id=$(verify_single_id jellyfin) || die "exactly one existing Jellyfin container is required"
  qbittorrent_id=$(existing_service_id qbittorrent)
  [ "$(printf '%s\n' "$qbittorrent_id" | awk 'NF {n++} END {print n+0}')" -le 1 ] || die "more than one qBittorrent container exists"
  allowed=$(for service in jellyfin qbittorrent sonarr radarr prowlarr; do existing_service_id "$service"; done)
  for id in $(docker_cmd ps -aq); do printf '%s\n' "$allowed" | grep -Fxq "$id" || die "a container outside the ARR deployment runtime exists"; done
  [ "$(docker_cmd inspect --format '{{.Config.Image}}' "$jellyfin_id")" = "$JELLYFIN_IMAGE" ] || die "existing Jellyfin image does not match the lock"
  [ "$(docker_cmd inspect --format '{{.State.Running}}|{{.State.Health.Status}}' "$jellyfin_id")" = 'true|healthy' ] || die "existing Jellyfin is not running and healthy"
  pass "container scope contains healthy Jellyfin and at most the intended qBittorrent"
}

check_image_scope() {
  local jellyfin_image_id qbittorrent_image_id id service image_id image_var allowed=
  jellyfin_image_id=$(docker_cmd image inspect --format '{{.Id}}' "$JELLYFIN_IMAGE" 2>/dev/null || true)
  [ -n "$jellyfin_image_id" ] || die "locked Jellyfin image is unavailable"
  qbittorrent_image_id=$(docker_cmd image inspect --format '{{.Id}}' "$QBITTORRENT_IMAGE" 2>/dev/null || true)
  allowed="$jellyfin_image_id\n$qbittorrent_image_id\n"
  for service in SONARR RADARR PROWLARR; do image_var=${service}_IMAGE; image_id=$(docker_cmd image inspect --format '{{.Id}}' "${!image_var}" 2>/dev/null || true); [ -z "$image_id" ] || allowed="$allowed$image_id\n"; done
  for id in $(docker_cmd images -q --no-trunc | sort -u); do printf '%b' "$allowed" | grep -Fxq "$id" || die "an unrelated image exists"; done
  pass "image scope contains only locked Jellyfin and optional qBittorrent"
}

check_port() {
  local intended
  if ss -H -lnt "sport = :$LOOPBACK_PORT" | grep -q .; then
    intended=$(existing_service_id qbittorrent)
    [ -n "$intended" ] || die "TCP 8080 is occupied by something other than the intended container"
  fi
  pass "TCP 8080 is available or belongs to the intended qBittorrent container"
}

check_env_contract() {
  local env_username env_password secret_path secret_password
  [ -f "$ENV_FILE" ] && [ ! -L "$ENV_FILE" ] || die "target-local environment is missing or unsafe"
  [ "$(file_mode "$ENV_FILE")" = 600 ] || die "target-local environment must be mode 0600"
  env_username=$(env_value MANAGEMENT_USERNAME) || die "MANAGEMENT_USERNAME is missing or duplicated"
  [[ $env_username =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "MANAGEMENT_USERNAME has invalid syntax"
  env_password=$(env_value MANAGEMENT_PASSWORD) || die "MANAGEMENT_PASSWORD is missing or duplicated"
  [ -z "$env_password" ] || [[ $env_password =~ ^[0-9a-f]{64}$ ]] || die "MANAGEMENT_PASSWORD has an unexpected format"
  secret_path=$RUNTIME_ROOT/secrets/management-password
  if [ -e "$secret_path" ]; then
    [ -f "$secret_path" ] && [ ! -L "$secret_path" ] && [ "$(file_mode "$secret_path")" = 600 ] || die "management-password file is unsafe"
    secret_password=$(tr -d '\r\n' <"$secret_path")
    [[ $secret_password =~ ^[0-9a-f]{64}$ ]] || die "management-password file has an unexpected format"
    [ -z "$env_password" ] || [ "$env_password" = "$secret_password" ] || die "environment and secret-file passwords disagree"
  fi
  MANAGEMENT_USERNAME=$env_username
  pass "target-local management credential contract is valid"
}

validate_compose() {
  local rendered_json
  compose_cmd "$ENV_FILE" config --quiet
  rendered_json=$(mktemp /tmp/veinfin-qbittorrent-compose.XXXXXX)
  ACTIVE_TEMP=$rendered_json
  chmod 0600 "$rendered_json"
  compose_cmd "$ENV_FILE" config --format json >"$rendered_json"
  python3 - "$rendered_json" <<'PY' || die "resolved Compose qBittorrent/Jellyfin bindings are unsafe"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
services = data["services"]
expected = {
    "qbittorrent": [{"name": "qbittorrent-bootstrap", "target": 8080, "published": "8080", "host_ip": "127.0.0.1", "protocol": "tcp", "mode": "ingress"}],
    "jellyfin": [{"name": "jellyfin-bootstrap", "target": 8096, "published": "8096", "host_ip": "127.0.0.1", "protocol": "tcp", "mode": "ingress"}],
}
for name, ports in expected.items():
    assert services[name].get("ports") == ports
PY
  rm -f "$rendered_json"; ACTIVE_TEMP=
  pass "resolved Compose configuration has only the approved loopback bindings"
}

run_checks() {
  require_commands
  runtime_identity
  load_image_pins
  validate_loopback_override
  check_paths
  check_media
  check_existing_scope
  check_image_scope
  check_port
  check_env_contract
  validate_compose
}

atomic_update_env_password() {
  local line replaced=0
  ACTIVE_TEMP=$(mktemp "$(dirname "$ENV_FILE")/.veinfin-qbittorrent-env.XXXXXX")
  chmod 0600 "$ACTIVE_TEMP"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      MANAGEMENT_PASSWORD=*) printf 'MANAGEMENT_PASSWORD=%s\n' "$MANAGEMENT_PASSWORD" >>"$ACTIVE_TEMP"; replaced=$((replaced + 1)) ;;
      *) printf '%s\n' "$line" >>"$ACTIVE_TEMP" ;;
    esac
  done <"$ENV_FILE"
  [ "$replaced" -eq 1 ] || die "cannot update missing or duplicate MANAGEMENT_PASSWORD"
  chown root:root "$ACTIVE_TEMP"
  mv -f "$ACTIVE_TEMP" "$ENV_FILE"
  ACTIVE_TEMP=
}

write_credential_artifacts() {
  local status=$1
  {
    printf 'VeinFin local credential summary\n'
    printf 'Generated for local administrative use. No Visit URL contains credentials.\n'
    printf 'Status: qBittorrent credentials %s.\n\n' "$status"
    printf 'Management username: %s\n' "$MANAGEMENT_USERNAME"
    printf 'Management password: %s\n' "$MANAGEMENT_PASSWORD"
    printf 'Applied use: qBittorrent Web UI and API.\n'
    printf 'Jellyfin viewer accounts and future application API keys remain separate.\n'
  } | vf_atomic_write "$RUNTIME_ROOT/secrets/credentials-summary.txt" 0600

  {
    printf '# Non-secret application bootstrap state.\n'
    printf 'QBITTORRENT_MANAGEMENT_PASSWORD_SOURCE=MANAGEMENT_PASSWORD\n'
    printf 'QBITTORRENT_MANAGEMENT_CREDENTIAL_STATUS=%s\n' "$(printf '%s' "$status" | tr '[:lower:] ' '[:upper:]_')"
    printf 'SONARR_API_KEY=PENDING_BOOTSTRAP\nRADARR_API_KEY=PENDING_BOOTSTRAP\nPROWLARR_API_KEY=PENDING_BOOTSTRAP\n'
    printf 'BAZARR_API_KEY=PENDING_BOOTSTRAP\nSEERR_API_KEY=PENDING_BOOTSTRAP\n'
  } | vf_atomic_write "$RUNTIME_ROOT/state/bootstrap-status.env" 0600
}

prepare_credentials() {
  local env_password secret_path secret_password
  install -d -o root -g root -m 0700 "$RUNTIME_ROOT" "$RUNTIME_ROOT/secrets" "$RUNTIME_ROOT/state"
  secret_path=$RUNTIME_ROOT/secrets/management-password
  env_password=$(env_value MANAGEMENT_PASSWORD)
  if [ -f "$secret_path" ]; then
    [ ! -L "$secret_path" ] && [ "$(file_mode "$secret_path")" = 600 ] || die "management-password file is unsafe"
    secret_password=$(tr -d '\r\n' <"$secret_path")
    [ -z "$env_password" ] || [ "$env_password" = "$secret_password" ] || die "refusing inconsistent management secrets"
    MANAGEMENT_PASSWORD=$secret_password
  elif [ -n "$env_password" ]; then
    MANAGEMENT_PASSWORD=$env_password
    printf '%s\n' "$MANAGEMENT_PASSWORD" | vf_atomic_write "$secret_path" 0600
    chown root:root "$secret_path"
  else
    MANAGEMENT_PASSWORD=$(vf_random_hex 32)
    printf '%s\n' "$MANAGEMENT_PASSWORD" | vf_atomic_write "$secret_path" 0600
    chown root:root "$secret_path"
  fi
  [[ $MANAGEMENT_PASSWORD =~ ^[0-9a-f]{64}$ ]] || die "management password has an unexpected format"
  atomic_update_env_password
  write_credential_artifacts 'pending application'
  pass "shared management credentials are protected and preserved"
}

prepare_directories() {
  local path
  install -d -m 0755 "$CONFIG_ROOT"
  [ ! -L "$CONFIG_ROOT/qbittorrent" ] || die "refusing symlinked qBittorrent config directory"
  install -d -o "$RUNTIME_UID" -g "$RUNTIME_GID" -m 0700 "$CONFIG_ROOT/qbittorrent"
  for path in "$MEDIA_ROOT/torrents" "$MEDIA_ROOT/torrents/incomplete" "$MEDIA_ROOT/torrents/movies" "$MEDIA_ROOT/torrents/tv" "$MEDIA_ROOT/torrents/anime"; do
    [ ! -L "$path" ] || die "refusing symlinked torrent directory"
    install -d -o "$RUNTIME_UID" -g "$RUNTIME_GID" -m 0775 "$path"
  done
  pass "protected qBittorrent config and required torrent directories are ready"
}

snapshot_listeners() { ss -H -lntu | awk '{print $1, $5}' | sort -u; }

record_listener_baseline() {
  local baseline=$RUNTIME_ROOT/state/qbittorrent-listeners-before.txt
  [ ! -L "$baseline" ] || die "refusing symlinked listener baseline"
  if [ -e "$baseline" ]; then
    [ -f "$baseline" ] && [ "$(file_mode "$baseline")" = 600 ] || die "listener baseline permissions are unsafe"
    return 0
  fi
  ACTIVE_TEMP=$(mktemp "$RUNTIME_ROOT/state/.qbittorrent-listeners-before.XXXXXX")
  chmod 0600 "$ACTIVE_TEMP"
  snapshot_listeners >"$ACTIVE_TEMP"
  chown root:root "$ACTIVE_TEMP"
  mv -f "$ACTIVE_TEMP" "$baseline"
  ACTIVE_TEMP=
}

verify_listener_delta() {
  local baseline current
  baseline=$RUNTIME_ROOT/state/qbittorrent-listeners-before.txt
  [ -f "$baseline" ] && [ ! -L "$baseline" ] && [ "$(file_mode "$baseline")" = 600 ] || die "protected qBittorrent listener baseline is missing or unsafe"
  grep -Fxq "tcp 127.0.0.1:$LOOPBACK_PORT" "$baseline" && die "qBittorrent listener baseline was captured after startup"
  current=$(mktemp /tmp/veinfin-qbittorrent-listeners.XXXXXX)
  ACTIVE_TEMP=$current
  snapshot_listeners | awk -v allowed="tcp 127.0.0.1:$LOOPBACK_PORT" '$0 != allowed && $0 != "tcp 127.0.0.1:8989" && $0 != "tcp 127.0.0.1:7878" && $0 != "tcp 127.0.0.1:9696"' >"$current"
  cmp -s "$baseline" "$current" || die "host listeners changed beyond loopback-only qBittorrent"
  rm -f "$current"; ACTIVE_TEMP=
  pass "listener delta contains only loopback TCP 8080"
}

wait_for_health() {
  local id=$1 attempt=0 health
  while [ "$attempt" -lt 36 ]; do
    health=$(docker_cmd inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "$id")
    [ "$health" = healthy ] && return 0
    [ "$health" != unhealthy ] || die "qBittorrent reported unhealthy"
    attempt=$((attempt + 1)); sleep 5
  done
  die "qBittorrent did not become healthy within three minutes"
}

ensure_work_dir() {
  if [ -z "$WORK_DIR" ]; then WORK_DIR=$(mktemp -d /run/veinfin-qbittorrent.XXXXXX); chmod 0700 "$WORK_DIR"; fi
}

login_with_file() {
  local username=$1 password_file=$2 cookie_file=$3 body_file request_file code
  ensure_work_dir
  body_file=$WORK_DIR/login-body
  request_file=$WORK_DIR/login-request
  python3 - "$password_file" "$request_file" "$username" <<'PY'
import pathlib, sys, urllib.parse
password = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").rstrip("\r\n")
pathlib.Path(sys.argv[2]).write_text(
    urllib.parse.urlencode({"username": sys.argv[3], "password": password}),
    encoding="utf-8",
)
PY
  chmod 0600 "$request_file"
  : >"$cookie_file"; chmod 0600 "$cookie_file"
  code=$(curl --silent --show-error --output "$body_file" --write-out '%{http_code}' \
    --cookie-jar "$cookie_file" --header "Referer: $BASE_URL" \
    --data-binary "@$request_file" \
    "$BASE_URL/api/v2/auth/login" 2>/dev/null || true)
  case "$code" in
    200) grep -qx 'Ok\.' "$body_file" || return 1 ;;
    204) : ;;
    *) return 1 ;;
  esac
  # qBittorrent 5 may scope the session cookie name to the Web UI port
  # (for example QBT_SID_8080), while older releases use SID.
  grep -Eq $'\t(SID|QBT_SID(_[0-9]+)?)\t' "$cookie_file"
}

api_get() {
  local cookie_file=$1 endpoint=$2 output_file=$3
  curl --silent --show-error --fail --cookie "$cookie_file" --header "Referer: $BASE_URL" \
    --output "$output_file" "$BASE_URL/api/v2/$endpoint"
  chmod 0600 "$output_file"
}

api_post_file() {
  local cookie_file=$1 endpoint=$2 request_file=$3 response_file code
  response_file=$WORK_DIR/api-response
  code=$(curl --silent --show-error --output "$response_file" --write-out '%{http_code}' \
    --cookie "$cookie_file" --header "Referer: $BASE_URL" --data-binary "@$request_file" \
    "$BASE_URL/api/v2/$endpoint" 2>/dev/null || true)
  [ "$code" = 200 ] || die "qBittorrent API request failed: $endpoint"
}

write_preferences_request() {
  local request_file=$1
  {
    printf 'json={"save_path":"/data/torrents","temp_path_enabled":true,"temp_path":"/data/torrents/incomplete",'
    printf '"scan_dirs":{},"upnp":false,"web_ui_upnp":false,"max_ratio_act":0,"auto_delete_mode":0,'
    printf '"rss_processing_enabled":false,"add_trackers_enabled":false,"bypass_local_auth":false,'
    printf '"bypass_auth_subnet_whitelist_enabled":false,"bypass_auth_subnet_whitelist":"",'
    printf '"web_ui_csrf_protection_enabled":true,"web_ui_clickjacking_protection_enabled":true,'
    printf '"web_ui_host_header_validation_enabled":true,"web_ui_username":"%s","web_ui_password":"%s"}' \
      "$MANAGEMENT_USERNAME" "$MANAGEMENT_PASSWORD"
  } >"$request_file"
  chmod 0600 "$request_file"
}

configure_categories() {
  local cookie_file=$1 categories_file torrents_file name path existing request
  categories_file=$WORK_DIR/categories
  torrents_file=$WORK_DIR/torrents-before-category-repair
  api_get "$cookie_file" torrents/categories "$categories_file"
  for name in movies tv anime; do
    path=/data/torrents/$name
    existing=$(python3 - "$categories_file" "$name" "$path" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
entry = data.get(sys.argv[2])
if entry is None:
    print("__MISSING__")
elif entry.get("savePath", "") == sys.argv[3]:
    print("__EXACT__")
else:
    print("__MISMATCH__")
PY
)
    [ "$existing" != __EXACT__ ] || continue
    request=$WORK_DIR/category-request
    printf 'category=%s&savePath=%s' "$name" "$path" >"$request"; chmod 0600 "$request"
    if [ "$existing" = __MISSING__ ]; then
      api_post_file "$cookie_file" torrents/createCategory "$request"
    else
      api_get "$cookie_file" torrents/info "$torrents_file"
      python3 - "$torrents_file" <<'PY' || die "refusing to replace a category while torrents exist"
import json, sys
assert json.load(open(sys.argv[1], encoding="utf-8")) == []
PY
      printf 'categories=%s' "$name" >"$request"; chmod 0600 "$request"
      api_post_file "$cookie_file" torrents/removeCategories "$request"
      printf 'category=%s&savePath=%s' "$name" "$path" >"$request"; chmod 0600 "$request"
      api_post_file "$cookie_file" torrents/createCategory "$request"
    fi
    api_get "$cookie_file" torrents/categories "$categories_file"
  done
}

capture_temporary_password() {
  local id=$1 logs_file=$WORK_DIR/container-logs password_file=$WORK_DIR/temporary-password
  docker_cmd logs "$id" >"$logs_file" 2>&1
  chmod 0600 "$logs_file"
  sed -n '/temporary password is provided for this session:/s/.*session:[[:space:]]*//p' "$logs_file" | tail -n 1 | tr -d '\r' >"$password_file"
  chmod 0600 "$password_file"
  [ -s "$password_file" ] || die "qBittorrent temporary password could not be captured securely"
  [ "$(wc -l <"$password_file" | tr -d ' ')" -eq 1 ] || die "qBittorrent temporary password capture was ambiguous"
  printf '%s\n' "$password_file"
}

bootstrap_qbittorrent() {
  local id=$1 configured_cookie source_cookie new_cookie source_password source_username mode=existing request logs default_file
  ensure_work_dir
  configured_cookie=$WORK_DIR/configured-cookie
  if login_with_file "$MANAGEMENT_USERNAME" "$RUNTIME_ROOT/secrets/management-password" "$configured_cookie"; then
    info "existing qBittorrent management credentials were preserved"
  else
    if [ -n "$PREVIOUS_PASSWORD_FILE" ]; then
      [ -f "$PREVIOUS_PASSWORD_FILE" ] && [ ! -L "$PREVIOUS_PASSWORD_FILE" ] && [ "$(file_mode "$PREVIOUS_PASSWORD_FILE")" = 600 ] || die "previous-password file must be a regular mode-0600 file"
      source_password=$PREVIOUS_PASSWORD_FILE
      source_username=$MANAGEMENT_USERNAME
      mode=rotation
    else
      source_password=$(capture_temporary_password "$id")
      source_username=admin
      mode=temporary
    fi
    source_cookie=$WORK_DIR/source-cookie
    login_with_file "$source_username" "$source_password" "$source_cookie" || die "qBittorrent bootstrap authentication failed"
    request=$WORK_DIR/preferences-request
    write_preferences_request "$request"
    api_post_file "$source_cookie" app/setPreferences "$request"
    new_cookie=$WORK_DIR/new-cookie
    login_with_file "$MANAGEMENT_USERNAME" "$RUNTIME_ROOT/secrets/management-password" "$new_cookie" || die "configured qBittorrent credentials were not accepted"
    configured_cookie=$new_cookie
  fi

  request=$WORK_DIR/preferences-request
  write_preferences_request "$request"
  api_post_file "$configured_cookie" app/setPreferences "$request"
  configured_cookie=$WORK_DIR/final-cookie
  login_with_file "$MANAGEMENT_USERNAME" "$RUNTIME_ROOT/secrets/management-password" "$configured_cookie" || die "configured qBittorrent credentials failed after preference update"
  configure_categories "$configured_cookie"

  if [ "$mode" != existing ]; then
    compose_cmd "$ENV_FILE" up -d --no-deps --force-recreate qbittorrent
    id=$(verify_single_id qbittorrent) || die "qBittorrent recreation failed"
    wait_for_health "$id"
    if login_with_file "$source_username" "$source_password" "$WORK_DIR/obsolete-cookie"; then die "obsolete qBittorrent credentials still authenticate"; fi
  fi

  default_file=$WORK_DIR/default-password
  printf 'adminadmin\n' >"$default_file"; chmod 0600 "$default_file"
  if login_with_file admin "$default_file" "$WORK_DIR/default-cookie"; then die "default qBittorrent credentials authenticate"; fi
  login_with_file "$MANAGEMENT_USERNAME" "$RUNTIME_ROOT/secrets/management-password" "$WORK_DIR/verified-cookie" || die "configured qBittorrent credentials do not authenticate"
  logs=$(docker_cmd logs "$id" 2>&1)
  case "$logs" in *'temporary password is provided for this session:'*) die "current qBittorrent logs retain a temporary password" ;; esac
  unset logs
  pass "qBittorrent credentials are applied; default and obsolete credentials are rejected"
}

verify_mounts() {
  local id=$1 mounts expected_config expected_torrents
  mounts=$(docker_cmd inspect --format '{{range .Mounts}}{{println .Source "|" .Destination "|" .RW}}{{end}}' "$id")
  expected_config="$CONFIG_ROOT/qbittorrent | /config | true"
  expected_torrents="$MEDIA_ROOT/torrents | /data/torrents | true"
  printf '%s\n' "$mounts" | grep -Fxq "$expected_config" || die "qBittorrent config mount is missing or not writable"
  printf '%s\n' "$mounts" | grep -Fxq "$expected_torrents" || die "qBittorrent torrent mount is missing or not writable"
  [ "$(printf '%s\n' "$mounts" | awk 'NF {n++} END {print n+0}')" -eq 2 ] || die "qBittorrent has an unexpected mount"
  printf '%s\n' "$mounts" | grep -qi library && die "qBittorrent must not receive a library mount"
  docker_cmd exec "$id" sh -c 'test -w /config && test -w /data/torrents && test -w /data/torrents/incomplete && test -w /data/torrents/movies && test -w /data/torrents/tv && test -w /data/torrents/anime' || die "qBittorrent required paths are not writable"
  pass "qBittorrent has only writable config and torrent-tree mounts"
}

verify_port_binding() {
  local id=$1 bindings listeners
  bindings=$(docker_cmd inspect --format '{{range $port, $entries := .NetworkSettings.Ports}}{{range $entries}}{{println $port "|" .HostIp "|" .HostPort}}{{end}}{{end}}' "$id")
  [ "$bindings" = '8080/tcp | 127.0.0.1 | 8080' ] || die "qBittorrent must publish only loopback TCP 8080 and no peer port"
  listeners=$(ss -H -lnt "sport = :$LOOPBACK_PORT")
  [ "$(printf '%s\n' "$listeners" | awk 'NF {n++} END {print n+0}')" -eq 1 ] || die "TCP 8080 does not have exactly one listener"
  printf '%s\n' "$listeners" | awk '$4 == "127.0.0.1:8080" {ok=1} END {exit !ok}' || die "TCP 8080 is not loopback-only"
  pass "host TCP 8080 is loopback-only and no peer port is published"
}

verify_api_contract() {
  local cookie prefs categories torrents version
  ensure_work_dir
  cookie=$WORK_DIR/verify-cookie
  login_with_file "$MANAGEMENT_USERNAME" "$RUNTIME_ROOT/secrets/management-password" "$cookie" || die "configured qBittorrent authentication failed"
  prefs=$WORK_DIR/preferences; categories=$WORK_DIR/categories; torrents=$WORK_DIR/torrents; version=$WORK_DIR/version
  api_get "$cookie" app/preferences "$prefs"
  api_get "$cookie" torrents/categories "$categories"
  api_get "$cookie" torrents/info "$torrents"
  api_get "$cookie" app/version "$version"
  python3 - "$prefs" "$MANAGEMENT_USERNAME" <<'PY' || die "qBittorrent preferences do not match the security/path contract"
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
expected = {
    "save_path": "/data/torrents",
    "temp_path_enabled": True,
    "temp_path": "/data/torrents/incomplete",
    "upnp": False,
    "web_ui_upnp": False,
    "max_ratio_act": 0,
    "auto_delete_mode": 0,
    "rss_processing_enabled": False,
    "add_trackers_enabled": False,
    "bypass_local_auth": False,
    "bypass_auth_subnet_whitelist_enabled": False,
    "web_ui_csrf_protection_enabled": True,
    "web_ui_clickjacking_protection_enabled": True,
    "web_ui_host_header_validation_enabled": True,
    "web_ui_username": sys.argv[2],
}
assert all(p.get(k) == v for k, v in expected.items())
assert p.get("scan_dirs", {}) == {}
PY
  python3 - "$categories" <<'PY' || die "qBittorrent categories do not match exact paths"
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8"))
expected = {name: f"/data/torrents/{name}" for name in ("movies", "tv", "anime")}
assert set(c) == set(expected)
assert all(c[name].get("savePath") == path for name, path in expected.items())
PY
  python3 - "$torrents" <<'PY' || die "qBittorrent contains a torrent"
import json, sys
assert json.load(open(sys.argv[1], encoding="utf-8")) == []
PY
  QBITTORRENT_VERSION=$(tr -d '\r\n' <"$version")
  [ -n "$QBITTORRENT_VERSION" ] || die "qBittorrent version is unavailable"
  pass "qBittorrent API authentication, preferences, categories, and empty torrent list are valid"
}

jellyfin_fingerprint() {
  local id
  id=$(verify_single_id jellyfin) || return 1
  docker_cmd inspect --format '{{.Id}}|{{.State.StartedAt}}|{{.RestartCount}}|{{.Config.Image}}|{{.State.Health.Status}}' "$id"
}

run_verify() {
  local jellyfin_id qbittorrent_id count image_count image service running_health devices privileged network_mode arr_count=0 arr_id arr_image_var arr_port arr_binding
  require_commands
  runtime_identity
  load_image_pins
  check_paths
  check_media
  check_env_contract
  jellyfin_id=$(verify_single_id jellyfin) || die "exactly one Jellyfin container is required"
  qbittorrent_id=$(verify_single_id qbittorrent) || die "exactly one qBittorrent container is required"
  count=$(docker_cmd ps -aq | awk 'NF {n++} END {print n+0}')
  for service in sonarr radarr prowlarr; do arr_id=$(existing_service_id "$service"); [ -z "$arr_id" ] || arr_count=$((arr_count + 1)); done
  { [ "$arr_count" -eq 0 ] || [ "$arr_count" -eq 3 ]; } || die "ARR deployment automation services must be all absent or all present"
  [ "$count" -eq $((2 + arr_count)) ] || die "runtime contains a container outside the approved services"
  image_count=$(docker_cmd images -q --no-trunc | sort -u | awk 'NF {n++} END {print n+0}')
  [ "$image_count" -eq $((2 + arr_count)) ] || die "runtime contains an image outside the approved services"
  [ "$(docker_cmd inspect --format '{{.Config.Image}}|{{.State.Running}}|{{.State.Health.Status}}' "$jellyfin_id")" = "$JELLYFIN_IMAGE|true|healthy" ] || die "Jellyfin identity or health changed"
  service=$(docker_cmd inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$qbittorrent_id")
  image=$(docker_cmd inspect --format '{{.Config.Image}}' "$qbittorrent_id")
  running_health=$(docker_cmd inspect --format '{{.State.Running}}|{{.State.Health.Status}}' "$qbittorrent_id")
  devices=$(docker_cmd inspect --format '{{json .HostConfig.Devices}}' "$qbittorrent_id")
  privileged=$(docker_cmd inspect --format '{{.HostConfig.Privileged}}' "$qbittorrent_id")
  network_mode=$(docker_cmd inspect --format '{{.HostConfig.NetworkMode}}' "$qbittorrent_id")
  [ "$service" = qbittorrent ] && [ "$image" = "$QBITTORRENT_IMAGE" ] || die "qBittorrent identity or image is incorrect"
  [ "$running_health" = 'true|healthy' ] || die "qBittorrent is not running and healthy"
  { [ "$devices" = '[]' ] || [ "$devices" = null ]; } && [ "$privileged" = false ] && [ "$network_mode" != host ] || die "qBittorrent host access is unsafe"
  verify_mounts "$qbittorrent_id"
  verify_port_binding "$qbittorrent_id"
  verify_listener_delta
  verify_api_contract
  if [ "$arr_count" -eq 3 ]; then
    for service in sonarr radarr prowlarr; do
      case "$service" in sonarr) arr_image_var=SONARR_IMAGE; arr_port=8989;; radarr) arr_image_var=RADARR_IMAGE; arr_port=7878;; prowlarr) arr_image_var=PROWLARR_IMAGE; arr_port=9696;; esac
      arr_id=$(verify_single_id "$service") || die "$service container is missing"
      [ "$(docker_cmd inspect --format '{{.Config.Image}}|{{.State.Running}}|{{.State.Health.Status}}' "$arr_id")" = "${!arr_image_var}|true|healthy" ] || die "$service identity or health is invalid"
      arr_binding=$(docker_cmd inspect --format '{{range $port,$entries:=.NetworkSettings.Ports}}{{range $entries}}{{println $port "|" .HostIp "|" .HostPort}}{{end}}{{end}}' "$arr_id")
      [ "$arr_binding" = "$arr_port/tcp | 127.0.0.1 | $arr_port" ] || die "$service binding is unsafe"
    done
  fi
  if ss -H -lnt 'sport = :80 or sport = :443 or sport = :3000 or sport = :5055 or sport = :6767 or sport = :2375 or sport = :2376' | grep -q .; then die "an unrelated application, public, or Docker API port is listening"; fi
  [ -x /usr/local/sbin/veinfin-firewall ] || die "VeinFin firewall verifier is unavailable"
  as_root /usr/local/sbin/veinfin-firewall --verify >/dev/null || die "VeinFin firewall verification failed"
  pass "Jellyfin/qBittorrent and optional ARR deployment runtime, firewall, and Docker API contract is valid"
}

run_check() {
  run_checks
  info "Read-only qBittorrent check passed; no file, directory, image, network, container, credential, or application setting was changed"
}

run_apply() {
  local jellyfin_before jellyfin_after rsync_before rsync_after id
  require_root "--apply"
  jellyfin_before=$(jellyfin_fingerprint) || die "existing Jellyfin identity cannot be captured"
  rsync_before=$(pgrep -xc rsync 2>/dev/null || true)
  run_checks
  prepare_directories
  prepare_credentials
  record_listener_baseline
  validate_compose
  compose_cmd "$ENV_FILE" pull qbittorrent
  compose_cmd "$ENV_FILE" up -d --no-deps qbittorrent
  id=$(verify_single_id qbittorrent) || die "Compose did not create exactly one qBittorrent container"
  wait_for_health "$id"
  bootstrap_qbittorrent "$id"
  run_verify
  jellyfin_after=$(jellyfin_fingerprint) || die "Jellyfin disappeared during qBittorrent deployment"
  [ "$jellyfin_before" = "$jellyfin_after" ] || die "Jellyfin was restarted or modified during qBittorrent deployment"
  rsync_after=$(pgrep -xc rsync 2>/dev/null || true)
  [ "$rsync_before" = "$rsync_after" ] || die "external rsync process count changed during qBittorrent deployment"
  write_credential_artifacts applied
  pass "qBittorrent-only deployment and bootstrap completed without changing Jellyfin"
}

if [ "${VEINFIN_QBITTORRENT_LIBRARY_ONLY:-0}" = 1 ]; then
  return 0 2>/dev/null || exit 0
fi

mode=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|--check|--apply|--verify)
      [ -z "$mode" ] || { usage; exit 2; }
      mode=$1; shift ;;
    --previous-password-file)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      PREVIOUS_PASSWORD_FILE=$2; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[ -n "$mode" ] || { usage; exit 2; }
[ -z "$PREVIOUS_PASSWORD_FILE" ] || [ "$mode" = --apply ] || die "--previous-password-file is valid only with --apply"
case "$mode" in
  --help) [ -z "$PREVIOUS_PASSWORD_FILE" ] || { usage; exit 2; }; usage ;;
  --check)
    if [ "$EUID" -ne 0 ] && [ ! -r "$ENV_FILE" ]; then
      command -v sudo >/dev/null 2>&1 || die "--check requires read access to protected target configuration"
      exec sudo -n --preserve-env=SSH_CONNECTION "$0" --check
    fi
    run_check ;;
  --apply) run_apply ;;
  --verify) run_verify ;;
esac
