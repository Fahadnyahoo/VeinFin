#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=${VEINFIN_REPO_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd -P)}
ENV_FILE=${VEINFIN_ENV_FILE:-$REPO_ROOT/.env}
DEPLOY_ROOT=${VEINFIN_DEPLOY_ROOT:-$REPO_ROOT}
RUNTIME_ROOT=$DEPLOY_ROOT/runtime
CONFIG_ROOT=${VEINFIN_CONFIG_ROOT:-/var/lib/veinfin}
PROJECT_NAME=${VEINFIN_PROJECT_NAME:-veinfin}
BASE_COMPOSE=$REPO_ROOT/compose.yaml
JELLYFIN_LOOPBACK=$REPO_ROOT/compose/jellyfin-loopback.yaml
QBITTORRENT_LOOPBACK=$REPO_ROOT/compose/qbittorrent-loopback.yaml
ARR_LOOPBACK=$REPO_ROOT/compose/arr-loopback.yaml
MEDIA_SERVICES_LOOPBACK=$REPO_ROOT/compose/media-services-loopback.yaml
IMAGE_LOCK=$REPO_ROOT/config/images.lock
ENV_EXAMPLE=$REPO_ROOT/.env.example
CADDY_TEMPLATE=$REPO_ROOT/templates/caddy/Caddyfile.tmpl
FIREWALL_SCRIPT=$REPO_ROOT/scripts/host/configure-firewall.sh
INSTALLED_FIREWALL=/usr/local/sbin/veinfin-firewall
MEDIA_SERVICES_API=$REPO_ROOT/scripts/deploy/media_services_api.py
WORK_DIR=
HOSTNAME_ARG=
CADDY_WAS_PRESENT=false
APPLY_ACTIVE=false

# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/lib/common.sh"

info() { printf 'INFO: %s\n' "$*"; }
pass() { printf 'PASS: %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
as_root() { if [ "$EUID" -eq 0 ]; then "$@"; else sudo -n --preserve-env=SSH_CONNECTION "$@"; fi; }
docker_cmd() { as_root docker "$@"; }
file_mode() { stat -c '%a' "$1"; }
ensure_work() { if [ -z "$WORK_DIR" ]; then WORK_DIR=$(mktemp -d /tmp/veinfin-https.XXXXXX); chmod 0700 "$WORK_DIR"; fi; }
cleanup() {
  local status=$?
  if [ "$status" -ne 0 ] && [ "$APPLY_ACTIVE" = true ] && [ "$CADDY_WAS_PRESENT" = false ]; then
    compose_cmd stop reverse-proxy >/dev/null 2>&1 || true
  fi
  [ -z "${WORK_DIR:-}" ] || [ ! -d "$WORK_DIR" ] || find "$WORK_DIR" -depth -delete 2>/dev/null || true
  vf_cleanup
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

usage() {
  cat <<'EOF'
VeinFin HTTPS deployment public HTTPS deployment

Usage:
  scripts/deploy/https.sh --help
  scripts/deploy/https.sh --check [--hostname HOSTNAME]
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/https.sh --apply --hostname HOSTNAME
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/https.sh --verify [--hostname HOSTNAME]

Modes:
  --check   Read-only DNS, public-IP, port, container, firewall, and Compose
            readiness checks. It does not pull, start, or modify anything.
  --apply   Record the eight-container baseline, render protected Caddy state,
            pull/start only Caddy, and enable only public TCP 443 through the
            rollback-protected firewall update. It leaves rollback armed.
  --verify  From a separate SSH session, verify HTTPS/certificate/isolation,
            preserved services/listeners/rsync state, then cancel rollback.

Apply uses ACME TLS-ALPN-01 only. TCP 80, UDP 443, direct Jellyfin exposure,
management ports, DNS APIs, self-signed certificates, and other components remain
disabled. Deployment-specific hostnames stay in the target's ignored .env.
EOF
}

require_root() { [ "$EUID" -eq 0 ] || die "$1 must run as root (use sudo)"; }
compose_cmd() {
  docker_cmd compose --project-directory "$REPO_ROOT" --env-file "$ENV_FILE" \
    -f "$BASE_COMPOSE" -f "$JELLYFIN_LOOPBACK" -f "$QBITTORRENT_LOOPBACK" \
    -f "$ARR_LOOPBACK" -f "$MEDIA_SERVICES_LOOPBACK" --profile public-https "$@"
}
env_value() { as_root awk -F= -v key="$1" '$1==key{n++;v=substr($0,index($0,"=")+1)}END{if(n!=1)exit 1;print v}' "$ENV_FILE"; }
service_id() { docker_cmd ps -aq --filter "label=com.docker.compose.project=$PROJECT_NAME" --filter "label=com.docker.compose.service=$1"; }
single_id() { local id; id=$(service_id "$1"); [ -n "$id" ] && [ "$(printf '%s\n' "$id" | awk 'NF{n++}END{print n+0}')" -eq 1 ] || return 1; printf '%s\n' "$id"; }
fingerprint() { docker_cmd inspect --format '{{.Id}}|{{.State.StartedAt}}|{{.RestartCount}}' "$1"; }

valid_hostname() {
  local value=$1 label
  [ "${#value}" -le 253 ] && [[ $value == *.* ]] && [[ $value != *.invalid ]] || return 1
  [[ $value =~ ^[A-Za-z0-9.-]+$ ]] || return 1
  IFS=. read -r -a labels <<<"$value"
  for label in "${labels[@]}"; do [ -n "$label" ] && [ "${#label}" -le 63 ] && [[ $label =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1; done
}

resolve_hostname() {
  if [ -n "$HOSTNAME_ARG" ]; then PUBLIC_HOSTNAME=$HOSTNAME_ARG; else PUBLIC_HOSTNAME=$(env_value PUBLIC_HOSTNAME); fi
  PUBLIC_HOSTNAME=${PUBLIC_HOSTNAME,,}
  valid_hostname "$PUBLIC_HOSTNAME" || die "a valid non-placeholder public hostname is required"
}

require_commands() {
  local command_name
  for command_name in awk chmod chown cmp curl docker find getent grep install mktemp openssl pgrep python3 sort ss stat; do
    command -v "$command_name" >/dev/null 2>&1 || die "required command missing: $command_name"
  done
  docker_cmd compose version >/dev/null 2>&1 || die "Docker Compose plugin is unavailable"
  docker_cmd info >/dev/null 2>&1 || die "Docker daemon is unavailable"
  [ -x "$FIREWALL_SCRIPT" ] && [ -x "$MEDIA_SERVICES_API" ] || die "deployment helper is unavailable"
}

load_caddy_lock() {
  local repository tag digest platforms count
  count=$(awk -F'|' '$1=="CADDY_IMAGE_TAG"{n++}END{print n+0}' "$IMAGE_LOCK")
  [ "$count" -eq 1 ] || die "Caddy image lock is missing or duplicated"
  IFS='|' read -r repository tag digest platforms < <(awk -F'|' '$1=="CADDY_IMAGE_TAG"{print $2"|"$3"|"$4"|"$5}' "$IMAGE_LOCK")
  [ "$repository" = caddy ] && [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] && [[ ,$platforms, == *,amd64,* ]] || die "Caddy image lock is invalid"
  grep -Fxq "CADDY_IMAGE_TAG=$tag@$digest" "$ENV_EXAMPLE" || die "Caddy example and lock disagree"
  CADDY_IMAGE="$repository:$tag@$digest"
  pass "locked Linux amd64 Caddy image is exact"
}

check_dns() {
  local dns public count
  dns=$(getent ahostsv4 "$PUBLIC_HOSTNAME" | awk '{print $1}' | sort -u)
  count=$(printf '%s\n' "$dns" | awk 'NF{n++}END{print n+0}')
  [ "$count" -eq 1 ] || die "public hostname must resolve to exactly one IPv4 address"
  public=$(curl -4fsS --max-time 10 https://api.ipify.org) || die "current public IPv4 could not be determined"
  [ "$dns" = "$public" ] || die "public hostname does not resolve to the current public IPv4"
  pass "public hostname resolves to the current public IPv4"
}

check_existing() {
  local service id count allowed= all_id
  for service in jellyfin qbittorrent sonarr radarr prowlarr bazarr seerr flaresolverr; do
    id=$(single_id "$service") || die "exactly one existing $service container is required"
    [ "$(docker_cmd inspect --format '{{.State.Running}}|{{.State.Health.Status}}' "$id")" = 'true|healthy' ] || die "$service is not healthy"
    allowed="$allowed$id\n"
  done
  id=$(service_id reverse-proxy)
  if [ -n "$id" ]; then
    [ "$(printf '%s\n' "$id" | awk 'NF{n++}END{print n+0}')" -eq 1 ] || die "multiple Caddy containers exist"
    [ "$(docker_cmd inspect --format '{{.Config.Image}}|{{.State.Running}}|{{.State.Health.Status}}' "$id")" = "$CADDY_IMAGE|true|healthy" ] || die "existing Caddy container is not exact and healthy"
    CADDY_WAS_PRESENT=true; allowed="$allowed$id\n"
  fi
  count=$(docker_cmd ps -aq | awk 'NF{n++}END{print n+0}'); [ "$count" -eq 8 ] || [ "$count" -eq 9 ] || die "runtime must contain exactly eight existing services and optional Caddy"
  for all_id in $(docker_cmd ps -aq); do printf '%b' "$allowed" | grep -Fxq "$all_id" || die "unrelated container exists"; done
  docker_cmd exec "$(single_id jellyfin)" curl -fsS http://127.0.0.1:8096/health >/dev/null || die "Jellyfin internal health endpoint is unreachable"
  pass "eight existing containers and internal Jellyfin are healthy"
}

validate_caddyfile_contract() {
  grep -Fq 'auto_https disable_redirects' "$CADDY_TEMPLATE" || die "HTTP redirect listener is not disabled"
  grep -Fq 'disable_http_challenge' "$CADDY_TEMPLATE" || die "HTTP-01 is not disabled"
  grep -Fq 'protocols h1 h2' "$CADDY_TEMPLATE" || die "HTTP/3 and UDP 443 are not disabled"
  [ "$(grep -Fc 'reverse_proxy jellyfin:8096' "$CADDY_TEMPLATE")" -eq 1 ] || die "Caddy upstream must be exactly jellyfin:8096"
  ! grep -Eq 'tls internal|acme_dns|cloudflare|duckdns' "$CADDY_TEMPLATE" || die "unsafe certificate mechanism is configured"
}

validate_compose() {
  ensure_work
  local rendered=$WORK_DIR/compose.json
  PUBLIC_HOSTNAME=$PUBLIC_HOSTNAME PUBLIC_BIND_IP=0.0.0.0 HTTPS_PORT=443 compose_cmd config --quiet
  PUBLIC_HOSTNAME=$PUBLIC_HOSTNAME PUBLIC_BIND_IP=0.0.0.0 HTTPS_PORT=443 compose_cmd config --format json >"$rendered"; chmod 0600 "$rendered"
  python3 - "$rendered" "$RUNTIME_ROOT" "$CONFIG_ROOT" "$CADDY_IMAGE" <<'PY' || exit 1
import json,sys
s=json.load(open(sys.argv[1]))['services']['reverse-proxy']; runtime,config,image=sys.argv[2:]
assert s['image']==image and s.get('user')=='1000:1000'
p=s.get('ports',[]); assert len(p)==1 and p[0]['host_ip']=='0.0.0.0' and int(p[0]['published'])==443 and int(p[0]['target'])==443 and p[0]['protocol']=='tcp'
m={(x['source'],x['target'],not x.get('read_only',False)) for x in s.get('volumes',[])}
assert m=={(runtime+'/config/caddy/Caddyfile','/etc/caddy/Caddyfile',False),(config+'/caddy/data','/data',True),(config+'/caddy/config','/config',True)}
assert s.get('read_only') is True and s.get('privileged',False) is False and s.get('network_mode')!='host'
assert s.get('cap_drop')==['ALL'] and s.get('cap_add')==['NET_BIND_SERVICE']
assert set(s.get('networks',{}).keys())=={'proxy'} and all('docker.sock' not in str(x) for x in s.get('volumes',[]))
PY
  pass "resolved Compose has the exact Caddy image, binding, mounts, network, and hardening"
}

check_port_readiness() {
  local id
  if ss -H -lnt 'sport = :443' | grep -q .; then
    id=$(service_id reverse-proxy)
    [ -n "$id" ] || die "host TCP 443 is occupied by a non-Caddy listener"
    [ "$(docker_cmd inspect --format '{{(index (index .NetworkSettings.Ports "443/tcp") 0).HostIp}}:{{(index (index .NetworkSettings.Ports "443/tcp") 0).HostPort}}' "$id")" = 0.0.0.0:443 ] || die "existing Caddy binding is not exact"
  fi
  ! ss -H -lnu 'sport = :443' | grep -q . || die "UDP 443 is occupied"
  pass "TCP 443 is free or owned by exact Caddy; UDP 443 is closed"
}

run_checks() {
  require_commands; resolve_hostname; load_caddy_lock; check_dns; check_existing
  validate_caddyfile_contract; check_port_readiness
  as_root "$INSTALLED_FIREWALL" --check >/dev/null
  validate_compose
}

record_baseline() {
  local state=$RUNTIME_ROOT/state service id
  install -d -m 0700 "$state"
  if [ ! -e "$state/https-preserved-containers.txt" ]; then
    for service in jellyfin qbittorrent sonarr radarr prowlarr bazarr seerr flaresolverr; do
      id=$(single_id "$service")
      printf '%s=%s\n' "$service" "$(fingerprint "$id")"
    done | vf_atomic_write "$state/https-preserved-containers.txt" 0600
  fi
  if [ ! -e "$state/https-listeners-before.txt" ]; then
    ss -H -lnt | sort | vf_atomic_write "$state/https-listeners-before.txt" 0600
  fi
  if [ ! -e "$state/https-rsync-before.txt" ]; then
    (pgrep -x rsync 2>/dev/null || true) | sort | vf_atomic_write "$state/https-rsync-before.txt" 0600
  fi
  chown root:root "$state"/https-*.txt
  pass "container, listener, and rsync baselines are protected"
}

update_env() {
  python3 - "$ENV_FILE" "$PUBLIC_HOSTNAME" <<'PY'
import os,pathlib,secrets,sys
p=pathlib.Path(sys.argv[1]); host=sys.argv[2]
if not p.is_file() or p.is_symlink() or (p.stat().st_mode&0o777)!=0o600:
    raise SystemExit('unsafe target environment')
wanted={'PUBLIC_HOSTNAME':host,'PUBLIC_BIND_IP':'0.0.0.0','HTTPS_PORT':'443'}
lines=p.read_text().splitlines(); seen={}
for i,line in enumerate(lines):
    if '=' in line and not line.startswith('#'):
        key=line.split('=',1)[0]
        if key in wanted:
            if key in seen: raise SystemExit('duplicate target environment key')
            seen[key]=1; lines[i]=key+'='+wanted[key]
if set(seen)!=set(wanted): raise SystemExit('missing target environment key')
tmp=p.parent/('.'+p.name+'.'+secrets.token_hex(8))
fd=os.open(tmp,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
try:
    with os.fdopen(fd,'w') as f:
        f.write('\n'.join(lines)+'\n'); f.flush(); os.fsync(f.fileno())
    os.chown(tmp,0,0); os.replace(tmp,p)
finally:
    if tmp.exists(): tmp.unlink()
PY
}

prepare_caddy() {
  local rendered=$RUNTIME_ROOT/config/caddy/Caddyfile
  install -d -o 1000 -g 1000 -m 0700 "$RUNTIME_ROOT/config/caddy" "$CONFIG_ROOT/caddy/data" "$CONFIG_ROOT/caddy/config"
  [ ! -L "$rendered" ] || die "Caddyfile is a symlink"
  python3 - "$CADDY_TEMPLATE" "$rendered" <<'PY'
import os,pathlib,secrets,sys
src,p=pathlib.Path(sys.argv[1]),pathlib.Path(sys.argv[2])
tmp=p.parent/('.'+p.name+'.'+secrets.token_hex(8))
fd=os.open(tmp,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
try:
    with os.fdopen(fd,'wb') as f:
        f.write(src.read_bytes()); f.flush(); os.fsync(f.fileno())
    os.chown(tmp,1000,1000); os.replace(tmp,p)
finally:
    if tmp.exists(): tmp.unlink()
PY
  [ "$(file_mode "$rendered")" = 600 ] || die "rendered Caddyfile mode is unsafe"
  pass "persistent Caddy directories and configuration are protected"
}

prepare_firewall_update() {
  local target=$RUNTIME_ROOT/state/https-firewall.conf
  python3 - /etc/veinfin/firewall.conf "$target" <<'PY'
import os,pathlib,secrets,sys
src,p=pathlib.Path(sys.argv[1]),pathlib.Path(sys.argv[2])
lines=src.read_text().splitlines(); found=0
for i,line in enumerate(lines):
    if line.startswith('ENABLE_PUBLIC_HTTPS='):
        lines[i]='ENABLE_PUBLIC_HTTPS=true'; found+=1
if found!=1: raise SystemExit('installed firewall HTTPS flag is missing or duplicated')
tmp=p.parent/('.'+p.name+'.'+secrets.token_hex(8))
fd=os.open(tmp,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
try:
    with os.fdopen(fd,'w') as f:
        f.write('\n'.join(lines)+'\n'); f.flush(); os.fsync(f.fileno())
    os.chown(tmp,0,0); os.replace(tmp,p)
finally:
    if tmp.exists(): tmp.unlink()
PY
  "$FIREWALL_SCRIPT" --update-public-https --config "$target"
}

wait_for_https() {
  local attempt=0
  while [ "$attempt" -lt 60 ]; do
    if curl -fsS --max-time 5 --resolve "$PUBLIC_HOSTNAME:443:127.0.0.1" "https://$PUBLIC_HOSTNAME/health" >/dev/null 2>&1; then
      pass "Caddy obtained a trusted certificate and proxies Jellyfin"
      return 0
    fi
    attempt=$((attempt+1)); sleep 5
  done
  docker_cmd logs --tail 30 "$(single_id reverse-proxy)" 2>&1 | sed -E 's/(mailto:|email=)[^ ,]+/\1[redacted]/g' >&2 || true
  die "public certificate issuance or HTTPS proxy validation did not complete within five minutes"
}

verify_preserved() {
  local service id state=$RUNTIME_ROOT/state/https-preserved-containers.txt
  [ -f "$state" ] && [ "$(file_mode "$state")" = 600 ] || die "container preservation baseline is missing"
  for service in jellyfin qbittorrent sonarr radarr prowlarr bazarr seerr flaresolverr; do
    id=$(single_id "$service")
    grep -Fxq "$service=$(fingerprint "$id")" "$state" || die "$service identity/start/restart count changed"
  done
  pass "all eight existing container fingerprints are preserved"
}

verify_listeners_and_rsync() {
  ensure_work
  ss -H -lnt | awk '$4 !~ /:443$/' | sort >"$WORK_DIR/listeners"
  awk '$4 !~ /:443$/' "$RUNTIME_ROOT/state/https-listeners-before.txt" | sort >"$WORK_DIR/listeners-before"
  cmp -s "$WORK_DIR/listeners-before" "$WORK_DIR/listeners" || die "an unexpected TCP listener changed"
  (pgrep -x rsync 2>/dev/null || true) | sort >"$WORK_DIR/rsync"
  cmp -s "$RUNTIME_ROOT/state/https-rsync-before.txt" "$WORK_DIR/rsync" || die "rsync process identities changed"
  [ "$(ss -H -lnt 'sport = :443' | awk '$4 ~ /0\.0\.0\.0:443$/ {n++} END{print n+0}')" -eq 1 ] || die "public TCP 443 listener is not exact"
  ! ss -H -lnt 'sport = :80 or sport = :2375 or sport = :2376' | grep -q . || die "prohibited TCP listener exists"
  ! ss -H -lnu 'sport = :443' | grep -q . || die "UDP 443 is listening"
  pass "only public TCP 443 was added; rsync identities are preserved"
}

verify_certificate() {
  ensure_work
  local cert=$WORK_DIR/leaf.pem storage=$CONFIG_ROOT/caddy/data/caddy/certificates
  openssl s_client -connect 127.0.0.1:443 -servername "$PUBLIC_HOSTNAME" -verify_hostname "$PUBLIC_HOSTNAME" -verify_return_error </dev/null 2>"$WORK_DIR/tls-errors" | openssl x509 -out "$cert" >/dev/null 2>&1 || die "certificate chain or hostname validation failed"
  openssl x509 -in "$cert" -noout -checkhost "$PUBLIC_HOSTNAME" >/dev/null || die "certificate hostname is invalid"
  openssl x509 -in "$cert" -noout -checkend 86400 >/dev/null || die "certificate expires within 24 hours"
  openssl x509 -in "$cert" -noout -dates >"$WORK_DIR/certificate-dates"
  [ -d "$storage" ] || die "automatic-renewal certificate storage is missing"
  [ "$(find "$storage" -type f -name '*.key' | awk 'NF{n++}END{print n+0}')" -ge 1 ] || die "persisted certificate key is missing"
  ! find "$storage" -type f -name '*.key' -perm /077 | grep -q . || die "persisted certificate key permissions are unsafe"
  pass "public chain, hostname, validity, and protected renewal storage are valid"
}

verify_https_behavior() {
  ensure_work
  local headers=$WORK_DIR/headers body=$WORK_DIR/body code
  curl -fsS --max-time 15 --resolve "$PUBLIC_HOSTNAME:443:127.0.0.1" -D "$headers" -o "$body" "https://$PUBLIC_HOSTNAME/"
  grep -Eqi '^strict-transport-security:[[:space:]]*max-age=31536000' "$headers" || die "HSTS header is missing"
  grep -Eqi '^x-content-type-options:[[:space:]]*nosniff' "$headers" || die "nosniff header is missing"
  grep -Eqi '^referrer-policy:[[:space:]]*no-referrer' "$headers" || die "referrer policy header is missing"
  ! grep -Eqi '^server:' "$headers" || die "server identity header is exposed"
  : >"$WORK_DIR/wrong-host"
  code=$(curl -skS --max-time 10 --resolve invalid.example:443:127.0.0.1 -o "$WORK_DIR/wrong-host" -w '%{http_code}' https://invalid.example/ 2>/dev/null || true)
  [ "$code" != 200 ] && ! grep -Eqi 'jellyfin|emby' "$WORK_DIR/wrong-host" || die "Caddy proxies an arbitrary Host"
  pass "Jellyfin HTTPS and conservative security headers pass; arbitrary Host is rejected"
}

verify_runtime() {
  local id count mounts
  id=$(single_id reverse-proxy) || die "Caddy container is missing"
  [ "$(docker_cmd inspect --format '{{.Config.Image}}|{{.State.Running}}|{{.State.Health.Status}}|{{.HostConfig.ReadonlyRootfs}}|{{.Config.User}}' "$id")" = "$CADDY_IMAGE|true|healthy|true|1000:1000" ] || die "Caddy runtime identity or hardening is invalid"
  count=$(docker_cmd ps -aq | awk 'NF{n++}END{print n+0}'); [ "$count" -eq 9 ] || die "runtime does not contain exactly nine containers"
  count=$(docker_cmd images -q --no-trunc | sort -u | awk 'NF{n++}END{print n+0}'); [ "$count" -eq 10 ] || die "runtime does not contain exactly ten images"
  [ "$(docker_cmd inspect --format '{{json .HostConfig.CapDrop}}|{{json .HostConfig.CapAdd}}|{{json .HostConfig.PortBindings}}' "$id")" = '["ALL"]|["CAP_NET_BIND_SERVICE"]|{"443/tcp":[{"HostIp":"0.0.0.0","HostPort":"443"}]}' ] || die "Caddy capabilities or binding are not exact"
  mounts=$(docker_cmd inspect --format '{{range .Mounts}}{{println .Source "|" .Destination "|" .RW}}{{end}}' "$id")
  [ "$(printf '%s\n' "$mounts" | awk 'NF{n++}END{print n+0}')" -eq 3 ] || die "Caddy mount count is wrong"
  printf '%s\n' "$mounts" | grep -Fxq "$RUNTIME_ROOT/config/caddy/Caddyfile | /etc/caddy/Caddyfile | false" || die "Caddyfile mount is wrong"
  printf '%s\n' "$mounts" | grep -Fxq "$CONFIG_ROOT/caddy/data | /data | true" || die "Caddy data mount is wrong"
  printf '%s\n' "$mounts" | grep -Fxq "$CONFIG_ROOT/caddy/config | /config | true" || die "Caddy config mount is wrong"
  pass "Caddy runtime has exact image, mounts, capabilities, and container/image totals"
}

verify_empty_state() {
  local username
  username=$(env_value MANAGEMENT_USERNAME)
  "$MEDIA_SERVICES_API" verify --config-root "$CONFIG_ROOT" --secrets-root "$RUNTIME_ROOT/secrets" --username "$username" --password-file "$RUNTIME_ROOT/secrets/management-password" >/dev/null
  pass "Jellyfin and Media services application empty state remains valid"
}

do_verify() {
  require_root "--verify"; run_checks; verify_runtime; verify_preserved
  verify_listeners_and_rsync; verify_certificate; verify_https_behavior; verify_empty_state
  "$INSTALLED_FIREWALL" --verify >/dev/null
  pass "firewall verification passed and rollback is cancelled"
  pass "HTTPS deployment verification completed"
}

do_apply() {
  require_root "--apply"; APPLY_ACTIVE=true; run_checks
  record_baseline; update_env; prepare_caddy
  validate_compose
  compose_cmd pull reverse-proxy
  prepare_firewall_update
  compose_cmd up -d --no-deps reverse-proxy
  wait_for_https; verify_runtime; verify_preserved; verify_listeners_and_rsync
  verify_certificate; verify_https_behavior; verify_empty_state
  APPLY_ACTIVE=false
  pass "HTTPS deployment apply completed; run --verify from a separate SSH session before firewall rollback expires"
}

if [ "${VEINFIN_HTTPS_LIBRARY_ONLY:-0}" = 1 ]; then
  return 0 2>/dev/null || exit 0
fi

mode=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|--check|--apply|--verify) [ -z "$mode" ] || { usage; exit 2; }; mode=$1; shift ;;
    --hostname) [ "$#" -ge 2 ] || { usage; exit 2; }; HOSTNAME_ARG=$2; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
case "$mode" in
  --help) [ -z "$HOSTNAME_ARG" ] || { usage; exit 2; }; usage ;;
  --check) run_checks; info "Read-only HTTPS deployment readiness check complete" ;;
  --apply) [ -n "$HOSTNAME_ARG" ] || die "--apply requires --hostname HOSTNAME"; do_apply ;;
  --verify) do_verify ;;
  *) usage; exit 2 ;;
esac
