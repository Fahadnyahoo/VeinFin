#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=${VEINFIN_REPO_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd -P)}
BASE_COMPOSE=$REPO_ROOT/compose.yaml
JELLYFIN_LOOPBACK=$REPO_ROOT/compose/jellyfin-loopback.yaml
QBITTORRENT_LOOPBACK=$REPO_ROOT/compose/qbittorrent-loopback.yaml
ARR_LOOPBACK=$REPO_ROOT/compose/arr-loopback.yaml
MEDIA_SERVICES_LOOPBACK=$REPO_ROOT/compose/media-services-loopback.yaml
IMAGE_LOCK=$REPO_ROOT/config/images.lock
ENV_EXAMPLE=$REPO_ROOT/.env.example
ENV_FILE=${VEINFIN_ENV_FILE:-$REPO_ROOT/.env}
API_HELPER=$REPO_ROOT/scripts/deploy/media_services_api.py
DEPLOY_ROOT=${VEINFIN_DEPLOY_ROOT:-$REPO_ROOT}
CONFIG_ROOT=${VEINFIN_CONFIG_ROOT:-/var/lib/veinfin}
MEDIA_ROOT=${VEINFIN_MEDIA_ROOT:-/srv/media}
RUNTIME_ROOT=$DEPLOY_ROOT/runtime
PROJECT_NAME=${VEINFIN_PROJECT_NAME:-veinfin}
WORK_DIR=

# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/lib/common.sh"

info() { printf 'INFO: %s\n' "$*"; }
pass() { printf 'PASS: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
cleanup() { [ -z "${WORK_DIR:-}" ] || [ ! -d "$WORK_DIR" ] || find "$WORK_DIR" -depth -delete 2>/dev/null || true; vf_cleanup; }
trap cleanup EXIT HUP INT TERM

usage() {
  cat <<'EOF'
VeinFin Media services services deployment

Usage:
  scripts/deploy/media-services.sh --help
  scripts/deploy/media-services.sh --check
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/media-services.sh --apply
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/media-services.sh --verify

Modes:
  --check   Read-only readiness validation. Accepts either the preserved ARR deployment
            baseline or an already-applied Media services runtime.
  --apply   Complete Jellyfin setup, pull only four locked images, start only
            Bazarr/Seerr/FlareSolverr, configure exact private integrations,
            and validate Recyclarr with its official preview mode.
  --verify  Read-only proof of eight healthy long-running containers, nine
            locked images, preserved ARR deployment identities, isolation, empty
            application state, firewall health, and resource safety.

Private operator access:
  ssh -N -L 6767:127.0.0.1:6767 -L 5055:127.0.0.1:5055 user@host

Recyclarr remains an on-demand job. This script never performs a real sync,
adds media/requests/indexers/providers/downloads, or starts services outside this deployment.
EOF
}

require_root() { [ "$EUID" -eq 0 ] || die "$1 must run as root (use sudo)"; }
as_root() { if [ "$EUID" -eq 0 ]; then "$@"; else sudo -n --preserve-env=SSH_CONNECTION "$@"; fi; }
docker_cmd() { as_root docker "$@"; }
compose_cmd() {
  local env_file=$1; shift
  docker_cmd compose --project-directory "$REPO_ROOT" --env-file "$env_file" \
    -f "$BASE_COMPOSE" -f "$JELLYFIN_LOOPBACK" -f "$QBITTORRENT_LOOPBACK" \
    -f "$ARR_LOOPBACK" -f "$MEDIA_SERVICES_LOOPBACK" "$@"
}
file_mode() { if stat -c '%a' "$1" >/dev/null 2>&1; then stat -c '%a' "$1"; else stat -f '%Lp' "$1"; fi; }
valid_path() { [ -n "$1" ] && [[ $1 == /* ]] && [ "$1" != / ] && [[ $1 =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ /$1/ != */../* ]] && [[ /$1/ != */./* ]]; }
env_value() { as_root awk -F= -v key="$1" '$1==key{n++;v=substr($0,index($0,"=")+1)}END{if(n!=1)exit 1;print v}' "${2:-$ENV_FILE}"; }
ensure_work() { if [ -z "$WORK_DIR" ]; then WORK_DIR=$(mktemp -d /tmp/veinfin-media_services.XXXXXX); chmod 0700 "$WORK_DIR"; fi; }
service_id() { docker_cmd ps -aq --filter "label=com.docker.compose.project=$PROJECT_NAME" --filter "label=com.docker.compose.service=$1"; }
single_id() { local id; id=$(service_id "$1"); [ -n "$id" ] && [ "$(printf '%s\n' "$id" | awk 'NF{n++}END{print n+0}')" -eq 1 ] || return 1; printf '%s\n' "$id"; }

runtime_identity() {
  local user_name
  if [ -n "${VEINFIN_RUNTIME_USER:-}" ]; then user_name=$VEINFIN_RUNTIME_USER
  elif [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then user_name=$SUDO_USER
  elif [ "$EUID" -ne 0 ]; then user_name=$(id -un)
  else die "cannot determine non-root runtime user"; fi
  RUNTIME_UID=$(id -u "$user_name"); RUNTIME_GID=$(id -g "$user_name")
  [ "$RUNTIME_UID" -gt 0 ] && [ "$RUNTIME_GID" -gt 0 ] || die "services must not run as root"
}

require_commands() {
  local cmd
  for cmd in awk chmod chown cmp curl docker find findmnt grep id install mktemp pgrep ps python3 sleep sort ss stat tr; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command missing: $cmd"
  done
  [ -x "$API_HELPER" ] || die "Media services API helper is unavailable"
  docker_cmd compose version >/dev/null 2>&1 || die "Docker Compose plugin is unavailable"
  docker_cmd info >/dev/null 2>&1 || die "Docker daemon is unavailable"
  pass "Docker Engine and Compose are available"
}

lock_line() { awk -F'|' -v key="$1" '$1==key{print $2"|"$3"|"$4"|"$5}' "$IMAGE_LOCK"; }
load_image_pins() {
  local spec key expected repository tag digest platforms count
  for spec in \
    'JELLYFIN_IMAGE_TAG|jellyfin/jellyfin' 'QBITTORRENT_IMAGE_TAG|lscr.io/linuxserver/qbittorrent' \
    'SONARR_IMAGE_TAG|lscr.io/linuxserver/sonarr' 'RADARR_IMAGE_TAG|lscr.io/linuxserver/radarr' \
    'PROWLARR_IMAGE_TAG|lscr.io/linuxserver/prowlarr' 'BAZARR_IMAGE_TAG|lscr.io/linuxserver/bazarr' \
    'SEERR_IMAGE_TAG|ghcr.io/seerr-team/seerr' 'RECYCLARR_IMAGE_TAG|ghcr.io/recyclarr/recyclarr' \
    'FLARESOLVERR_IMAGE_TAG|ghcr.io/flaresolverr/flaresolverr'; do
    key=${spec%%|*}; expected=${spec#*|}; count=$(awk -F'|' -v key="$key" '$1==key{n++}END{print n+0}' "$IMAGE_LOCK")
    [ "$count" -eq 1 ] || die "$key lock is missing or duplicated"
    IFS='|' read -r repository tag digest platforms <<<"$(lock_line "$key")"
    [ "$repository" = "$expected" ] || die "$key repository is unreviewed"
    [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || die "$key digest is invalid"
    case ",$platforms," in *,amd64,*) ;; *) die "$key lacks Linux amd64";; esac
    grep -Fxq "$key=$tag@$digest" "$ENV_EXAMPLE" || die "$key example and lock disagree"
    eval "${key%_IMAGE_TAG}_IMAGE=\$repository:\$tag@\$digest"
  done
  pass "all nine service images match reviewed Linux amd64 locks"
}

expected_image() {
  case "$1" in
    jellyfin) printf %s "$JELLYFIN_IMAGE";; qbittorrent) printf %s "$QBITTORRENT_IMAGE";;
    sonarr) printf %s "$SONARR_IMAGE";; radarr) printf %s "$RADARR_IMAGE";; prowlarr) printf %s "$PROWLARR_IMAGE";;
    bazarr) printf %s "$BAZARR_IMAGE";; seerr) printf %s "$SEERR_IMAGE";; recyclarr) printf %s "$RECYCLARR_IMAGE";;
    flaresolverr) printf %s "$FLARESOLVERR_IMAGE";; *) return 1;;
  esac
}

validate_loopback() {
  local service port
  for service in bazarr seerr; do
    [ "$service" = bazarr ] && port=6767 || port=5055
    [ "$(grep -Ec "^[[:space:]]+-[[:space:]]+name:[[:space:]]+$service-bootstrap$" "$MEDIA_SERVICES_LOOPBACK")" -eq 1 ] || die "$service loopback entry missing"
    [ "$(grep -Ec "^[[:space:]]+target:[[:space:]]+$port$" "$MEDIA_SERVICES_LOOPBACK")" -eq 1 ] || die "$service target is unsafe"
    [ "$(grep -Ec "^[[:space:]]+published:[[:space:]]+\"?$port\"?$" "$MEDIA_SERVICES_LOOPBACK")" -eq 1 ] || die "$service publication is unsafe"
  done
  [ "$(grep -Ec '^[[:space:]]+host_ip:[[:space:]]+127\.0\.0\.1$' "$MEDIA_SERVICES_LOOPBACK")" -eq 2 ] || die "Media services UIs must bind IPv4 loopback"
  if grep -Eq 'host_ip:[[:space:]]*(0\.0\.0\.0|::|\[::\]|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)|network_mode:[[:space:]]*host' "$MEDIA_SERVICES_LOOPBACK"; then die "unsafe Media services binding"; fi
  pass "Media services override is exactly IPv4-loopback-only"
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
  pass "media mount and exact required directories are ready"
}

check_credentials() {
  local env_password secret_password secret
  as_root test -f "$ENV_FILE" && as_root test ! -L "$ENV_FILE" && [ "$(as_root stat -c '%a' "$ENV_FILE")" = 600 ] || die "target .env is unsafe"
  MANAGEMENT_USERNAME=$(env_value MANAGEMENT_USERNAME); env_password=$(env_value MANAGEMENT_PASSWORD)
  [[ $MANAGEMENT_USERNAME =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "management username is invalid"
  [[ $env_password =~ ^[0-9a-f]{64}$ ]] || die "management password is invalid"
  secret=$RUNTIME_ROOT/secrets/management-password
  as_root test -f "$secret" && as_root test ! -L "$secret" && [ "$(as_root stat -c '%a' "$secret")" = 600 ] || die "management password file is unsafe"
  secret_password=$(as_root sh -c 'tr -d "\r\n" < "$1"' sh "$secret")
  [ "$secret_password" = "$env_password" ] || die "password sources disagree"
  for secret in sonarr-api-key radarr-api-key prowlarr-api-key; do
    as_root test -f "$RUNTIME_ROOT/secrets/$secret" && [ "$(as_root stat -c '%a' "$RUNTIME_ROOT/secrets/$secret")" = 600 ] || die "$secret is unsafe"
  done
  pass "existing management and application credentials are protected"
}

check_existing() {
  local service id allowed= all_id count expected
  for service in jellyfin qbittorrent sonarr radarr prowlarr; do
    id=$(single_id "$service") || die "exactly one existing $service is required"
    expected=$(expected_image "$service")
    [ "$(docker_cmd inspect --format '{{.Config.Image}}|{{.State.Running}}|{{.State.Health.Status}}' "$id")" = "$expected|true|healthy" ] || die "$service is not locked and healthy"
  done
  count=$(docker_cmd ps -aq | awk 'NF{n++}END{print n+0}')
  [ "$count" -eq 5 ] || [ "$count" -eq 8 ] || die "runtime contains neither the five-service baseline nor Media services"
  for service in jellyfin qbittorrent sonarr radarr prowlarr bazarr seerr flaresolverr; do allowed="$allowed$(service_id "$service")\n"; done
  for all_id in $(docker_cmd ps -aq); do printf '%b' "$allowed" | grep -Fxq "$all_id" || die "unrelated container exists"; done
  pass "existing five services are locked and healthy; runtime scope is clean"
}

validate_compose() {
  local rendered=$WORK_DIR/compose.json
  compose_cmd "$ENV_FILE" --profile automation config --quiet
  compose_cmd "$ENV_FILE" --profile automation config --format json >"$rendered"; chmod 0600 "$rendered"
  python3 - "$rendered" "$CONFIG_ROOT" "$MEDIA_ROOT" "$RUNTIME_ROOT" <<'PY' || exit 1
import json,sys
s=json.load(open(sys.argv[1]))['services']; config,media,runtime=sys.argv[2:]
for name,port in {'bazarr':6767,'seerr':5055}.items():
 p=s[name].get('ports',[]); assert len(p)==1 and p[0]['host_ip']=='127.0.0.1' and int(p[0]['target'])==port and int(p[0]['published'])==port
def mounts(name): return {(m['source'],m['target'],not m.get('read_only',False)) for m in s[name].get('volumes',[])}
assert mounts('bazarr')=={(config+'/bazarr','/config',True),(media+'/library/movies','/data/library/movies',True),(media+'/library/tv','/data/library/tv',True),(media+'/library/anime','/data/library/anime',True)}
assert mounts('seerr')=={(config+'/seerr','/app/config',True)}
assert mounts('flaresolverr')==set() and not s['flaresolverr'].get('ports')
assert mounts('recyclarr')=={(runtime+'/config/recyclarr','/config',True),(config+'/recyclarr','/data',True)}
assert s['recyclarr'].get('profiles')==['automation'] and s['recyclarr'].get('restart')=='no' and not s['recyclarr'].get('ports')
assert s['recyclarr'].get('command')==['sync','--preview']
for name in ('bazarr','seerr','recyclarr','flaresolverr'):
 assert not s[name].get('privileged',False) and s[name].get('network_mode')!='host' and all('docker.sock' not in str(x) for x in s[name].get('volumes',[]))
PY
  pass "resolved Compose has exact Media services mounts, bindings, and isolation"
}

run_checks() {
  require_commands; runtime_identity; ensure_work; load_image_pins; validate_loopback
  check_media; check_existing; check_credentials; validate_compose
}

fingerprint() { docker_cmd inspect --format '{{.Id}}|{{.State.StartedAt}}|{{.RestartCount}}' "$1"; }
record_preserved() {
  local out=$RUNTIME_ROOT/state/media_services-preserved-containers.txt service id
  if [ -e "$out" ]; then [ -f "$out" ] && [ "$(file_mode "$out")" = 600 ] || die "preservation state unsafe"; return; fi
  for service in jellyfin qbittorrent sonarr radarr prowlarr; do id=$(single_id "$service"); printf '%s=%s\n' "$service" "$(fingerprint "$id")"; done | vf_atomic_write "$out" 0600
  chown root:root "$out"
}
verify_preserved() {
  local state=$RUNTIME_ROOT/state/media_services-preserved-containers.txt service id
  [ -f "$state" ] && [ "$(file_mode "$state")" = 600 ] || die "preservation state missing"
  for service in jellyfin qbittorrent sonarr radarr prowlarr; do id=$(single_id "$service"); grep -Fxq "$service=$(fingerprint "$id")" "$state" || die "$service identity/start/restarts changed"; done
  pass "all five pre-existing container fingerprints are preserved"
}
snapshot_listeners() { ss -H -lntu | awk '{print $1,$5}' | sort -u; }
record_baselines() {
  local listeners=$RUNTIME_ROOT/state/media_services-listeners-before.txt rsync=$RUNTIME_ROOT/state/media_services-rsync-before.txt
  if [ ! -e "$listeners" ]; then snapshot_listeners | vf_atomic_write "$listeners" 0600; chown root:root "$listeners"; fi
  if [ ! -e "$rsync" ]; then { ps -C rsync -o pid=,lstart=,comm= || true; } | sed 's/^[[:space:]]*//' | vf_atomic_write "$rsync" 0600; chown root:root "$rsync"; fi
}
verify_baselines() {
  local baseline=$RUNTIME_ROOT/state/media_services-listeners-before.txt current=$WORK_DIR/listeners rsync=$WORK_DIR/rsync
  snapshot_listeners | awk '$0!="tcp 127.0.0.1:6767"&&$0!="tcp 127.0.0.1:5055"' >"$current"
  cmp -s "$baseline" "$current" || die "unexpected host listener change"
  { ps -C rsync -o pid=,lstart=,comm= || true; } | sed 's/^[[:space:]]*//' >"$rsync"
  cmp -s "$RUNTIME_ROOT/state/media_services-rsync-before.txt" "$rsync" || die "external rsync process identity changed"
  pass "listener delta is exact and active rsync identities are untouched"
}

prepare_directories() {
  local service
  install -d -m 0755 "$CONFIG_ROOT"
  install -d -m 0700 "$RUNTIME_ROOT" "$RUNTIME_ROOT/secrets" "$RUNTIME_ROOT/state" "$RUNTIME_ROOT/config" "$RUNTIME_ROOT/config/recyclarr"
  for service in bazarr seerr recyclarr; do [ ! -L "$CONFIG_ROOT/$service" ] || die "symlinked $service config"; install -d -o "$RUNTIME_UID" -g "$RUNTIME_GID" -m 0700 "$CONFIG_ROOT/$service"; done
  chown "$RUNTIME_UID:$RUNTIME_GID" "$RUNTIME_ROOT/config/recyclarr"
  pass "protected Media services config, state, and secret directories are ready"
}

run_api() { "$API_HELPER" "$1" --config-root "$CONFIG_ROOT" --secrets-root "$RUNTIME_ROOT/secrets" --username "$MANAGEMENT_USERNAME" --password-file "$RUNTIME_ROOT/secrets/management-password"; }

wait_services() {
  local service id health= attempt
  for service in bazarr seerr flaresolverr; do
    id=$(single_id "$service") || die "$service missing"; attempt=0
    while [ "$attempt" -lt 48 ]; do
      health=$(docker_cmd inspect --format '{{.State.Health.Status}}' "$id")
      [ "$health" = healthy ] && break
      [ "$health" != unhealthy ] || die "$service became unhealthy"
      attempt=$((attempt+1)); sleep 5
    done
    [ "$health" = healthy ] || die "$service health timeout"
  done
}

write_recyclarr_config() {
  local target=$RUNTIME_ROOT/config/recyclarr/recyclarr.yml
  python3 - "$RUNTIME_ROOT/secrets/sonarr-api-key" "$RUNTIME_ROOT/secrets/radarr-api-key" "$target" "$RUNTIME_UID" "$RUNTIME_GID" <<'PY'
import os,pathlib,secrets,sys
s,r,target,uid,gid=sys.argv[1:]
def read(p):
 q=pathlib.Path(p)
 if not q.is_file() or q.is_symlink() or (q.stat().st_mode & 0o777)!=0o600: raise SystemExit('unsafe API key file')
 return q.read_text().strip()
text=("sonarr:\n  veinfin:\n    base_url: http://sonarr:8989\n    api_key: "+read(s)+"\n"
      "radarr:\n  veinfin:\n    base_url: http://radarr:7878\n    api_key: "+read(r)+"\n")
p=pathlib.Path(target); tmp=p.parent/("."+p.name+"."+secrets.token_hex(8))
fd=os.open(tmp,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
try:
 with os.fdopen(fd,'w') as f: f.write(text); f.flush(); os.fsync(f.fileno())
 os.chown(tmp,int(uid),int(gid)); os.replace(tmp,p)
finally:
 if tmp.exists(): tmp.unlink()
PY
  [ "$(file_mode "$target")" = 600 ] || die "Recyclarr configuration permissions are unsafe"
  pass "protected Recyclarr configuration is generated atomically"
}

validate_recyclarr() {
  local output=$WORK_DIR/recyclarr-preview.log
  compose_cmd "$ENV_FILE" --profile automation run --rm --no-deps recyclarr sync --preview >"$output" 2>&1 || die "Recyclarr official preview validation failed"
  if grep -Eqi 'api[_ -]?key.*[0-9a-f]{16}|password.*[0-9a-f]{16}' "$output"; then die "Recyclarr preview exposed a secret"; fi
  printf 'validated-not-applied\n' | vf_atomic_write "$RUNTIME_ROOT/state/recyclarr-status" 0600; chown root:root "$RUNTIME_ROOT/state/recyclarr-status"
  pass "Recyclarr configuration passed official preview; no real sync ran"
}

write_credential_status() {
  {
    printf 'VeinFin local credential summary\n'
    printf 'Generated for local administrative use. No Visit URL contains credentials.\n\n'
    printf 'Management username: %s\n' "$MANAGEMENT_USERNAME"
    printf 'Management password: %s\n' "$(tr -d '\r\n' <"$RUNTIME_ROOT/secrets/management-password")"
    printf 'Applied use: qBittorrent, Sonarr, Radarr, Prowlarr, Jellyfin, Bazarr, and Seerr.\n'
    printf 'Application API keys: five unique protected files are present.\n'
    printf 'No credentials are embedded in Visit URLs.\n'
  } | vf_atomic_write "$RUNTIME_ROOT/secrets/credentials-summary.txt" 0600
  chown root:root "$RUNTIME_ROOT/secrets/credentials-summary.txt"
}

resource_sample() {
  awk '/^MemAvailable:/{a=$2}/^SwapTotal:/{t=$2}/^SwapFree:/{f=$2}END{print a, t-f}' /proc/meminfo
}
resource_guard() {
  local a1 s1 a2 s2
  read -r a1 s1 <<<"$(resource_sample)"; sleep 10; read -r a2 s2 <<<"$(resource_sample)"
  if [ "$a1" -lt 524288 ] || [ "$a2" -lt 524288 ] || [ $((s2-s1)) -gt 262144 ]; then
    compose_cmd "$ENV_FILE" stop bazarr seerr flaresolverr >/dev/null
    die "critical memory/swap pressure detected; only new Media services services were stopped"
  fi
  pass "available memory and swap-pressure guard passed"
}

verify_runtime() {
  local service id expected count bindings mounts
  for service in jellyfin qbittorrent sonarr radarr prowlarr bazarr seerr flaresolverr; do
    id=$(single_id "$service") || die "$service missing"; expected=$(expected_image "$service")
    [ "$(docker_cmd inspect --format '{{.Config.Image}}|{{.State.Running}}|{{.State.Health.Status}}' "$id")" = "$expected|true|healthy" ] || die "$service image/health invalid"
  done
  count=$(docker_cmd ps -aq | awk 'NF{n++}END{print n+0}'); [ "$count" -eq 8 ] || die "not exactly eight containers"
  count=$(docker_cmd images -q --no-trunc | sort -u | awk 'NF{n++}END{print n+0}'); [ "$count" -eq 9 ] || die "not exactly nine images"
  for service in bazarr seerr; do
    id=$(single_id "$service"); [ "$service" = bazarr ] && expected=6767 || expected=5055
    bindings=$(docker_cmd inspect --format '{{range $p,$e:=.NetworkSettings.Ports}}{{range $e}}{{println $p "|" .HostIp "|" .HostPort}}{{end}}{{end}}' "$id")
    [ "$bindings" = "$expected/tcp | 127.0.0.1 | $expected" ] || die "$service binding unsafe"
  done
  id=$(single_id flaresolverr); [ -z "$(docker_cmd inspect --format '{{range $p,$e:=.NetworkSettings.Ports}}{{range $e}}{{println .HostIp .HostPort}}{{end}}{{end}}' "$id")" ] || die "FlareSolverr is host-published"
  mounts=$(docker_cmd inspect --format '{{range .Mounts}}{{println .Source "|" .Destination "|" .RW}}{{end}}' "$(single_id bazarr)")
  [ "$(printf '%s\n' "$mounts" | awk 'NF{n++}END{print n+0}')" -eq 4 ] || die "Bazarr mount count wrong"
  for expected in "$CONFIG_ROOT/bazarr | /config | true" "$MEDIA_ROOT/library/movies | /data/library/movies | true" "$MEDIA_ROOT/library/tv | /data/library/tv | true" "$MEDIA_ROOT/library/anime | /data/library/anime | true"; do printf '%s\n' "$mounts" | grep -Fxq "$expected" || die "Bazarr mount missing"; done
  mounts=$(docker_cmd inspect --format '{{range .Mounts}}{{println .Source "|" .Destination "|" .RW}}{{end}}' "$(single_id seerr)")
  [ "$mounts" = "$CONFIG_ROOT/seerr | /app/config | true" ] || die "Seerr mount contract wrong"
  docker_cmd inspect "$(single_id flaresolverr)" >"$WORK_DIR/flaresolverr-inspect.json"
  python3 - "$WORK_DIR/flaresolverr-inspect.json" <<'PY' || die "FlareSolverr has an unexpected mount"
import json,sys
c=json.load(open(sys.argv[1]))[0]
assert c['HostConfig'].get('Binds') in (None, [])
assert set((c['Config'].get('Volumes') or {}).keys()) == {'/config'}
m=c.get('Mounts', [])
assert len(m) == 1 and m[0].get('Type') == 'volume' and m[0].get('Destination') == '/config'
assert m[0].get('Source', '').startswith('/var/lib/docker/volumes/')
PY
  [ "$(file_mode "$RUNTIME_ROOT/config/recyclarr/recyclarr.yml")" = 600 ] || die "Recyclarr config mode wrong"
  [ "$(tr -d '\r\n' <"$RUNTIME_ROOT/state/recyclarr-status")" = validated-not-applied ] || die "Recyclarr no-sync proof missing"
  pass "eight healthy containers, nine images, and exact mounts/bindings verified"
}

verify_host() {
  if ss -H -lnt 'sport = :80 or sport = :443 or sport = :3000 or sport = :8191 or sport = :2375 or sport = :2376' | grep -q .; then die "prohibited listener exists"; fi
  [ -x /usr/local/sbin/veinfin-firewall ] || die "firewall verifier unavailable"
  as_root /usr/local/sbin/veinfin-firewall --verify >/dev/null || die "firewall verification failed"
  pass "firewall passes and Docker TCP/FlareSolverr/public other service ports are closed"
}

report_resources() {
  local available swap_total swap_free
  available=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
  swap_total=$(awk '/^SwapTotal:/{print int($2/1024)}' /proc/meminfo); swap_free=$(awk '/^SwapFree:/{print int($2/1024)}' /proc/meminfo)
  info "Host memory after stabilization: available=${available}MiB swap_used=$((swap_total-swap_free))MiB"
  docker_cmd stats --no-stream --format 'INFO: Container memory: {{.Name}}={{.MemUsage}}'
}

do_apply() {
  require_root "--apply"; run_checks; prepare_directories; record_preserved; record_baselines
  run_api jellyfin
  compose_cmd "$ENV_FILE" pull bazarr seerr recyclarr flaresolverr
  compose_cmd "$ENV_FILE" up -d --no-deps bazarr seerr flaresolverr
  wait_services; resource_guard
  run_api apply
  write_recyclarr_config; validate_recyclarr; write_credential_status
  do_verify
  pass "Media services apply completed"
}

do_verify() {
  require_root "--verify"; run_checks; verify_runtime; verify_preserved; ensure_work
  run_api verify; verify_baselines; verify_host; report_resources
  pass "Media services verification completed"
}

if [ "${VEINFIN_MEDIA_SERVICES_LIBRARY_ONLY:-0}" = 1 ]; then
  return 0 2>/dev/null || exit 0
fi

[ "$#" -eq 1 ] || { usage >&2; exit 2; }
case "$1" in
  --help) usage;;
  --check) run_checks; info "Read-only Media services readiness check complete";;
  --apply) do_apply;;
  --verify) do_verify;;
  *) usage >&2; exit 2;;
esac
