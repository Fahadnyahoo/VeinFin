#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=${VEINFIN_REPO_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd -P)}
DEPLOY_ROOT=${VEINFIN_DEPLOY_ROOT:-$REPO_ROOT}
RUNTIME_ROOT=$DEPLOY_ROOT/runtime
CONFIG_ROOT=${VEINFIN_CONFIG_ROOT:-/var/lib/veinfin}
PROJECT_NAME=${VEINFIN_PROJECT_NAME:-veinfin}
STATE=$RUNTIME_ROOT/state
BACKUP=$RUNTIME_ROOT/backups/quality_profiles-apps-before
POLICY=$REPO_ROOT/config/quality-policy.json
HELPER=$SCRIPT_DIR/quality_profiles.py
GENERATED=$RUNTIME_ROOT/config/recyclarr/quality_profiles.yml
BEFORE=$STATE/quality_profiles-api-before.json
PREVIEW_SUMMARY=$STATE/quality_profiles-preview.json
MARKER=$STATE/quality_profiles-complete
STARTED=$STATE/quality_profiles-started
BASELINE=$STATE/quality_profiles-preserved-containers.txt
LISTENERS=$STATE/quality_profiles-listeners-before.txt
FIREWALL4=$STATE/quality_profiles-firewall-v4-before.rules
FIREWALL6=$STATE/quality_profiles-firewall-v6-before.rules
HTTPS_STATE=$STATE/quality_profiles-https-before.txt
WORK_DIR=

# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/lib/common.sh"

info() { printf 'INFO: %s\n' "$*"; }
pass() { printf 'PASS: %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
as_root() { if [ "$EUID" -eq 0 ]; then "$@"; else sudo -n --preserve-env=SSH_CONNECTION "$@"; fi; }
docker_cmd() { as_root docker "$@"; }
file_mode() { stat -c '%a' "$1"; }
ensure_work() { if [ -z "$WORK_DIR" ]; then WORK_DIR=$(mktemp -d /tmp/veinfin-quality_profiles.XXXXXX); chmod 0700 "$WORK_DIR"; fi; }
cleanup() { [ -z "${WORK_DIR:-}" ] || [ ! -d "$WORK_DIR" ] || find "$WORK_DIR" -depth -delete 2>/dev/null || true; vf_cleanup; }
trap cleanup EXIT HUP INT TERM
service_id() { docker_cmd ps -aq --filter "label=com.docker.compose.project=$PROJECT_NAME" --filter "label=com.docker.compose.service=$1"; }
single_id() { local id; id=$(service_id "$1"); [ -n "$id" ] && [ "$(printf '%s\n' "$id" | awk 'NF{n++}END{print n+0}')" -eq 1 ] || return 1; printf '%s\n' "$id"; }
fingerprint() { docker_cmd inspect --format '{{.Id}}|{{.State.StartedAt}}|{{.RestartCount}}' "$1"; }
env_value() { awk -F= -v key="$1" '$1==key{n++;v=substr($0,index($0,"=")+1)}END{if(n!=1)exit 1;print v}' "$REPO_ROOT/.env"; }

usage() {
  cat <<'EOF'
VeinFin Quality profile setup quality-profile and Recyclarr synchronization

Usage:
  scripts/deploy/quality-profiles.sh --help
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/quality-profiles.sh --check
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/quality-profiles.sh --preview
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/quality-profiles.sh --apply
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/quality-profiles.sh --verify
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/quality-profiles.sh --rollback

Modes:
  --check     Read-only preflight and protected-state validation.
  --preview   Back up application state, generate protected configuration, run
              only the official Recyclarr preview, and write a sanitized gate.
  --apply     Require a matching successful preview, run exactly one Recyclarr
              synchronization, update only future Seerr defaults, and verify.
  --verify    Read-only verification of policy, preservation, and zero activity.
  --rollback  Restore API configuration from the protected snapshot without
              touching media. Database restore remains a guarded last resort.

Repeated --apply is verification-only after completion. No mode searches,
downloads, imports, scans, renames, moves, deletes, or reassigns existing media.
EOF
}

require_root() { [ "$EUID" -eq 0 ] || die "$1 must run as root (use sudo)"; }
require_commands() {
  local name
  for name in awk cmp curl docker find ip6tables-save iptables-save mktemp openssl python3 sed sha256sum ss stat; do
    command -v "$name" >/dev/null 2>&1 || die "required command missing: $name"
  done
  [ -x "$HELPER" ] && [ -x /usr/local/sbin/veinfin-firewall ] || die "Quality profile setup helper or firewall verifier is unavailable"
  docker_cmd info >/dev/null || die "Docker daemon is unavailable"
}

api_args() {
  printf '%s\0' --policy "$POLICY" --username "$(env_value MANAGEMENT_USERNAME)" \
    --password-file "$RUNTIME_ROOT/secrets/management-password" \
    --sonarr-key-file "$RUNTIME_ROOT/secrets/sonarr-api-key" \
    --radarr-key-file "$RUNTIME_ROOT/secrets/radarr-api-key" \
    --prowlarr-key-file "$RUNTIME_ROOT/secrets/prowlarr-api-key" \
    --bazarr-key-file "$RUNTIME_ROOT/secrets/bazarr-api-key"
}

run_helper() {
  local mode=$1; shift; local args=()
  while IFS= read -r -d '' item; do args+=("$item"); done < <(api_args)
  "$HELPER" "$mode" "${args[@]}" "$@"
}

check_containers() {
  local service id allowed= all_id
  for service in reverse-proxy jellyfin qbittorrent sonarr radarr prowlarr bazarr seerr flaresolverr; do
    id=$(single_id "$service") || die "exactly one $service container is required"
    [ "$(docker_cmd inspect --format '{{.State.Running}}|{{.State.Health.Status}}|{{.RestartCount}}' "$id")" = true\|healthy\|0 ] || die "$service is not healthy with zero restarts"
    allowed="$allowed$id\n"
  done
  [ "$(docker_cmd ps -aq | awk 'NF{n++}END{print n+0}')" -eq 9 ] || die "runtime must contain exactly nine long-running containers"
  for all_id in $(docker_cmd ps -aq); do printf '%b' "$allowed" | grep -Fxq "$all_id" || die "unrelated container exists"; done
  pass "all nine long-running containers are healthy with zero restarts"
}

check_security() {
  local host code
  /usr/local/sbin/veinfin-firewall --check >/dev/null || die "firewall verification failed"
  ! ss -H -lnt '( sport = :80 or sport = :2375 or sport = :2376 or sport = :8191 )' | grep -q . || die "a prohibited TCP listener exists"
  ! ss -H -lnu 'sport = :443' | grep -q . || die "UDP 443 is listening"
  host=$(env_value PUBLIC_HOSTNAME) || die "public hostname is unavailable"
  code=$(curl -fsS --max-time 15 -o /dev/null -w '%{http_code}' "https://$host/health" || true)
  [ "$code" = 200 ] || die "public Jellyfin HTTPS health check failed"
  pass "firewall, listeners, HTTPS, and Docker API protection remain valid"
}

resource_revision() {
  local repository=$1 head ref
  [ -f "$repository/.git/HEAD" ] || return 1
  head=$(sed -n '1p' "$repository/.git/HEAD")
  case "$head" in
    'ref: '*) ref=${head#ref: }; if [ -f "$repository/.git/$ref" ]; then sed -n '1p' "$repository/.git/$ref"; else awk -v r="$ref" '$2==r{print $1}' "$repository/.git/packed-refs"; fi ;;
    *) printf '%s\n' "$head" ;;
  esac
}

check_resource_locks() {
  local expected_templates expected_trash actual_templates actual_trash
  expected_templates=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["resource_revisions"]["config_templates"])' "$POLICY")
  expected_trash=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["resource_revisions"]["trash_guides"])' "$POLICY")
  actual_templates=$(resource_revision "$CONFIG_ROOT/recyclarr/resources/config-templates/git/official") || die "Recyclarr config-template revision is unavailable"
  actual_trash=$(resource_revision "$CONFIG_ROOT/recyclarr/resources/trash-guides/git/official") || die "TRaSH resource revision is unavailable"
  [ "$actual_templates" = "$expected_templates" ] || die "Recyclarr config-template revision differs from the reviewed lock"
  [ "$actual_trash" = "$expected_trash" ] || die "TRaSH resource revision differs from the reviewed lock"
  pass "Recyclarr resources match the reviewed immutable revisions"
}

normalized_listeners() { ss -H -lntup | awk '{print $1"|"$2"|"$5}' | sort; }
normalized_firewall4() { iptables-save | sed -E '/^# (Generated|Completed)/d; s/ \[[0-9]+:[0-9]+\]$/ [0:0]/'; }
normalized_firewall6() { ip6tables-save | sed -E '/^# (Generated|Completed)/d; s/ \[[0-9]+:[0-9]+\]$/ [0:0]/'; }
https_fingerprint() { local host; host=$(env_value PUBLIC_HOSTNAME); echo | openssl s_client -connect "$host:443" -servername "$host" -verify_hostname "$host" 2>/dev/null | openssl x509 -noout -fingerprint -sha256; }

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
    [ -f "$path" ] && [ ! -L "$path" ] && [ "$(file_mode "$path")" = 600 ] || die "protected Quality profile setup baseline is missing or unsafe"
  done
  for service in reverse-proxy jellyfin qbittorrent sonarr radarr prowlarr bazarr seerr flaresolverr; do
    id=$(single_id "$service"); expected=$(awk -F= -v key="$service" '$1==key{print substr($0,index($0,"=")+1)}' "$BASELINE"); actual=$(fingerprint "$id")
    [ -n "$expected" ] && [ "$actual" = "$expected" ] || die "$service identity, start time, or restart count changed"
  done
  normalized_listeners >"$WORK_DIR/listeners"; normalized_firewall4 >"$WORK_DIR/firewall4"; normalized_firewall6 >"$WORK_DIR/firewall6"; https_fingerprint >"$WORK_DIR/https"
  cmp -s "$LISTENERS" "$WORK_DIR/listeners" || die "listener set changed"
  cmp -s "$FIREWALL4" "$WORK_DIR/firewall4" && cmp -s "$FIREWALL6" "$WORK_DIR/firewall6" || die "firewall state changed"
  cmp -s "$HTTPS_STATE" "$WORK_DIR/https" || die "HTTPS certificate identity changed"
  pass "containers, listeners, firewall, and HTTPS match the Quality profile setup baseline"
}

verify_media() {
  local media_path
  media_path=$(awk -F= '$1=="HOST_SERIES_PATH"{print substr($0,index($0,"=")+1)}' "$STATE/sonarr_adoption-series.conf")
  [ -n "$media_path" ] || die "protected Sonarr adoption media path is unavailable"
  run_helper media-verify --snapshot "$STATE/sonarr_adoption-media-snapshot.json" --media-path "$media_path"
}

run_checks() {
  require_root "this mode"; require_commands
  "$REPO_ROOT/scripts/deploy/indexers-subtitles.sh" --verify >/dev/null || die "Indexer and subtitle setup protected baseline verification failed"
  check_containers; check_security; check_resource_locks
  run_helper validate-policy
  if [ -e "$MARKER" ]; then
    [ -f "$BEFORE" ] && [ "$(file_mode "$BEFORE")" = 600 ] || die "protected pre-quality-profile API state is missing"
    run_helper verify --before "$BEFORE"
  else
    [ ! -e "$STARTED" ] || die "an earlier Quality profile setup apply is unresolved; inspect the protected backup and use --rollback"
    ensure_work; run_helper snapshot --expect initial --output "$WORK_DIR/preflight.json" >/dev/null
  fi
  verify_media
  pass "Quality profile setup read-only readiness checks passed"
}

prepare_backup() {
  local uid gid
  uid=$(env_value PUID); gid=$(env_value PGID)
  if [ ! -e "$BEFORE" ]; then
    run_helper snapshot --expect initial --output "$BEFORE"
  fi
  run_helper backup --before "$BEFORE" --backup-dir "$BACKUP" --config-root "$CONFIG_ROOT" --recyclarr-config "$RUNTIME_ROOT/config/recyclarr"
  run_helper generate --output "$GENERATED" --uid "$uid" --gid "$gid"
  [ "$(file_mode "$GENERATED")" = 600 ] || die "generated Recyclarr configuration permissions are unsafe"
  pass "protected application backups and generated Recyclarr configuration are ready"
}

compose_recyclarr() {
  docker_cmd compose --project-name "$PROJECT_NAME" --env-file "$REPO_ROOT/.env" -f "$REPO_ROOT/compose.yaml" --profile automation run --rm --no-deps recyclarr "$@"
}

do_preview() {
  local output
  run_checks; record_baseline; verify_baseline; prepare_backup; ensure_work
  output=$WORK_DIR/recyclarr-preview.log
  compose_recyclarr sync --instance veinfin-sonarr --instance veinfin-radarr --preview --config /config/quality_profiles.yml --log debug >"$output" 2>&1 || die "official Recyclarr preview failed"
  check_resource_locks
  run_helper preview-summary --preview "$output" --config "$GENERATED" --output "$PREVIEW_SUMMARY"
  verify_baseline; verify_media; check_security
  pass "Quality profile setup official preview gate passed; no synchronization was applied"
}

mark_state() {
  local target=$1 value=$2 temporary
  temporary=$(mktemp "$STATE/.$(basename "$target").XXXXXX"); chmod 0600 "$temporary"; printf '%s\n' "$value" >"$temporary"; chown root:root "$temporary"; mv -f "$temporary" "$target"
}

verify_preview_gate() {
  local expected actual
  [ -f "$PREVIEW_SUMMARY" ] && [ ! -L "$PREVIEW_SUMMARY" ] && [ "$(file_mode "$PREVIEW_SUMMARY")" = 600 ] || die "a protected successful preview is required before apply"
  expected=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["generated_config_sha256"])' "$PREVIEW_SUMMARY")
  actual=$(sha256sum "$GENERATED" | awk '{print $1}')
  [ "$actual" = "$expected" ] || die "generated configuration changed after preview"
  check_resource_locks
}

do_apply() {
  local status
  run_checks; record_baseline; verify_baseline
  if [ -e "$MARKER" ]; then
    info "Quality profile setup is already complete; running verification only"
  else
    prepare_backup; verify_preview_gate; mark_state "$STARTED" started
    set +e
    compose_recyclarr sync --instance veinfin-sonarr --instance veinfin-radarr --config /config/quality_profiles.yml
    status=$?
    if [ "$status" -eq 0 ]; then run_helper seerr-apply --before "$BEFORE"; status=$?; fi
    set -e
    if [ "$status" -ne 0 ]; then
      run_helper rollback --before "$BEFORE" || die "Quality profile setup failed and API rollback also failed; protected backups remain available"
      rm -f -- "$STARTED"
      die "Quality profile setup apply failed and the pre-quality-profile API state was restored"
    fi
    run_helper verify --before "$BEFORE" || { run_helper rollback --before "$BEFORE"; rm -f -- "$STARTED"; die "Quality profile setup verification failed and API state was restored"; }
    mark_state "$MARKER" completed
    rm -f -- "$STARTED"
  fi
  run_helper verify --before "$BEFORE"; verify_baseline; verify_media; check_security; check_resource_locks
  pass "Quality profile setup apply completed"
}

do_verify() { run_checks; verify_baseline; run_helper verify --before "$BEFORE"; verify_media; check_security; check_resource_locks; pass "Quality profile setup verification completed"; }

do_rollback() {
  require_root "--rollback"; require_commands
  [ -f "$BEFORE" ] || die "protected Quality profile setup API backup is absent"
  run_helper rollback --before "$BEFORE"
  rm -f -- "$MARKER" "$STARTED" "$PREVIEW_SUMMARY" "$GENERATED"
  check_containers; check_security; verify_baseline; verify_media
  pass "Quality profile setup API rollback completed; database and state backups were preserved"
}

if [ "${VEINFIN_QUALITY_PROFILES_LIBRARY_ONLY:-0}" = 1 ]; then return 0 2>/dev/null || exit 0; fi
[ "$#" -eq 1 ] || { usage >&2; exit 2; }
case "$1" in
  --help) usage ;;
  --check) run_checks ;;
  --preview) do_preview ;;
  --apply) do_apply ;;
  --verify) do_verify ;;
  --rollback) do_rollback ;;
  *) usage >&2; exit 2 ;;
esac
