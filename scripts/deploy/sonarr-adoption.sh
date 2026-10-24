#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=${VEINFIN_REPO_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd -P)}
DEPLOY_ROOT=${VEINFIN_DEPLOY_ROOT:-$REPO_ROOT}
RUNTIME_ROOT=$DEPLOY_ROOT/runtime
CONFIG_ROOT=${VEINFIN_CONFIG_ROOT:-/var/lib/veinfin}
PROJECT_NAME=${VEINFIN_PROJECT_NAME:-veinfin}
MANIFEST=${VEINFIN_SONARR_ADOPTION_MANIFEST:-$RUNTIME_ROOT/state/sonarr_adoption-series.conf}
LIBRARIES_MANIFEST=${VEINFIN_LIBRARIES_MANIFEST:-$RUNTIME_ROOT/state/libraries-media.conf}
LIBRARIES_REPORT=$RUNTIME_ROOT/state/libraries-media-report.json
HELPER=$SCRIPT_DIR/sonarr_adoption.py
LIBRARIES_HELPER=$SCRIPT_DIR/libraries_api.py
FIREWALL=${VEINFIN_FIREWALL_SCRIPT:-/usr/local/sbin/veinfin-firewall}
STATE=$RUNTIME_ROOT/state
BASELINE=$STATE/sonarr_adoption-preserved-containers.txt
LISTENERS=$STATE/sonarr_adoption-listeners-before.txt
FIREWALL4=$STATE/sonarr_adoption-firewall-v4-before.rules
FIREWALL6=$STATE/sonarr_adoption-firewall-v6-before.rules
HTTPS_STATE=$STATE/sonarr_adoption-https-before.txt
SNAPSHOT=$STATE/sonarr_adoption-media-snapshot.json
REPORT=$STATE/sonarr_adoption-adoption-report.json
BACKUP=$RUNTIME_ROOT/backups/sonarr_adoption-sonarr-retry-before
MARKER=$STATE/sonarr_adoption-adoption-complete
STARTED=$STATE/sonarr_adoption-adoption-started
WORK_DIR=

# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/lib/common.sh"

info() { printf 'INFO: %s\n' "$*"; }
pass() { printf 'PASS: %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
as_root() { if [ "$EUID" -eq 0 ]; then "$@"; else sudo -n --preserve-env=SSH_CONNECTION "$@"; fi; }
docker_cmd() { as_root docker "$@"; }
file_mode() { stat -c '%a' "$1"; }
ensure_work() { if [ -z "$WORK_DIR" ]; then WORK_DIR=$(mktemp -d /tmp/veinfin-sonarr_adoption.XXXXXX); chmod 0700 "$WORK_DIR"; fi; }
cleanup() { [ -z "${WORK_DIR:-}" ] || [ ! -d "$WORK_DIR" ] || find "$WORK_DIR" -depth -delete 2>/dev/null || true; vf_cleanup; }
trap cleanup EXIT HUP INT TERM
service_id() { docker_cmd ps -aq --filter "label=com.docker.compose.project=$PROJECT_NAME" --filter "label=com.docker.compose.service=$1"; }
single_id() { local id; id=$(service_id "$1"); [ -n "$id" ] && [ "$(printf '%s\n' "$id" | awk 'NF{n++}END{print n+0}')" -eq 1 ] || return 1; printf '%s\n' "$id"; }
fingerprint() { docker_cmd inspect --format '{{.Id}}|{{.State.StartedAt}}|{{.RestartCount}}' "$1"; }

usage() {
  cat <<'EOF'
VeinFin Sonarr adoption existing-series Sonarr adoption

Usage:
  scripts/deploy/sonarr-adoption.sh --help
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/sonarr-adoption.sh --check
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/sonarr-adoption.sh --apply
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/sonarr-adoption.sh --verify

Modes:
  --check   Read-only validation of the protected manifest, empty/adopted app
            state, media, integrations, containers, HTTPS, and firewall.
  --apply   Back up Sonarr, snapshot the media tree, add one lookup-verified
            existing series with monitoring/search disabled, run only a local
            Sonarr disk rescan, and roll back the database entry on mismatch.
  --verify  Verify exact Sonarr recognition, unchanged media size/timestamps,
            zero torrents/searches, Jellyfin state, and infrastructure state.

Repeated apply is verification-only after the protected completion marker.
No mode renames, moves, copies, hardlinks, deletes, or rewrites media.
EOF
}

require_root() { [ "$EUID" -eq 0 ] || die "$1 must run as root (use sudo)"; }
manifest_value() { awk -F= -v key="$1" '$1==key{n++;v=substr($0,index($0,"=")+1)}END{if(n!=1||v=="")exit 1;print v}' "$MANIFEST"; }
libraries_value() { awk -F= -v key="$1" '$1==key{n++;v=substr($0,index($0,"=")+1)}END{if(n!=1||v=="")exit 1;print v}' "$LIBRARIES_MANIFEST"; }
env_value() { awk -F= -v key="$1" '$1==key{n++;v=substr($0,index($0,"=")+1)}END{if(n!=1)exit 1;print v}' "$REPO_ROOT/.env"; }

load_manifest() {
  [ -f "$MANIFEST" ] && [ ! -L "$MANIFEST" ] && [ "$(file_mode "$MANIFEST")" = 600 ] && [ "$(stat -c '%u:%g' "$MANIFEST")" = 0:0 ] || die "Sonarr adoption manifest must be root-owned mode 0600"
  LOOKUP_TERM=$(manifest_value LOOKUP_TERM) || die "manifest lookup term is missing"
  EXPECTED_TVDB_ID=$(manifest_value EXPECTED_TVDB_ID) || die "manifest TVDB identity is missing"
  QUALITY_PROFILE=$(manifest_value QUALITY_PROFILE) || die "manifest quality profile is missing"
  SERIES_PATH=$(manifest_value SERIES_PATH) || die "manifest Sonarr series path is missing"
  HOST_SERIES_PATH=$(manifest_value HOST_SERIES_PATH) || die "manifest host series path is missing"
  EXPECTED_FILES=$(manifest_value EXPECTED_FILES) || die "manifest expected file count is missing"
  [[ $EXPECTED_TVDB_ID =~ ^[1-9][0-9]*$ ]] && [[ $EXPECTED_FILES =~ ^[1-9][0-9]*$ ]] || die "manifest numeric value is invalid"
  [[ $SERIES_PATH == /data/library/anime/* ]] && [[ $HOST_SERIES_PATH == /srv/media/library/anime/* ]] || die "series path is outside the Anime root"
  [ -d "$HOST_SERIES_PATH" ] && [ ! -L "$HOST_SERIES_PATH" ] || die "host series directory is unavailable"
}

require_commands() {
  local command_name
  for command_name in awk cmp cp curl docker find grep ip6tables-save iptables-save mktemp openssl pgrep python3 sed sha256sum ss stat; do
    command -v "$command_name" >/dev/null || die "required command missing: $command_name"
  done
  [ -x "$HELPER" ] && [ -x "$LIBRARIES_HELPER" ] && [ -x "$FIREWALL" ] || die "required deployment helper is unavailable"
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
  pass "firewall, listeners, and public HTTPS remain valid"
}

jellyfin_verify() {
  local username expected_name expected_count language country report_copy
  [ -f "$LIBRARIES_MANIFEST" ] && [ "$(file_mode "$LIBRARIES_MANIFEST")" = 600 ] || die "protected Library setup manifest is unavailable"
  ensure_work; report_copy=$WORK_DIR/libraries-media-report.json; cp "$LIBRARIES_REPORT" "$report_copy"; chmod 0600 "$report_copy"
  username=$(env_value MANAGEMENT_USERNAME); expected_name=$(libraries_value EXPECTED_SERIES_NAME); expected_count=$(libraries_value EXPECTED_EPISODES)
  language=$(libraries_value EXPECTED_LANGUAGE); country=$(libraries_value EXPECTED_COUNTRY)
  "$LIBRARIES_HELPER" verify --username "$username" --password-file "$RUNTIME_ROOT/secrets/management-password" \
    --expected-series-name "$expected_name" --expected-count "$expected_count" --language "$language" --country "$country" --report "$report_copy" >/dev/null
  pass "Jellyfin still has the exact three-library, one-series, 170-episode state"
}

api_args() {
  printf '%s\0' --username "$(env_value MANAGEMENT_USERNAME)" \
    --password-file "$RUNTIME_ROOT/secrets/management-password" \
    --sonarr-key-file "$RUNTIME_ROOT/secrets/sonarr-api-key" \
    --radarr-key-file "$RUNTIME_ROOT/secrets/radarr-api-key" \
    --prowlarr-key-file "$RUNTIME_ROOT/secrets/prowlarr-api-key" \
    --lookup-term "$LOOKUP_TERM" --expected-tvdb-id "$EXPECTED_TVDB_ID" \
    --quality-profile "$QUALITY_PROFILE" --series-path "$SERIES_PATH" \
    --host-series-path "$HOST_SERIES_PATH" --expected-files "$EXPECTED_FILES" \
    --snapshot "$SNAPSHOT" --report "$REPORT"
}

run_api() {
  local mode=$1 state=${2:-} args=()
  while IFS= read -r -d '' item; do args+=("$item"); done < <(api_args)
  if [ "$mode" = check ]; then "$HELPER" check "${args[@]}" --expected-state "$state"; else "$HELPER" "$mode" "${args[@]}"; fi
}

run_checks() {
  local expected=empty
  require_root "this mode"; require_commands; load_manifest; check_containers; check_security; jellyfin_verify
  [ ! -e "$MARKER" ] || expected=adopted
  run_api check "$expected"
  pass "Sonarr adoption readiness checks passed"
}

normalized_listeners() { ss -H -lntup | awk '{print $1"|"$2"|"$5}' | sort; }
normalized_firewall4() { iptables-save | sed -E '/^# (Generated|Completed)/d; s/ \[[0-9]+:[0-9]+\]$/ [0:0]/'; }
normalized_firewall6() { ip6tables-save | sed -E '/^# (Generated|Completed)/d; s/ \[[0-9]+:[0-9]+\]$/ [0:0]/'; }
https_fingerprint() {
  local host
  host=$(env_value PUBLIC_HOSTNAME)
  echo | openssl s_client -connect "$host:443" -servername "$host" -verify_hostname "$host" 2>/dev/null |
    openssl x509 -noout -fingerprint -sha256
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
  for id in "$BASELINE" "$LISTENERS" "$FIREWALL4" "$FIREWALL6" "$HTTPS_STATE"; do [ -f "$id" ] && [ ! -L "$id" ] && [ "$(file_mode "$id")" = 600 ] || die "protected baseline is missing or unsafe"; done
  pass "container, listener, firewall, and HTTPS baselines are protected"
}

verify_baseline() {
  local service id expected actual
  ensure_work
  for service in reverse-proxy jellyfin qbittorrent sonarr radarr prowlarr bazarr seerr flaresolverr; do
    id=$(single_id "$service"); expected=$(awk -F= -v key="$service" '$1==key{print substr($0,index($0,"=")+1)}' "$BASELINE"); actual=$(fingerprint "$id")
    [ -n "$expected" ] && [ "$actual" = "$expected" ] || die "$service identity, start time, or restart count changed"
  done
  normalized_listeners >"$WORK_DIR/listeners"; normalized_firewall4 >"$WORK_DIR/firewall4"; normalized_firewall6 >"$WORK_DIR/firewall6"; https_fingerprint >"$WORK_DIR/https"
  cmp -s "$LISTENERS" "$WORK_DIR/listeners" || die "listener set changed"
  cmp -s "$FIREWALL4" "$WORK_DIR/firewall4" && cmp -s "$FIREWALL6" "$WORK_DIR/firewall6" || die "firewall state changed"
  cmp -s "$HTTPS_STATE" "$WORK_DIR/https" || die "HTTPS certificate identity changed"
  pass "containers, listeners, firewall, and HTTPS match the pre-adoption baseline"
}

mark_state() {
  local target=$1 value=$2 temporary
  temporary=$(mktemp "$STATE/.$(basename "$target").XXXXXX"); chmod 0600 "$temporary"; printf '%s\n' "$value" >"$temporary"; mv -f "$temporary" "$target"
}

prepare_recovery() {
  [ -e "$SNAPSHOT" ] || "$HELPER" snapshot --host-series-path "$HOST_SERIES_PATH" --snapshot "$SNAPSHOT"
  "$HELPER" backup --config-root "$CONFIG_ROOT" --backup-dir "$BACKUP"
  pass "Sonarr database/configuration backup and media snapshot are protected"
}

do_apply() {
  local status
  run_checks; record_baseline; verify_baseline; prepare_recovery
  if [ -e "$MARKER" ]; then
    [ -f "$MARKER" ] && [ "$(file_mode "$MARKER")" = 600 ] || die "completion marker is unsafe"
    info "Sonarr adoption already completed; verifying without mutation or rescan"
    run_api verify
  else
    [ ! -e "$STARTED" ] || die "an earlier adoption start is unresolved; inspect Sonarr and the protected backup before recovery"
    mark_state "$STARTED" started
    set +e; run_api apply; status=$?; set -e
    if [ "$status" -ne 0 ]; then
      if run_api check empty >/dev/null 2>&1; then rm -f -- "$STARTED"; fi
      return "$status"
    fi
    mark_state "$MARKER" completed
    rm -f -- "$STARTED"
  fi
  run_api verify; jellyfin_verify; verify_baseline; check_security
  pass "Sonarr adoption apply completed"
}

do_verify() { run_checks; verify_baseline; run_api verify; jellyfin_verify; check_security; pass "Sonarr adoption verification completed"; }

if [ "${VEINFIN_SONARR_ADOPTION_LIBRARY_ONLY:-0}" = 1 ]; then return 0 2>/dev/null || exit 0; fi
[ "$#" -eq 1 ] || { usage; exit 2; }
case "$1" in
  --help) usage ;;
  --check) run_checks ;;
  --apply) do_apply ;;
  --verify) do_verify ;;
  *) usage; exit 2 ;;
esac
