#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=${VEINFIN_REPO_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd -P)}
DEPLOY_ROOT=${VEINFIN_DEPLOY_ROOT:-$REPO_ROOT}
RUNTIME_ROOT=$DEPLOY_ROOT/runtime
CONFIG_ROOT=${VEINFIN_CONFIG_ROOT:-/var/lib/veinfin}
PROJECT_NAME=${VEINFIN_PROJECT_NAME:-veinfin}
HELPER=$SCRIPT_DIR/indexers_subtitles.py
FIREWALL=${VEINFIN_FIREWALL_SCRIPT:-/usr/local/sbin/veinfin-firewall}
STATE=$RUNTIME_ROOT/state
BACKUP=$RUNTIME_ROOT/backups/indexers_subtitles-apps-before
REPORT=$STATE/indexers_subtitles-report.json
BASELINE=$STATE/indexers_subtitles-preserved-containers.txt
LISTENERS=$STATE/indexers_subtitles-listeners-before.txt
FIREWALL4=$STATE/indexers_subtitles-firewall-v4-before.rules
FIREWALL6=$STATE/indexers_subtitles-firewall-v6-before.rules
HTTPS_STATE=$STATE/indexers_subtitles-https-before.txt
MARKER=$STATE/indexers_subtitles-complete
STARTED=$STATE/indexers_subtitles-started
WORK_DIR=

# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/lib/common.sh"

info() { printf 'INFO: %s\n' "$*"; }
pass() { printf 'PASS: %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
as_root() { if [ "$EUID" -eq 0 ]; then "$@"; else sudo -n --preserve-env=SSH_CONNECTION "$@"; fi; }
docker_cmd() { as_root docker "$@"; }
file_mode() { stat -c '%a' "$1"; }
ensure_work() { if [ -z "$WORK_DIR" ]; then WORK_DIR=$(mktemp -d /tmp/veinfin-indexers_subtitles.XXXXXX); chmod 0700 "$WORK_DIR"; fi; }
cleanup() { [ -z "${WORK_DIR:-}" ] || [ ! -d "$WORK_DIR" ] || find "$WORK_DIR" -depth -delete 2>/dev/null || true; vf_cleanup; }
trap cleanup EXIT HUP INT TERM
service_id() { docker_cmd ps -aq --filter "label=com.docker.compose.project=$PROJECT_NAME" --filter "label=com.docker.compose.service=$1"; }
single_id() { local id; id=$(service_id "$1"); [ -n "$id" ] && [ "$(printf '%s\n' "$id" | awk 'NF{n++}END{print n+0}')" -eq 1 ] || return 1; printf '%s\n' "$id"; }
fingerprint() { docker_cmd inspect --format '{{.Id}}|{{.State.StartedAt}}|{{.RestartCount}}' "$1"; }
env_value() { awk -F= -v key="$1" '$1==key{n++;v=substr($0,index($0,"=")+1)}END{if(n!=1)exit 1;print v}' "$REPO_ROOT/.env"; }

usage() {
  cat <<'EOF'
VeinFin Indexer and subtitle setup public indexer and subtitle-provider foundation

Usage:
  scripts/deploy/indexers-subtitles.sh --help
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/indexers-subtitles.sh --check
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/indexers-subtitles.sh --apply
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/indexers-subtitles.sh --verify
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/indexers-subtitles.sh --rollback

Modes:
  --check     Read-only readiness check for application, media, and network state.
  --apply     Back up Prowlarr/Bazarr, test bundled public candidates, configure
              only passing indexers, synchronize Arr applications, and create
              unassigned Arabic/English Bazarr profiles without media searches.
  --verify    Verify exact API state, zero searches/downloads, and preservation.
  --rollback  Restore the protected pre-indexer/subtitle API state. Database/configuration
              backups remain available for separately reviewed disaster recovery.

Repeated --apply is verification-only after successful completion. No mode
searches, grabs, downloads, scans, imports, renames, moves, or deletes media.
EOF
}

require_root() { [ "$EUID" -eq 0 ] || die "$1 must run as root (use sudo)"; }
require_commands() {
  local command_name
  for command_name in awk cmp curl docker find ip6tables-save iptables-save mktemp openssl python3 sed ss stat; do
    command -v "$command_name" >/dev/null 2>&1 || die "required command missing: $command_name"
  done
  [ -x "$HELPER" ] && [ -x "$FIREWALL" ] || die "Indexer and subtitle setup helper or firewall verifier is unavailable"
  docker_cmd info >/dev/null || die "Docker daemon is unavailable"
}

check_containers() {
  local service id allowed= all_id
  for service in reverse-proxy jellyfin qbittorrent sonarr radarr prowlarr bazarr seerr flaresolverr; do
    id=$(single_id "$service") || die "exactly one $service container is required"
    [ "$(docker_cmd inspect --format '{{.State.Running}}|{{.State.Health.Status}}|{{.RestartCount}}' "$id")" = true\|healthy\|0 ] || die "$service is not healthy with zero restarts"
    allowed="$allowed$id\n"
  done
  [ "$(docker_cmd ps -aq | awk 'NF{n++}END{print n+0}')" -eq 9 ] || die "runtime must contain exactly nine containers"
  for all_id in $(docker_cmd ps -aq); do printf '%b' "$allowed" | grep -Fxq "$all_id" || die "unrelated container exists"; done
  pass "all nine containers are healthy with zero restarts"
}

check_security() {
  local host code
  "$FIREWALL" --check >/dev/null || die "firewall verification failed"
  ! ss -H -lnt '( sport = :80 or sport = :2375 or sport = :2376 or sport = :8191 )' | grep -q . || die "a prohibited TCP listener exists"
  ! ss -H -lnu 'sport = :443' | grep -q . || die "UDP 443 is listening"
  host=$(env_value PUBLIC_HOSTNAME) || die "public hostname is unavailable"
  code=$(curl -fsS --max-time 15 -o /dev/null -w '%{http_code}' "https://$host/health" || true)
  [ "$code" = 200 ] || die "public Jellyfin HTTPS health check failed"
  pass "firewall, listeners, HTTPS, and Docker TCP API protection remain valid"
}

api_args() {
  printf '%s\0' --username "$(env_value MANAGEMENT_USERNAME)" \
    --password-file "$RUNTIME_ROOT/secrets/management-password" \
    --sonarr-key-file "$RUNTIME_ROOT/secrets/sonarr-api-key" \
    --radarr-key-file "$RUNTIME_ROOT/secrets/radarr-api-key" \
    --prowlarr-key-file "$RUNTIME_ROOT/secrets/prowlarr-api-key" \
    --bazarr-key-file "$RUNTIME_ROOT/secrets/bazarr-api-key" \
    --report "$REPORT"
}

run_api() {
  local mode=$1 expected=${2:-} args=()
  while IFS= read -r -d '' item; do args+=("$item"); done < <(api_args)
  if [ "$mode" = check ]; then "$HELPER" check "${args[@]}" --expected-state "$expected"
  elif [ "$mode" = backup ]; then "$HELPER" backup "${args[@]}" --config-root "$CONFIG_ROOT" --backup-dir "$BACKUP"
  elif [ "$mode" = rollback ]; then "$HELPER" rollback "${args[@]}" --backup-dir "$BACKUP"
  else "$HELPER" "$mode" "${args[@]}"; fi
}

run_checks() {
  local expected=empty
  require_root "this mode"; require_commands; check_containers; check_security
  [ ! -e "$MARKER" ] || expected=configured
  [ ! -e "$STARTED" ] || die "an earlier Indexer and subtitle setup apply is unresolved; inspect the protected backup and use --rollback"
  run_api check "$expected"
  pass "Indexer and subtitle setup read-only readiness checks passed"
}

normalized_listeners() { ss -H -lntup | awk '{print $1"|"$2"|"$5}' | sort; }
normalized_firewall4() { iptables-save | sed -E '/^# (Generated|Completed)/d; s/ \[[0-9]+:[0-9]+\]$/ [0:0]/'; }
normalized_firewall6() { ip6tables-save | sed -E '/^# (Generated|Completed)/d; s/ \[[0-9]+:[0-9]+\]$/ [0:0]/'; }
https_fingerprint() {
  local host; host=$(env_value PUBLIC_HOSTNAME)
  echo | openssl s_client -connect "$host:443" -servername "$host" -verify_hostname "$host" 2>/dev/null | openssl x509 -noout -fingerprint -sha256
}

record_baseline() {
  local service id
  install -d -o root -g root -m 0700 "$STATE" "$RUNTIME_ROOT/backups"
  if [ ! -e "$BASELINE" ]; then
    { for service in reverse-proxy jellyfin qbittorrent sonarr radarr prowlarr bazarr seerr flaresolverr; do id=$(single_id "$service"); printf '%s=%s\n' "$service" "$(fingerprint "$id")"; done; } | vf_atomic_write "$BASELINE" 0600
    normalized_listeners | vf_atomic_write "$LISTENERS" 0600
    normalized_firewall4 | vf_atomic_write "$FIREWALL4" 0600
    normalized_firewall6 | vf_atomic_write "$FIREWALL6" 0600
    https_fingerprint | vf_atomic_write "$HTTPS_STATE" 0600
    chown root:root "$BASELINE" "$LISTENERS" "$FIREWALL4" "$FIREWALL6" "$HTTPS_STATE"
  fi
  pass "container, listener, firewall, and HTTPS baselines are protected"
}

verify_baseline() {
  local service id expected actual path
  ensure_work
  for path in "$BASELINE" "$LISTENERS" "$FIREWALL4" "$FIREWALL6" "$HTTPS_STATE"; do
    [ -f "$path" ] && [ ! -L "$path" ] && [ "$(file_mode "$path")" = 600 ] || die "protected Indexer and subtitle setup baseline is missing or unsafe"
  done
  for service in reverse-proxy jellyfin qbittorrent sonarr radarr prowlarr bazarr seerr flaresolverr; do
    id=$(single_id "$service"); expected=$(awk -F= -v key="$service" '$1==key{print substr($0,index($0,"=")+1)}' "$BASELINE"); actual=$(fingerprint "$id")
    [ -n "$expected" ] && [ "$actual" = "$expected" ] || die "$service identity, start time, or restart count changed"
  done
  normalized_listeners >"$WORK_DIR/listeners"; normalized_firewall4 >"$WORK_DIR/firewall4"; normalized_firewall6 >"$WORK_DIR/firewall6"; https_fingerprint >"$WORK_DIR/https"
  cmp -s "$LISTENERS" "$WORK_DIR/listeners" || die "listener set changed"
  cmp -s "$FIREWALL4" "$WORK_DIR/firewall4" && cmp -s "$FIREWALL6" "$WORK_DIR/firewall6" || die "firewall state changed"
  cmp -s "$HTTPS_STATE" "$WORK_DIR/https" || die "HTTPS certificate identity changed"
  pass "containers, listeners, firewall, and HTTPS match the Indexer and subtitle setup baseline"
}

mark_state() {
  local target=$1 value=$2 temporary
  temporary=$(mktemp "$STATE/.$(basename "$target").XXXXXX"); chmod 0600 "$temporary"; printf '%s\n' "$value" >"$temporary"; chown root:root "$temporary"; mv -f "$temporary" "$target"
}

do_apply() {
  local status
  run_checks; record_baseline; verify_baseline; run_api backup
  if [ -e "$MARKER" ]; then
    info "Indexer and subtitle setup is already complete; running verification only"
  else
    mark_state "$STARTED" started
    set +e; run_api apply; status=$?; set -e
    if [ "$status" -ne 0 ]; then
      run_api rollback || die "Indexer and subtitle setup apply failed and API rollback also failed; protected database backups are available"
      rm -f -- "$STARTED"; run_api check empty
      die "Indexer and subtitle setup apply failed and the pre-indexer/subtitle API state was restored"
    fi
    mark_state "$MARKER" completed; rm -f -- "$STARTED"
  fi
  run_api verify; verify_baseline; check_security
  pass "Indexer and subtitle setup apply completed"
}

do_verify() { run_checks; verify_baseline; run_api verify; check_security; pass "Indexer and subtitle setup verification completed"; }

do_rollback() {
  require_root "--rollback"; require_commands; [ -d "$BACKUP" ] || die "protected Indexer and subtitle setup backup is absent"
  run_api rollback; rm -f -- "$MARKER" "$STARTED" "$REPORT"; run_api check empty; check_containers; check_security
  pass "Indexer and subtitle setup API rollback completed; protected backups were preserved"
}

if [ "${VEINFIN_INDEXERS_SUBTITLES_LIBRARY_ONLY:-0}" = 1 ]; then return 0 2>/dev/null || exit 0; fi
[ "$#" -eq 1 ] || { usage >&2; exit 2; }
case "$1" in
  --help) usage ;;
  --check) run_checks ;;
  --apply) do_apply ;;
  --verify) do_verify ;;
  --rollback) do_rollback ;;
  *) usage >&2; exit 2 ;;
esac
