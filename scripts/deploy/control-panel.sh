#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=${VEINFIN_REPO_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd -P)}
DEPLOY_ROOT=${VEINFIN_DEPLOY_ROOT:-$REPO_ROOT}
RUNTIME_ROOT=$DEPLOY_ROOT/runtime
STATE=$RUNTIME_ROOT/state
SECRETS=$RUNTIME_ROOT/secrets
GENERATED=$RUNTIME_ROOT/generated
BACKUP=$RUNTIME_ROOT/backups/control_panel-before
MARKER=$STATE/control_panel-complete
STARTED=$STATE/control_panel-started
PENDING=$STATE/control_panel-firewall-pending
CONTROL_PANEL_ENV=$GENERATED/control_panel.env
CONTROL_PANEL_COMPOSE=$REPO_ROOT/compose/control-panel.yml
FIREWALL_SOURCE=$REPO_ROOT/scripts/host/configure-firewall.sh
FIREWALL_INSTALLED=/usr/local/sbin/veinfin-firewall
WORK_DIR=
SUDO_BIN=${VEINFIN_SUDO_BIN:-sudo}
VALIDATED_SSH_CONNECTION=

# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/lib/common.sh"

info(){ printf 'INFO: %s\n' "$*"; }
pass(){ printf 'PASS: %s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
effective_uid(){ id -u; }
file_mode(){ stat -c '%a' "$1"; }
ensure_work(){ if [ -z "$WORK_DIR" ]; then WORK_DIR=$(mktemp -d /tmp/veinfin-control_panel.XXXXXX); chmod 0700 "$WORK_DIR"; fi; }
cleanup(){ [ -z "${WORK_DIR:-}" ] || [ ! -d "$WORK_DIR" ] || find "$WORK_DIR" -depth -delete 2>/dev/null || true; vf_cleanup; }
trap cleanup EXIT HUP INT TERM

usage(){ cat <<'EOF'
VeinFin Control panel setup private control panel

Usage:
  scripts/deploy/control-panel.sh --help
  scripts/deploy/control-panel.sh --check
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/control-panel.sh --apply
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/control-panel.sh --verify

Modes:
  --check   Read-only readiness, resource, security, and preservation checks.
  --apply   Back up affected configuration, build reproducibly, deploy the panel
            and restricted agent, publish allowlisted management ports, and arm
            firewall rollback. Existing application state is preserved.
  --verify  Verify firewall policy from the approved SSH session, authenticate
            the panel, exercise one controlled FlareSolverr restart, and finish.

Repeated apply is verification-only after completion. The panel never mounts the
Docker socket; only the allowlisted, unexposed agent receives it. No mode touches
media, creates downloads, enables experimental plugins, or starts future work.
EOF
}

validate_ssh_context(){
  [ -n "${SSH_CONNECTION:-}" ] || die "SSH_CONNECTION is required"
  ss -H -tn state established | "$SCRIPT_DIR/download_lifecycle.py" validate-ssh >/dev/null || die "SSH connection context is invalid"
  VALIDATED_SSH_CONNECTION=$SSH_CONNECTION; export SSH_CONNECTION
}
enter_privileged(){ validate_ssh_context; if [ "$(effective_uid)" -ne 0 ]; then exec "$SUDO_BIN" --preserve-env=SSH_CONNECTION "$SCRIPT_DIR/control-panel.sh" "$@"; fi; }
docker_cmd(){ docker "$@"; }
env_value(){ awk -F= -v key="$1" '$1==key{n++;v=substr($0,index($0,"=")+1)}END{if(n!=1)exit 1;print v}' "$REPO_ROOT/.env"; }
service_id(){ docker_cmd ps -aq --filter "label=com.docker.compose.project=$(env_value COMPOSE_PROJECT_NAME)" --filter "label=com.docker.compose.service=$1"; }
fingerprint(){ docker_cmd inspect --format '{{.Id}}|{{.State.StartedAt}}|{{.RestartCount}}' "$1"; }

require_commands(){ local command; for command in awk cmp curl docker find findmnt id install mktemp openssl python3 sed sha256sum ss stat; do command -v "$command" >/dev/null || die "required command missing: $command"; done; docker info >/dev/null || die "Docker is unavailable"; }

check_preflight(){
  require_commands
  [ -f "$REPO_ROOT/.env" ] && [ "$(file_mode "$REPO_ROOT/.env")" = 600 ] || die ".env is missing or unsafe"
  "$SCRIPT_DIR/download-lifecycle.sh" --verify >/dev/null || die "Download lifecycle setup verification failed"
  local service id
  for service in reverse-proxy jellyfin qbittorrent sonarr radarr prowlarr bazarr seerr flaresolverr; do
    id=$(service_id "$service"); [ -n "$id" ] || die "$service is absent"
    [ "$(docker inspect --format '{{.State.Running}}|{{.State.Health.Status}}|{{.RestartCount}}' "$id")" = true\|healthy\|0 ] || die "$service is not healthy with zero restarts"
  done
  [ "$(docker ps -q | awk 'NF{n++}END{print n+0}')" -eq 9 ] || [ -f "$MARKER" ] || die "expected nine pre-panel long-running containers"
  findmnt -T "$(env_value MEDIA_ROOT)" >/dev/null || die "media root is not mounted"
  [ -w "$(env_value MEDIA_ROOT)" ] || die "media root is not writable"
  [ ! -e "$(env_value MEDIA_ROOT)/torrents/.veinfin-control_panel-validation" ] || die "unexpected validation artifact exists"
  pass "zero-torrent Download lifecycle setup state, containers, media, firewall, and HTTPS are ready"
}

record_backup(){
  install -d -o root -g root -m 0700 "$BACKUP" "$STATE" "$SECRETS" "$GENERATED"
  if [ ! -e "$BACKUP/manifest" ]; then
    install -o root -g root -m 0600 "$REPO_ROOT/.env" "$BACKUP/repository.env"
    install -o root -g root -m 0600 /etc/veinfin/firewall.conf "$BACKUP/firewall.conf"
    install -o root -g root -m 0755 "$FIREWALL_INSTALLED" "$BACKUP/veinfin-firewall"
    { for service in reverse-proxy jellyfin qbittorrent sonarr radarr prowlarr bazarr seerr flaresolverr; do printf '%s=%s\n' "$service" "$(fingerprint "$(service_id "$service")")"; done; } | vf_atomic_write "$BACKUP/container-fingerprints" 0600
    printf 'schema=1\nmedia_included=false\n' | vf_atomic_write "$BACKUP/manifest" 0600
    chown root:root "$BACKUP"/*
  fi
  pass "Control panel setup affected configuration backup is protected"
}

generate_secrets(){
  local password hash_file=$SECRETS/control_panel-password-hash agent_file=$SECRETS/control_panel-agent-secret session_file=$SECRETS/control_panel-session-secret cert=$SECRETS/control_panel-panel.crt key=$SECRETS/control_panel-panel.key host extension temp
  umask 077
  if [ ! -e "$agent_file" ]; then vf_random_hex 32 | vf_atomic_write "$agent_file" 0600; fi
  if [ ! -e "$session_file" ]; then vf_random_hex 32 | vf_atomic_write "$session_file" 0600; fi
  if [ ! -e "$hash_file" ]; then
    password=$SECRETS/management-password
    python3 - "$password" <<'PY' | vf_atomic_write "$hash_file" 0600
import base64,hashlib,os,sys
password=open(sys.argv[1],encoding='utf-8').read().strip().encode(); salt=os.urandom(16); iterations=600000
value=hashlib.pbkdf2_hmac('sha256',password,salt,iterations,dklen=32)
enc=lambda x:base64.urlsafe_b64encode(x).decode()
print(f"pbkdf2-sha256${iterations}${enc(salt)}${enc(value)}")
PY
  fi
  if [ ! -e "$cert" ] || [ ! -e "$key" ]; then
    host=$(management_address)
    case "$host" in *:*) extension="subjectAltName=IP:$host" ;; *[!0-9.]* ) extension="subjectAltName=DNS:$host" ;; *) extension="subjectAltName=IP:$host" ;; esac
    ensure_work; temp=$WORK_DIR/tls; mkdir -m 0700 "$temp"
    openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 825 -subj /CN=VeinFin -addext "$extension" -keyout "$temp/panel.key" -out "$temp/panel.crt" >/dev/null 2>&1
    install -o root -g root -m 0600 "$temp/panel.key" "$key"
    install -o root -g root -m 0600 "$temp/panel.crt" "$cert"
  fi
  chown 65532:65532 "$agent_file" "$session_file" "$hash_file" "$cert" "$key"; chmod 0600 "$agent_file" "$session_file" "$hash_file" "$cert" "$key"
  pass "panel password hash, session channel secret, and private TLS material are protected"
}

management_address(){
  ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}'
}

build_images(){
  local base first second source_hash
  base='python:3.13.17-alpine3.24@sha256:fa0bb0d0cd7c7d6cef30a69094d32ac2b71c7304c87c6107fec100e1ee4eda02'
  docker pull "$base" >/dev/null
  source_hash=$(sha256sum "$REPO_ROOT/panel/Dockerfile" "$REPO_ROOT/panel/app.py" | sha256sum | awk '{print $1}')
  first=$(docker buildx build --network=none --no-cache --provenance=false --sbom=false --build-arg SOURCE_DATE_EPOCH=0 --output type=docker,rewrite-timestamp=true -q -t "veinfin/panel:$source_hash-a" "$REPO_ROOT/panel")
  second=$(docker buildx build --network=none --no-cache --provenance=false --sbom=false --build-arg SOURCE_DATE_EPOCH=0 --output type=docker,rewrite-timestamp=true -q -t "veinfin/panel:$source_hash-b" "$REPO_ROOT/panel")
  [ "$first" = "$second" ] || die "independent panel builds are not byte-identical"
  docker tag "$first" "veinfin/panel:$source_hash"
  docker image rm "veinfin/panel:$source_hash-a" "veinfin/panel:$source_hash-b" >/dev/null 2>&1 || true
  PANEL_IMAGE=$first
  pass "two independent panel builds produced one identical immutable image"
}

update_env_and_render(){
  local address project socket_gid origin visits tmp
  address=$(management_address); [ -n "$address" ] || die "management address is unavailable"
  project=$(env_value COMPOSE_PROJECT_NAME); socket_gid=$(stat -c '%g' /var/run/docker.sock)
  origin="https://$address:$(env_value CONTROL_PANEL_MANAGEMENT_PORT)"
  visits=$(python3 - "$REPO_ROOT/.env" "$address" <<'PY'
import json,sys
values={}
for line in open(sys.argv[1],encoding='utf-8'):
 if '=' in line and not line.startswith('#'):
  k,v=line.rstrip('\n').split('=',1); values[k]=v
host=sys.argv[2]; scheme=values.get('MANAGEMENT_URL_SCHEME','http')
result={'jellyfin':'https://'+values['PUBLIC_HOSTNAME']}
for key,name in [('QBITTORRENT','qbittorrent'),('SONARR','sonarr'),('RADARR','radarr'),('PROWLARR','prowlarr'),('BAZARR','bazarr'),('SEERR','seerr')]:
 result[name]=f"{scheme}://{host}:{values[key+'_MANAGEMENT_PORT']}"
print(json.dumps(result,separators=(',',':')))
PY
)
  ensure_work; tmp=$WORK_DIR/repository.env
  awk -F= -v ip="$address" '
    $1=="MANAGEMENT_BIND_IP" {$0="MANAGEMENT_BIND_IP=" ip; bind++}
    $1=="MANAGEMENT_URL_HOST" {$0="MANAGEMENT_URL_HOST=" ip; host++}
    {print}
    END{if(bind!=1||host!=1)exit 1}' "$REPO_ROOT/.env" >"$tmp"
  chmod 0600 "$tmp"; chown root:root "$tmp"; mv -f "$tmp" "$REPO_ROOT/.env"
  {
    printf 'VEINFIN_PANEL_IMAGE=%s\n' "$PANEL_IMAGE"
    printf 'DOCKER_SOCKET_GID=%s\n' "$socket_gid"
    printf 'PANEL_ORIGIN=%s\n' "$origin"
    printf 'VISIT_URLS_JSON=%s\n' "$visits"
  } | vf_atomic_write "$CONTROL_PANEL_ENV" 0600
  chown root:root "$CONTROL_PANEL_ENV"
}

compose_cmd(){ docker compose --env-file "$REPO_ROOT/.env" --env-file "$CONTROL_PANEL_ENV" -f "$REPO_ROOT/compose.yaml" -f "$CONTROL_PANEL_COMPOSE" "$@"; }

update_panel_image_reference(){
  local image=${PANEL_IMAGE:-} temp
  [[ "$image" =~ ^sha256:[0-9a-f]{64}$ ]] || die "panel image must be an immutable local image ID"
  [ -f "$CONTROL_PANEL_ENV" ] || die "Control panel setup generated environment is absent"
  ensure_work; temp=$WORK_DIR/control_panel.env
  awk -F= -v image="$image" '
    $1=="VEINFIN_PANEL_IMAGE" {$0="VEINFIN_PANEL_IMAGE=" image; found++}
    {print}
    END{if(found!=1)exit 1}' "$CONTROL_PANEL_ENV" >"$temp" || die "cannot update panel image reference"
  install -o root -g root -m 0600 "$temp" "$CONTROL_PANEL_ENV"
}

verify_applications(){
  local media_path attempt
  media_path=$(awk -F= '$1=="HOST_SERIES_PATH"{print substr($0,index($0,"=")+1)}' "$STATE/sonarr_adoption-series.conf")
  attempt=0
  while [ "$attempt" -lt 30 ]; do
    if "$SCRIPT_DIR/download_lifecycle.py" verify \
      --policy "$REPO_ROOT/config/download-lifecycle-policy.json" \
      --username "$(env_value MANAGEMENT_USERNAME)" \
      --password-file "$SECRETS/management-password" \
      --sonarr-key-file "$SECRETS/sonarr-api-key" \
      --radarr-key-file "$SECRETS/radarr-api-key" \
      --prowlarr-key-file "$SECRETS/prowlarr-api-key" \
      --bazarr-key-file "$SECRETS/bazarr-api-key" \
      --media-root "$(env_value MEDIA_ROOT)" \
      --before "$STATE/download_lifecycle-retry1b-api-before.json" \
      --validation-root "$(env_value MEDIA_ROOT)/torrents/.veinfin-download_lifecycle-validation" >/dev/null 2>&1; then
      "$SCRIPT_DIR/quality_profiles.py" media-verify --snapshot "$STATE/sonarr_adoption-media-snapshot.json" --media-path "$media_path" >/dev/null || return 1
      return 0
    fi
    sleep 2; attempt=$((attempt + 1))
  done
  return 1
}

render_firewall_candidate(){
  ensure_work
  sed 's/^ENABLE_MANAGEMENT_PORTS=.*/ENABLE_MANAGEMENT_PORTS=true/' /etc/veinfin/firewall.conf >"$WORK_DIR/firewall.conf"
  [ "$(grep -c '^ENABLE_MANAGEMENT_PORTS=true$' "$WORK_DIR/firewall.conf")" -eq 1 ] || die "cannot render management firewall transition"
  chmod 0600 "$WORK_DIR/firewall.conf"
}

verify_runtime(){
  local service id count attempt status
  for service in reverse-proxy jellyfin qbittorrent sonarr radarr prowlarr bazarr seerr flaresolverr veinfin-panel veinfin-agent; do
    id=$(service_id "$service"); [ -n "$id" ] || die "$service is absent"
    attempt=0; status=
    while [ "$attempt" -lt 60 ]; do
      status=$(docker inspect --format '{{.State.Running}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id")
      [ "$status" = true\|healthy ] && break
      sleep 2; attempt=$((attempt + 1))
    done
    [ "$status" = true\|healthy ] || die "$service is not healthy"
  done
  count=$(docker ps -q | awk 'NF{n++}END{print n+0}'); [ "$count" -eq 11 ] || die "exactly eleven long-running containers are required"
  [ -z "$(docker inspect --format '{{range .Mounts}}{{println .Source .Destination}}{{end}}' "$(service_id veinfin-panel)" | grep docker.sock || true)" ] || die "panel has Docker socket access"
  docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/run/docker.sock"}}{{.Destination}}{{end}}{{end}}' "$(service_id veinfin-agent)" | grep -qx /var/run/docker.sock || die "agent socket mount is absent"
  ! ss -H -lnt 'sport = :9000' | grep -q . || die "agent port is host-published"
  ! ss -H -lnt 'sport = :2375 or sport = :2376' | grep -q . || die "Docker TCP API is exposed"
  verify_applications || die "application/media preservation failed"
  pass "eleven containers, restricted socket ownership, zero torrents, media, and public exposure are valid"
}

do_check(){ enter_privileged --check; check_preflight; [ ! -e "$STARTED" ] || die "an interrupted Control panel setup apply requires review"; pass "Control panel setup readiness check completed without changes"; }

do_apply(){
  enter_privileged --apply
  if [ -f "$MARKER" ]; then info "Control panel setup is already complete; running verification only"; do_verify_internal; return; fi
  check_preflight; record_backup; generate_secrets; build_images; update_env_and_render
  compose_cmd config --quiet
  printf 'started\n' | vf_atomic_write "$STARTED" 0600; chown root:root "$STARTED"
  compose_cmd up -d --no-deps qbittorrent sonarr radarr prowlarr bazarr seerr veinfin-panel veinfin-agent
  verify_runtime
  install -o root -g root -m 0755 "$FIREWALL_SOURCE" "$FIREWALL_INSTALLED"
  render_firewall_candidate
  SSH_CONNECTION=$VALIDATED_SSH_CONNECTION "$FIREWALL_INSTALLED" --update-management --config "$WORK_DIR/firewall.conf"
  printf 'pending\n' | vf_atomic_write "$PENDING" 0600; chown root:root "$PENDING"
  pass "Control panel setup apply completed; run --verify from a separate approved SSH session"
}

run_panel_smoke(){
  local action=${1:-false} address origin username action_args=()
  address=$(management_address); origin="https://$address:$(env_value CONTROL_PANEL_MANAGEMENT_PORT)"; username=$(env_value MANAGEMENT_USERNAME)
  [ "$action" = true ] && action_args=(--action-service flaresolverr)
  "$SCRIPT_DIR/control_panel_smoke.py" --connect-url "https://127.0.0.1:$(env_value CONTROL_PANEL_MANAGEMENT_PORT)" --origin "$origin" --username "$username" --password-file "$SECRETS/management-password" "${action_args[@]}"
}

do_verify_internal(){
  local action=${1:-false}
  [ -f "$CONTROL_PANEL_ENV" ] || die "Control panel setup generated environment is absent"
  compose_cmd config --quiet
  verify_runtime
  SSH_CONNECTION=$VALIDATED_SSH_CONNECTION "$FIREWALL_INSTALLED" --verify >/dev/null
  run_panel_smoke "$action"
  verify_runtime
  pass "Control panel setup panel, agent, firewall, authentication, and preservation verification passed"
}

do_verify(){
  enter_privileged --verify
  [ -f "$PENDING" ] || [ -f "$MARKER" ] || die "Control panel setup apply has not completed"
  if [ -f "$MARKER" ]; then do_verify_internal false; else do_verify_internal true; fi
  if [ ! -e "$MARKER" ]; then printf 'completed\n' | vf_atomic_write "$MARKER" 0600; chown root:root "$MARKER"; fi
  rm -f -- "$STARTED" "$PENDING"
  pass "Control panel setup verification completed"
}

if [ "${VEINFIN_CONTROL_PANEL_LIBRARY_ONLY:-0}" = 1 ]; then return 0 2>/dev/null || exit 0; fi
[ "$#" -eq 1 ] || { usage >&2; exit 2; }
case "$1" in --help) usage;; --check) do_check;; --apply) do_apply;; --verify) do_verify;; *) usage >&2; exit 2;; esac
