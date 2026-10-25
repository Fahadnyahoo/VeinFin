#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=${VEINFIN_REPO_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd -P)}
BASE_COMPOSE=$REPO_ROOT/compose.yaml
JELLYFIN_LOOPBACK=$REPO_ROOT/compose/jellyfin-loopback.yaml
QBITTORRENT_LOOPBACK=$REPO_ROOT/compose/qbittorrent-loopback.yaml
ARR_LOOPBACK=$REPO_ROOT/compose/arr-loopback.yaml
IMAGE_LOCK=$REPO_ROOT/config/images.lock
ENV_EXAMPLE=$REPO_ROOT/.env.example
ENV_FILE=${VEINFIN_ENV_FILE:-$REPO_ROOT/.env}
API_HELPER=$REPO_ROOT/scripts/deploy/arr_api.py
DEPLOY_ROOT=${VEINFIN_DEPLOY_ROOT:-$REPO_ROOT}
CONFIG_ROOT=${VEINFIN_CONFIG_ROOT:-/var/lib/veinfin}
MEDIA_ROOT=${VEINFIN_MEDIA_ROOT:-/srv/media}
RUNTIME_ROOT=$DEPLOY_ROOT/runtime
PROJECT_NAME=${VEINFIN_PROJECT_NAME:-veinfin}
WORK_DIR=
TEST_TORRENT_DIR=
TEST_LIBRARY_DIR=

# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/lib/common.sh"

info() { printf 'INFO: %s\n' "$*"; }
pass() { printf 'PASS: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
cleanup() {
  if [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ]; then find "$WORK_DIR" -depth -delete 2>/dev/null || true; fi
  if [ -n "${TEST_TORRENT_DIR:-}" ] && [ -d "$TEST_TORRENT_DIR" ]; then find "$TEST_TORRENT_DIR" -depth -delete 2>/dev/null || true; fi
  if [ -n "${TEST_LIBRARY_DIR:-}" ] && [ -d "$TEST_LIBRARY_DIR" ]; then find "$TEST_LIBRARY_DIR" -depth -delete 2>/dev/null || true; fi
  vf_cleanup
}
trap cleanup EXIT HUP INT TERM

usage() {
  cat <<'EOF'
VeinFin Sonarr/Radarr/Prowlarr deployment and integration

Usage:
  scripts/deploy/arr.sh --help
  scripts/deploy/arr.sh --check
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/arr.sh --apply
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/arr.sh --verify

Modes:
  --check   Read-only validation of locks, storage, existing services,
            credentials, loopback exposure, and resolved Compose.
  --apply   Pull/start only Sonarr, Radarr, and Prowlarr with --no-deps, then
            configure protected authentication and exact integrations.
  --verify  Prove the five-container runtime, empty application state, exact
            mounts/paths/connections, hardlinks, and network isolation.

Private access uses generic operator-side tunnels:
  ssh -N -L 8989:127.0.0.1:8989 user@host
  ssh -N -L 7878:127.0.0.1:7878 user@host
  ssh -N -L 9696:127.0.0.1:9696 user@host

This workflow never adds a torrent, movie, series, indexer, remote path mapping,
or FlareSolverr connection, and never scans or imports the existing library.
EOF
}

require_root() { [ "$EUID" -eq 0 ] || die "$1 must run as root (use sudo)"; }
as_root() { if [ "$EUID" -eq 0 ]; then "$@"; else sudo -n --preserve-env=SSH_CONNECTION "$@"; fi; }
docker_cmd() { as_root docker "$@"; }
compose_cmd() {
  local env_file=$1; shift
  docker_cmd compose --project-directory "$REPO_ROOT" --env-file "$env_file" \
    -f "$BASE_COMPOSE" -f "$JELLYFIN_LOOPBACK" -f "$QBITTORRENT_LOOPBACK" -f "$ARR_LOOPBACK" "$@"
}
file_mode() { if stat -c '%a' "$1" >/dev/null 2>&1; then stat -c '%a' "$1"; else stat -f '%Lp' "$1"; fi; }
valid_path() { [ -n "$1" ] && [[ $1 == /* ]] && [ "$1" != / ] && [[ $1 =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ /$1/ != */../* ]] && [[ /$1/ != */./* ]]; }
env_value() { awk -F= -v key="$1" '$1==key{n++;v=substr($0,index($0,"=")+1)}END{if(n!=1)exit 1;print v}' "${2:-$ENV_FILE}"; }
ensure_work() { if [ -z "$WORK_DIR" ]; then WORK_DIR=$(mktemp -d /tmp/veinfin-arr.XXXXXX); chmod 0700 "$WORK_DIR"; fi; }

runtime_identity() {
  local user_name
  if [ -n "${VEINFIN_RUNTIME_USER:-}" ]; then user_name=$VEINFIN_RUNTIME_USER
  elif [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then user_name=$SUDO_USER
  elif [ "$EUID" -ne 0 ]; then user_name=$(id -un)
  else die "cannot determine the non-root runtime SSH user; invoke through sudo"; fi
  RUNTIME_UID=$(id -u "$user_name"); RUNTIME_GID=$(id -g "$user_name")
  [ "$RUNTIME_UID" -gt 0 ] && [ "$RUNTIME_GID" -gt 0 ] || die "automation services must not run as root"
}

require_commands() {
  local cmd
  for cmd in awk chmod chown cmp curl docker find findmnt grep id install ln mktemp od pgrep python3 sort ss stat tr; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command missing: $cmd"
  done
  [ -x "$API_HELPER" ] || die "protected API helper is unavailable"
  docker_cmd compose version >/dev/null 2>&1 || die "Docker Compose plugin is unavailable"
  docker_cmd info >/dev/null 2>&1 || die "Docker daemon is unavailable"
  pass "Docker Engine and Compose are available"
}

lock_line() { awk -F'|' -v key="$1" '$1==key{print $2"|"$3"|"$4"|"$5}' "$IMAGE_LOCK"; }
load_image_pins() {
  local spec key expected repository tag digest platforms count
  for spec in 'JELLYFIN_IMAGE_TAG|jellyfin/jellyfin' 'QBITTORRENT_IMAGE_TAG|lscr.io/linuxserver/qbittorrent' \
              'SONARR_IMAGE_TAG|lscr.io/linuxserver/sonarr' 'RADARR_IMAGE_TAG|lscr.io/linuxserver/radarr' \
              'PROWLARR_IMAGE_TAG|lscr.io/linuxserver/prowlarr'; do
    key=${spec%%|*}; expected=${spec#*|}; count=$(awk -F'|' -v key="$key" '$1==key{n++}END{print n+0}' "$IMAGE_LOCK")
    [ "$count" -eq 1 ] || die "$key lock is missing or duplicated"
    IFS='|' read -r repository tag digest platforms <<<"$(lock_line "$key")"
    [ "$repository" = "$expected" ] || die "$key repository is unreviewed"
    [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || die "$key digest is invalid"
    case ",$platforms," in *,amd64,*) ;; *) die "$key lacks Linux amd64";; esac
    grep -Fxq "$key=$tag@$digest" "$ENV_EXAMPLE" || die "$key example and lock disagree"
    case "$key" in
      JELLYFIN_IMAGE_TAG) JELLYFIN_IMAGE=$repository:$tag@$digest;;
      QBITTORRENT_IMAGE_TAG) QBITTORRENT_IMAGE=$repository:$tag@$digest;;
      SONARR_IMAGE_TAG) SONARR_IMAGE=$repository:$tag@$digest;;
      RADARR_IMAGE_TAG) RADARR_IMAGE=$repository:$tag@$digest;;
      PROWLARR_IMAGE_TAG) PROWLARR_IMAGE=$repository:$tag@$digest;;
    esac
  done
  pass "all five image identities match reviewed Linux amd64 locks"
}

validate_loopback() {
  local service port
  for service in sonarr radarr prowlarr; do
    case "$service" in sonarr) port=8989;; radarr) port=7878;; prowlarr) port=9696;; esac
    [ "$(grep -Ec "^[[:space:]]+-[[:space:]]+name:[[:space:]]+$service-bootstrap$" "$ARR_LOOPBACK")" -eq 1 ] || die "$service loopback entry is missing"
    [ "$(grep -Ec "^[[:space:]]+target:[[:space:]]+$port$" "$ARR_LOOPBACK")" -eq 1 ] || die "$service target is unsafe"
    [ "$(grep -Ec "^[[:space:]]+published:[[:space:]]+\"?$port\"?$" "$ARR_LOOPBACK")" -eq 1 ] || die "$service publication is unsafe"
  done
  [ "$(grep -Ec '^[[:space:]]+host_ip:[[:space:]]+127\.0\.0\.1$' "$ARR_LOOPBACK")" -eq 3 ] || die "all three UIs must bind IPv4 loopback"
  if grep -Eq 'host_ip:[[:space:]]*(0\.0\.0\.0|::|\[::\]|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)|network_mode:[[:space:]]*host' "$ARR_LOOPBACK"; then
    die "wildcard, LAN, IPv6, or host-network binding found"
  fi
  pass "automation override is exactly loopback-only"
}

check_media() {
  local path component current= target options
  for path in "$CONFIG_ROOT" "$MEDIA_ROOT" "$DEPLOY_ROOT"; do valid_path "$path" || die "unsafe root: $path"; done
  IFS=/ read -r -a components <<<"${CONFIG_ROOT#/}"
  for component in "${components[@]}"; do current=$current/$component; [ ! -L "$current" ] || die "config root contains a symlink"; done
  [ "$CONFIG_ROOT" != "$MEDIA_ROOT" ] || die "config and media roots must differ"
  target=$(findmnt -n -T "$MEDIA_ROOT" -o TARGET 2>/dev/null || true); [ "$target" = "$MEDIA_ROOT" ] || die "media root is not its own mount"
  options=$(findmnt -n -T "$MEDIA_ROOT" -o OPTIONS 2>/dev/null || true); case ",$options," in *,rw,*) ;; *) die "media root is not read-write";; esac
  for path in library/tv library/anime library/movies torrents/tv torrents/anime torrents/movies; do [ -d "$MEDIA_ROOT/$path" ] || die "required path missing: $path"; done
  pass "real read-write media mount and required paths are available"
}

service_id() { docker_cmd ps -aq --filter "label=com.docker.compose.project=$PROJECT_NAME" --filter "label=com.docker.compose.service=$1"; }
single_id() { local id; id=$(service_id "$1"); [ -n "$id" ] && [ "$(printf '%s\n' "$id" | awk 'NF{n++}END{print n+0}')" -eq 1 ] || return 1; printf '%s\n' "$id"; }
expected_image() { case "$1" in jellyfin) printf %s "$JELLYFIN_IMAGE";; qbittorrent) printf %s "$QBITTORRENT_IMAGE";; sonarr) printf %s "$SONARR_IMAGE";; radarr) printf %s "$RADARR_IMAGE";; prowlarr) printf %s "$PROWLARR_IMAGE";; esac; }

check_scope() {
  local service id allowed all_id image_id image_allowed=
  for service in jellyfin qbittorrent; do
    id=$(single_id "$service") || die "exactly one existing $service is required"
    [ "$(docker_cmd inspect --format '{{.Config.Image}}|{{.State.Running}}|{{.State.Health.Status}}' "$id")" = "$(expected_image "$service")|true|healthy" ] || die "$service is not locked and healthy"
  done
  allowed=$(for service in jellyfin qbittorrent sonarr radarr prowlarr; do service_id "$service"; done)
  for all_id in $(docker_cmd ps -aq); do printf '%s\n' "$allowed" | grep -Fxq "$all_id" || die "unrelated container exists"; done
  for service in jellyfin qbittorrent sonarr radarr prowlarr; do image_id=$(docker_cmd image inspect --format '{{.Id}}' "$(expected_image "$service")" 2>/dev/null || true); [ -z "$image_id" ] || image_allowed="$image_allowed$image_id\n"; done
  for all_id in $(docker_cmd images -q --no-trunc | sort -u); do printf '%b' "$image_allowed" | grep -Fxq "$all_id" || die "unrelated image exists"; done
  pass "container and image scope contains only ARR deployment services"
}

check_ports_credentials() {
  local spec service port id env_password secret_password
  for spec in 'sonarr 8989' 'radarr 7878' 'prowlarr 9696'; do set -- $spec; service=$1; port=$2
    if ss -H -lnt "sport = :$port" | grep -q .; then id=$(service_id "$service"); [ -n "$id" ] || die "TCP $port is occupied"; fi
  done
  [ -f "$ENV_FILE" ] && [ ! -L "$ENV_FILE" ] && [ "$(file_mode "$ENV_FILE")" = 600 ] || die "target .env is unsafe"
  MANAGEMENT_USERNAME=$(env_value MANAGEMENT_USERNAME); env_password=$(env_value MANAGEMENT_PASSWORD)
  [[ $MANAGEMENT_USERNAME =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "management username is invalid"
  [[ $env_password =~ ^[0-9a-f]{64}$ ]] || die "management password is invalid"
  [ -f "$RUNTIME_ROOT/secrets/management-password" ] && [ "$(file_mode "$RUNTIME_ROOT/secrets/management-password")" = 600 ] || die "password file is unsafe"
  secret_password=$(tr -d '\r\n' <"$RUNTIME_ROOT/secrets/management-password"); [ "$secret_password" = "$env_password" ] || die "password sources disagree"
  pass "ports and protected management credentials are ready"
}

validate_compose() {
  local rendered=$WORK_DIR/compose.json
  compose_cmd "$ENV_FILE" config --quiet; compose_cmd "$ENV_FILE" config --format json >"$rendered"; chmod 0600 "$rendered"
  python3 - "$rendered" "$CONFIG_ROOT" "$MEDIA_ROOT" <<'PY' || die "resolved Compose violates ARR deployment"
import json,sys
s=json.load(open(sys.argv[1]))['services']; config=sys.argv[2]; media=sys.argv[3]
for name,port in {'jellyfin':8096,'qbittorrent':8080,'sonarr':8989,'radarr':7878,'prowlarr':9696}.items():
 p=s[name].get('ports',[]); assert len(p)==1 and p[0]['host_ip']=='127.0.0.1' and int(p[0]['target'])==port and int(p[0]['published'])==port
def mounts(name): return {(m['source'],m['target'],not m.get('read_only',False)) for m in s[name].get('volumes',[])}
assert mounts('sonarr')=={(config+'/sonarr','/config',True),(media,'/data',True)}
assert mounts('radarr')=={(config+'/radarr','/config',True),(media,'/data',True)}
assert mounts('prowlarr')=={(config+'/prowlarr','/config',True)}
for name in ('sonarr','radarr','prowlarr'):
 assert not s[name].get('privileged',False) and s[name].get('network_mode')!='host' and all('docker.sock' not in str(x) for x in s[name].get('volumes',[]))
PY
  pass "resolved Compose has exact bindings and mounts"
}

check_qbittorrent() {
  local request=$WORK_DIR/qbit-request cookie=$WORK_DIR/qbit-cookie code
  python3 - "$RUNTIME_ROOT/secrets/management-password" "$request" "$MANAGEMENT_USERNAME" <<'PY'
import pathlib,sys,urllib.parse
p=pathlib.Path(sys.argv[1]).read_text().rstrip('\r\n'); pathlib.Path(sys.argv[2]).write_text(urllib.parse.urlencode({'username':sys.argv[3],'password':p}))
PY
  chmod 0600 "$request"; : >"$cookie"; chmod 0600 "$cookie"
  code=$(curl -sS -o "$WORK_DIR/qbit-login" -w '%{http_code}' -c "$cookie" -H 'Referer: http://127.0.0.1:8080' --data-binary "@$request" http://127.0.0.1:8080/api/v2/auth/login || true)
  case "$code" in 200|204) ;; *) die "qBittorrent authentication failed";; esac
  grep -Eq $'\t(SID|QBT_SID(_[0-9]+)?)\t' "$cookie" || die "qBittorrent cookie missing"
  curl -sS --fail -b "$cookie" -H 'Referer: http://127.0.0.1:8080' -o "$WORK_DIR/qbit-categories" http://127.0.0.1:8080/api/v2/torrents/categories
  curl -sS --fail -b "$cookie" -H 'Referer: http://127.0.0.1:8080' -o "$WORK_DIR/qbit-torrents" http://127.0.0.1:8080/api/v2/torrents/info
  python3 - "$WORK_DIR/qbit-categories" "$WORK_DIR/qbit-torrents" <<'PY' || die "qBittorrent is not empty and bootstrapped"
import json,sys
c=json.load(open(sys.argv[1])); e={n:f'/data/torrents/{n}' for n in ('movies','tv','anime')}
assert set(c)==set(e) and all(c[n].get('savePath')==p for n,p in e.items()) and json.load(open(sys.argv[2]))==[]
PY
  pass "qBittorrent categories and empty state are valid"
}

run_checks() {
  require_commands; runtime_identity; ensure_work; load_image_pins; validate_loopback
  check_media; check_scope; check_ports_credentials; validate_compose; check_qbittorrent
}
prepare_directories() {
  local service
  install -d -m 0755 "$CONFIG_ROOT"; install -d -m 0700 "$RUNTIME_ROOT" "$RUNTIME_ROOT/secrets" "$RUNTIME_ROOT/state"
  for service in sonarr radarr prowlarr; do [ ! -L "$CONFIG_ROOT/$service" ] || die "symlinked $service config"; install -d -o "$RUNTIME_UID" -g "$RUNTIME_GID" -m 0700 "$CONFIG_ROOT/$service"; done
  pass "protected config and secret directories are ready"
}

fingerprint() { docker_cmd inspect --format '{{.Id}}|{{.State.StartedAt}}|{{.RestartCount}}' "$1"; }
record_preserved() {
  local out=$RUNTIME_ROOT/state/arr-preserved-containers.txt jelly qbit
  jelly=$(single_id jellyfin); qbit=$(single_id qbittorrent)
  if [ -e "$out" ]; then [ -f "$out" ] && [ "$(file_mode "$out")" = 600 ] || die "preserved state unsafe"; return; fi
  { printf 'jellyfin=%s\n' "$(fingerprint "$jelly")"; printf 'qbittorrent=%s\n' "$(fingerprint "$qbit")"; } | vf_atomic_write "$out" 0600; chown root:root "$out"
}
verify_preserved() {
  local state=$RUNTIME_ROOT/state/arr-preserved-containers.txt jelly qbit
  [ -f "$state" ] && [ "$(file_mode "$state")" = 600 ] || die "preserved state missing"
  jelly=$(single_id jellyfin); qbit=$(single_id qbittorrent)
  grep -Fxq "jellyfin=$(fingerprint "$jelly")" "$state" || die "Jellyfin changed"
  grep -Fxq "qbittorrent=$(fingerprint "$qbit")" "$state" || die "qBittorrent changed"
  pass "Jellyfin and qBittorrent fingerprints are preserved"
}
snapshot_listeners() { ss -H -lntu | awk '{print $1,$5}' | sort -u; }
record_listeners() {
  local path=$RUNTIME_ROOT/state/arr-listeners-before.txt
  if [ -e "$path" ]; then [ -f "$path" ] && [ "$(file_mode "$path")" = 600 ] || die "listener baseline unsafe"; return; fi
  snapshot_listeners | vf_atomic_write "$path" 0600; chown root:root "$path"
}
verify_listeners() {
  local baseline=$RUNTIME_ROOT/state/arr-listeners-before.txt current=$WORK_DIR/current-listeners
  [ -f "$baseline" ] && [ "$(file_mode "$baseline")" = 600 ] || die "listener baseline missing"
  snapshot_listeners | awk '$0!="tcp 127.0.0.1:8989"&&$0!="tcp 127.0.0.1:7878"&&$0!="tcp 127.0.0.1:9696"' >"$current"
  cmp -s "$baseline" "$current" || die "unexpected listener change"
  pass "listener delta contains only the three loopback ports"
}
wait_services() {
  local service id health attempt
  for service in sonarr radarr prowlarr; do id=$(single_id "$service") || die "$service missing"; attempt=0
    while [ "$attempt" -lt 36 ]; do health=$(docker_cmd inspect --format '{{.State.Health.Status}}' "$id"); [ "$health" = healthy ] && break; [ "$health" != unhealthy ] || die "$service unhealthy"; attempt=$((attempt+1)); sleep 5; done
    [ "$health" = healthy ] || die "$service health timeout"
  done
}
run_api() {
  "$API_HELPER" "$1" --config-root "$CONFIG_ROOT" --secrets-root "$RUNTIME_ROOT/secrets" \
    --username "$MANAGEMENT_USERNAME" --password-file "$RUNTIME_ROOT/secrets/management-password"
}

verify_runtime() {
  local service id bindings mounts port
  for service in jellyfin qbittorrent sonarr radarr prowlarr; do id=$(single_id "$service") || die "$service missing"
    [ "$(docker_cmd inspect --format '{{.Config.Image}}|{{.State.Running}}|{{.State.Health.Status}}' "$id")" = "$(expected_image "$service")|true|healthy" ] || die "$service identity/health invalid"
  done
  [ "$(docker_cmd ps -aq | awk 'NF{n++}END{print n+0}')" -eq 5 ] || die "not exactly five containers"
  [ "$(docker_cmd images -q --no-trunc | sort -u | awk 'NF{n++}END{print n+0}')" -eq 5 ] || die "not exactly five images"
  for service in sonarr radarr prowlarr; do
    id=$(single_id "$service"); case "$service" in sonarr) port=8989;; radarr) port=7878;; prowlarr) port=9696;; esac
    bindings=$(docker_cmd inspect --format '{{range $p,$e:=.NetworkSettings.Ports}}{{range $e}}{{println $p "|" .HostIp "|" .HostPort}}{{end}}{{end}}' "$id")
    [ "$bindings" = "$port/tcp | 127.0.0.1 | $port" ] || die "$service binding unsafe"
    mounts=$(docker_cmd inspect --format '{{range .Mounts}}{{println .Source "|" .Destination "|" .RW}}{{end}}' "$id")
    printf '%s\n' "$mounts" | grep -Fxq "$CONFIG_ROOT/$service | /config | true" || die "$service config mount wrong"
    if [ "$service" = prowlarr ]; then [ "$(printf '%s\n' "$mounts" | awk 'NF{n++}END{print n+0}')" -eq 1 ] || die "Prowlarr has media access"
    else
      printf '%s\n' "$mounts" | grep -Fxq "$MEDIA_ROOT | /data | true" || die "$service /data mount wrong"
      [ "$(printf '%s\n' "$mounts" | awk 'NF{n++}END{print n+0}')" -eq 2 ] || die "$service has sliced mounts"
      docker_cmd exec "$id" sh -c 'for p in /data/library/tv /data/library/anime /data/library/movies /data/torrents/tv /data/torrents/anime /data/torrents/movies; do test -d "$p" || exit 1; done' || die "$service paths missing"
    fi
  done
  pass "five locked healthy containers have exact mounts and bindings"
}

hardlink_test() {
  local token source link a b
  token=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  TEST_TORRENT_DIR=$MEDIA_ROOT/torrents/.veinfin-hardlink-test-$token
  TEST_LIBRARY_DIR=$MEDIA_ROOT/library/.veinfin-hardlink-test-$token
  install -d -o "$RUNTIME_UID" -g "$RUNTIME_GID" -m 0700 "$TEST_TORRENT_DIR" "$TEST_LIBRARY_DIR"
  source=$TEST_TORRENT_DIR/source; link=$TEST_LIBRARY_DIR/link
  printf 'arr-hardlink-one\n' >"$source"; chown "$RUNTIME_UID:$RUNTIME_GID" "$source"; chmod 0600 "$source"; ln "$source" "$link"
  a=$(stat -c '%d:%i' "$source"); b=$(stat -c '%d:%i' "$link"); [ "$a" = "$b" ] || die "hardlink inode mismatch"
  printf 'arr-hardlink-two\n' >>"$source"; cmp -s "$source" "$link" || die "hardlink edit visibility failed"
  find "$TEST_TORRENT_DIR" -depth -delete; find "$TEST_LIBRARY_DIR" -depth -delete
  [ ! -e "$TEST_TORRENT_DIR" ] && [ ! -e "$TEST_LIBRARY_DIR" ] || die "hardlink cleanup failed"
  TEST_TORRENT_DIR=; TEST_LIBRARY_DIR=
  pass "temporary hardlink shared device/inode, reflected edits, and cleaned up"
}

verify_host() {
  local available swap_total swap_free swap_used
  if ss -H -lnt 'sport = :80 or sport = :443 or sport = :3000 or sport = :5055 or sport = :6767 or sport = :2375 or sport = :2376' | grep -q .; then die "unrelated port is listening"; fi
  [ -x /usr/local/sbin/veinfin-firewall ] && as_root /usr/local/sbin/veinfin-firewall --verify >/dev/null || die "firewall verification failed"
  available=$(awk '/MemAvailable:/{print $2*1024}' /proc/meminfo); swap_total=$(awk '/SwapTotal:/{print $2*1024}' /proc/meminfo); swap_free=$(awk '/SwapFree:/{print $2*1024}' /proc/meminfo); swap_used=$((swap_total-swap_free))
  [ "$available" -ge 536870912 ] && [ "$swap_used" -le 536870912 ] || die "severe memory pressure or heavy swap use"
  pass "firewall, Docker API closure, and memory thresholds pass"
}

write_summary() {
  {
    printf 'VeinFin local credential summary\nGenerated for local administrative use. No Visit URL contains credentials.\n\n'
    printf 'Management username: %s\n' "$MANAGEMENT_USERNAME"
    printf 'Management password: %s\n' "$(tr -d '\r\n' <"$RUNTIME_ROOT/secrets/management-password")"
    printf 'Applied use: qBittorrent, Sonarr, Radarr, and Prowlarr.\nUnique API keys: separate protected application files.\nJellyfin accounts remain separate.\n'
  } | vf_atomic_write "$RUNTIME_ROOT/secrets/credentials-summary.txt" 0600
  {
    printf '# Non-secret application bootstrap state.\nQBITTORRENT_MANAGEMENT_CREDENTIAL_STATUS=APPLIED\nSONARR_MANAGEMENT_CREDENTIAL_STATUS=APPLIED\nRADARR_MANAGEMENT_CREDENTIAL_STATUS=APPLIED\nPROWLARR_MANAGEMENT_CREDENTIAL_STATUS=APPLIED\n'
    printf 'SONARR_API_KEY=CAPTURED_UNIQUE\nRADARR_API_KEY=CAPTURED_UNIQUE\nPROWLARR_API_KEY=CAPTURED_UNIQUE\nBAZARR_API_KEY=PENDING_BOOTSTRAP\nSEERR_API_KEY=PENDING_BOOTSTRAP\n'
  } | vf_atomic_write "$RUNTIME_ROOT/state/bootstrap-status.env" 0600
  chown root:root "$RUNTIME_ROOT/secrets/credentials-summary.txt" "$RUNTIME_ROOT/state/bootstrap-status.env"
}

run_verify() {
  require_root "--verify"; require_commands; runtime_identity; ensure_work; load_image_pins; check_media; check_ports_credentials
  verify_runtime; verify_preserved; check_qbittorrent; run_api verify; hardlink_test; verify_listeners; verify_host
  pass "ARR deployment integration is valid with no torrent, movie, series, or indexer"
}
run_check() { run_checks; info "Read-only automation check passed; no persistent state changed"; }
run_apply() {
  local before after
  require_root "--apply"; run_checks; before=$({ pgrep -x rsync || true; } | awk 'END{print NR+0}')
  prepare_directories; record_preserved; record_listeners; validate_compose
  compose_cmd "$ENV_FILE" pull sonarr radarr prowlarr
  compose_cmd "$ENV_FILE" up -d --no-deps sonarr radarr prowlarr
  wait_services
  if ! run_api apply; then warn "bootstrap failed; stopping only ARR deployment services"; compose_cmd "$ENV_FILE" stop sonarr radarr prowlarr >/dev/null 2>&1 || true; return 1; fi
  write_summary
  if ! run_verify; then warn "verification failed; stopping only ARR deployment services"; compose_cmd "$ENV_FILE" stop sonarr radarr prowlarr >/dev/null 2>&1 || true; return 1; fi
  after=$({ pgrep -x rsync || true; } | awk 'END{print NR+0}'); [ "$after" -eq "$before" ] || die "external rsync process count changed"
  pass "automation deployment completed without changing existing services or the external copy"
}

if [ "${VEINFIN_ARR_LIBRARY_ONLY:-0}" = 1 ]; then return 0 2>/dev/null || exit 0; fi
[ "$#" -eq 1 ] || { usage; exit 2; }
if [ "$1" = --check ] && [ "$EUID" -ne 0 ] && [ ! -r "$ENV_FILE" ]; then
  exec sudo -n --preserve-env=SSH_CONNECTION "$0" --check
fi
case "$1" in --help) usage;; --check) run_check;; --apply) run_apply;; --verify) run_verify;; *) usage; exit 2;; esac
