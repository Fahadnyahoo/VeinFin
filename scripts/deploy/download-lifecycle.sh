#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=${VEINFIN_REPO_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd -P)}
DEPLOY_ROOT=${VEINFIN_DEPLOY_ROOT:-$REPO_ROOT}
RUNTIME_ROOT=$DEPLOY_ROOT/runtime
CONFIG_ROOT=${VEINFIN_CONFIG_ROOT:-/var/lib/veinfin}
MEDIA_ROOT=${VEINFIN_MEDIA_ROOT:-/srv/media}
PROJECT_NAME=${VEINFIN_PROJECT_NAME:-veinfin}
STATE=$RUNTIME_ROOT/state
ORIGINAL_BACKUP=$RUNTIME_ROOT/backups/download_lifecycle-apps-before
RETRY1_BACKUP=$RUNTIME_ROOT/backups/download_lifecycle-retry1-apps-before
BACKUP=$RUNTIME_ROOT/backups/download_lifecycle-retry1b-apps-before
POLICY=$REPO_ROOT/config/download-lifecycle-policy.json
HELPER=$SCRIPT_DIR/download_lifecycle.py
BEFORE=$STATE/download_lifecycle-retry1b-api-before.json
PREVIEW=$STATE/download_lifecycle-retry1b-preview.json
MARKER=$STATE/download_lifecycle-complete
STARTED=$STATE/download_lifecycle-started
BLOCKED=$STATE/download_lifecycle-blocked
BASELINE=$STATE/download_lifecycle-preserved-containers.txt
LISTENERS=$STATE/download_lifecycle-listeners-before.txt
FIREWALL4=$STATE/download_lifecycle-firewall-v4-before.rules
FIREWALL6=$STATE/download_lifecycle-firewall-v6-before.rules
HTTPS_STATE=$STATE/download_lifecycle-https-before.txt
VALIDATION_ROOT=$MEDIA_ROOT/torrents/.veinfin-download_lifecycle-validation
WORK_DIR=
VALIDATED_SSH_CONNECTION=
SUDO_BIN=${VEINFIN_SUDO_BIN:-sudo}

# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/lib/common.sh"

info() { printf 'INFO: %s\n' "$*"; }
pass() { printf 'PASS: %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
effective_uid() { id -u; }
validate_ssh_context() {
  command -v ss >/dev/null 2>&1 || die "required command missing: ss"
  [ -n "${SSH_CONNECTION:-}" ] || die "SSH_CONNECTION is required and must identify the active administrative session"
  ss -H -tn state established | "$HELPER" validate-ssh >/dev/null || die "SSH_CONNECTION is malformed or does not match the active administrative session"
  VALIDATED_SSH_CONNECTION=$SSH_CONNECTION
  export SSH_CONNECTION
}
enter_privileged() {
  validate_ssh_context
  if [ "$(effective_uid)" -ne 0 ]; then
    exec "$SUDO_BIN" --preserve-env=SSH_CONNECTION "$SCRIPT_DIR/download-lifecycle.sh" "$@"
  fi
}
as_root() { if [ "$(effective_uid)" -eq 0 ]; then "$@"; else "$SUDO_BIN" --preserve-env=SSH_CONNECTION "$@"; fi; }
docker_cmd() { as_root docker "$@"; }
file_mode() { stat -c '%a' "$1"; }
ensure_work() { if [ -z "$WORK_DIR" ]; then WORK_DIR=$(mktemp -d /tmp/veinfin-download_lifecycle.XXXXXX); chmod 0700 "$WORK_DIR"; fi; }
cleanup() { [ -z "${WORK_DIR:-}" ] || [ ! -d "$WORK_DIR" ] || find "$WORK_DIR" -depth -delete 2>/dev/null || true; vf_cleanup; }
trap cleanup EXIT HUP INT TERM
service_id() { docker_cmd ps -aq --filter "label=com.docker.compose.project=$PROJECT_NAME" --filter "label=com.docker.compose.service=$1"; }
single_id() { local id; id=$(service_id "$1"); [ -n "$id" ] && [ "$(printf '%s\n' "$id" | awk 'NF{n++}END{print n+0}')" -eq 1 ] || return 1; printf '%s\n' "$id"; }
fingerprint() { docker_cmd inspect --format '{{.Id}}|{{.State.StartedAt}}|{{.RestartCount}}' "$1"; }
env_value() { awk -F= -v key="$1" '$1==key{n++;v=substr($0,index($0,"=")+1)}END{if(n!=1)exit 1;print v}' "$REPO_ROOT/.env"; }

usage() {
  cat <<'EOF'
VeinFin Download lifecycle setup production download-lifecycle configuration

Usage:
  scripts/deploy/download-lifecycle.sh --help
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/download-lifecycle.sh --check
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/download-lifecycle.sh --preview
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/download-lifecycle.sh --apply
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/download-lifecycle.sh --verify
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/download-lifecycle.sh --rollback

Modes:
  --check     Read-only health, activity, path, policy, and preservation checks.
  --preview   Create protected backups and a sanitized configuration/deletion
              preview. It never creates a torrent or deletes data.
  --apply     Apply and verify only the reviewed production API configuration.
              It never creates a torrent or validation file.
  --verify    Read-only verification of policy and protected state.
  --rollback  Restore API configuration from the protected snapshot; media and
              preserved backups are never changed.

The first apply requires a successful preview. Repeated --apply is verification-only.
The optional live synthetic proof is deferred and is not called by this entry point.
No mode searches for or downloads content, scans media, or starts Control panel setup.
EOF
}

require_root() { [ "$EUID" -eq 0 ] || die "$1 must run as root (use sudo)"; }
require_commands() {
  local name
  for name in awk cmp curl docker find findmnt ip6tables-save iptables-save mktemp openssl python3 sed sha256sum ss stat; do
    command -v "$name" >/dev/null 2>&1 || die "required command missing: $name"
  done
  [ -x "$HELPER" ] && [ -x /usr/local/sbin/veinfin-firewall ] || die "Download lifecycle setup helper or firewall verifier is unavailable"
  docker_cmd info >/dev/null || die "Docker daemon is unavailable"
}

api_args() {
  printf '%s\0' --policy "$POLICY" --username "$(env_value MANAGEMENT_USERNAME)" \
    --password-file "$RUNTIME_ROOT/secrets/management-password" \
    --sonarr-key-file "$RUNTIME_ROOT/secrets/sonarr-api-key" \
    --radarr-key-file "$RUNTIME_ROOT/secrets/radarr-api-key" \
    --prowlarr-key-file "$RUNTIME_ROOT/secrets/prowlarr-api-key" \
    --bazarr-key-file "$RUNTIME_ROOT/secrets/bazarr-api-key" \
    --media-root "$(env_value MEDIA_ROOT)"
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
  [ -n "$VALIDATED_SSH_CONNECTION" ] && [ "$SSH_CONNECTION" = "$VALIDATED_SSH_CONNECTION" ] || die "validated SSH connection context changed"
  SSH_CONNECTION=$VALIDATED_SSH_CONNECTION /usr/local/sbin/veinfin-firewall --check >/dev/null || die "firewall verification failed"
  ! ss -H -lnt '( sport = :80 or sport = :2375 or sport = :2376 or sport = :8191 )' | grep -q . || die "a prohibited TCP listener exists"
  ! ss -H -lnu 'sport = :443' | grep -q . || die "UDP 443 is listening"
  host=$(env_value PUBLIC_HOSTNAME) || die "public hostname is unavailable"
  code=$(curl -fsS --max-time 15 -o /dev/null -w '%{http_code}' "https://$host/health" || true)
  [ "$code" = 200 ] || die "public Jellyfin HTTPS health check failed"
  pass "firewall, listeners, HTTPS, and Docker API protection remain valid"
}

check_storage() {
  local media device path qbit_id sonarr_id radarr_id
  media=$(env_value MEDIA_ROOT); [ "$media" = "$MEDIA_ROOT" ] || die "configured media roots disagree"
  findmnt -T "$media" >/dev/null || die "media root is not on an available mounted filesystem"
  device=
  for path in "$media/torrents" "$media/torrents/incomplete" "$media/torrents/movies" "$media/torrents/tv" "$media/torrents/anime" "$media/library/movies" "$media/library/tv" "$media/library/anime"; do
    [ -d "$path" ] && [ ! -L "$path" ] || die "required media directory is unavailable"
    if [ -z "$device" ]; then device=$(stat -c '%d' "$path"); else [ "$(stat -c '%d' "$path")" = "$device" ] || die "torrent and library paths are not on one filesystem"; fi
  done
  qbit_id=$(single_id qbittorrent); sonarr_id=$(single_id sonarr); radarr_id=$(single_id radarr)
  [ "$(docker_cmd exec "$qbit_id" stat -c '%d' /data/torrents /data/torrents/incomplete /data/torrents/movies /data/torrents/tv /data/torrents/anime | sort -u | wc -l)" -eq 1 ] || die "qBittorrent /data paths do not share a filesystem"
  [ "$(docker_cmd exec "$sonarr_id" stat -c '%d' /data/torrents /data/library | sort -u | wc -l)" -eq 1 ] || die "Sonarr /data paths do not share a filesystem"
  [ "$(docker_cmd exec "$radarr_id" stat -c '%d' /data/torrents /data/library | sort -u | wc -l)" -eq 1 ] || die "Radarr /data paths do not share a filesystem"
  pass "incomplete, completed, and library paths resolve consistently on one filesystem"
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
    [ -f "$path" ] && [ ! -L "$path" ] && [ "$(file_mode "$path")" = 600 ] || die "protected Download lifecycle setup baseline is missing or unsafe"
  done
  for service in reverse-proxy jellyfin qbittorrent sonarr radarr prowlarr bazarr seerr flaresolverr; do
    id=$(single_id "$service"); expected=$(awk -F= -v key="$service" '$1==key{print substr($0,index($0,"=")+1)}' "$BASELINE"); actual=$(fingerprint "$id")
    [ -n "$expected" ] && [ "$actual" = "$expected" ] || die "$service identity, start time, or restart count changed"
  done
  normalized_listeners >"$WORK_DIR/listeners"; normalized_firewall4 >"$WORK_DIR/firewall4"; normalized_firewall6 >"$WORK_DIR/firewall6"; https_fingerprint >"$WORK_DIR/https"
  cmp -s "$LISTENERS" "$WORK_DIR/listeners" || die "listener set changed"
  cmp -s "$FIREWALL4" "$WORK_DIR/firewall4" && cmp -s "$FIREWALL6" "$WORK_DIR/firewall6" || die "firewall state changed"
  cmp -s "$HTTPS_STATE" "$WORK_DIR/https" || die "HTTPS certificate identity changed"
  pass "containers, listeners, firewall, and HTTPS match the Download lifecycle setup baseline"
}

verify_media() {
  local media_path
  media_path=$(awk -F= '$1=="HOST_SERIES_PATH"{print substr($0,index($0,"=")+1)}' "$STATE/sonarr_adoption-series.conf")
  [ -n "$media_path" ] || die "protected Sonarr adoption media path is unavailable"
  "$SCRIPT_DIR/quality_profiles.py" media-verify --snapshot "$STATE/sonarr_adoption-media-snapshot.json" --media-path "$media_path"
}

run_checks() {
  require_root "this mode"; require_commands
  if [ ! -e "$MARKER" ]; then "$SCRIPT_DIR/quality-profiles.sh" --verify >/dev/null || die "Quality profile setup protected baseline verification failed"; fi
  check_containers; check_security; check_storage; run_helper validate-policy
  if [ -e "$MARKER" ]; then
    [ -f "$BEFORE" ] && [ "$(file_mode "$BEFORE")" = 600 ] || die "protected pre-download-lifecycle API state is missing"
    run_helper verify --before "$BEFORE" --validation-root "$VALIDATION_ROOT"
  else
    [ ! -e "$STARTED" ] || die "an earlier Download lifecycle setup apply is unresolved; inspect the protected backup and use --rollback"
    ensure_work; run_helper snapshot --output "$WORK_DIR/preflight.json" >/dev/null
  fi
  verify_media; pass "Download lifecycle setup read-only readiness checks passed"
}

prepare_backup() {
  install -d -o root -g root -m 0700 "$STATE" "$RUNTIME_ROOT/backups"
  [ -d "$ORIGINAL_BACKUP" ] && [ ! -L "$ORIGINAL_BACKUP" ] && [ "$(file_mode "$ORIGINAL_BACKUP")" = 700 ] || die "original Download lifecycle setup backup is missing or unsafe"
  [ -d "$RETRY1_BACKUP" ] && [ ! -L "$RETRY1_BACKUP" ] && [ "$(file_mode "$RETRY1_BACKUP")" = 700 ] || die "Download lifecycle setup Retry 1 backup is missing or unsafe"
  if [ ! -e "$BEFORE" ]; then run_helper snapshot --output "$BEFORE"; fi
  run_helper backup --before "$BEFORE" --backup-dir "$BACKUP" --config-root "$CONFIG_ROOT"
  pass "protected configuration backups are ready"
}

mark_state() {
  local target=$1 value=$2 temporary
  temporary=$(mktemp "$STATE/.$(basename "$target").XXXXXX"); chmod 0600 "$temporary"; printf '%s\n' "$value" >"$temporary"; chown root:root "$temporary"; mv -f "$temporary" "$target"
}

do_preview() {
  run_checks; record_baseline; verify_baseline; prepare_backup
  run_helper preview --output "$PREVIEW"
  verify_baseline; verify_media; check_security
  pass "Download lifecycle setup preview completed without torrent creation or deletion"
}

do_apply() {
  local status
  run_checks; record_baseline; verify_baseline
  [ ! -e "$BLOCKED" ] || die "a prior Download lifecycle setup apply failed; a separately reviewed retry must clear the protected block"
  if [ -e "$MARKER" ]; then
    info "Download lifecycle setup is already complete; running verification only"
  else
    prepare_backup
    [ -f "$PREVIEW" ] && [ ! -L "$PREVIEW" ] && [ "$(file_mode "$PREVIEW")" = 600 ] || die "a protected successful preview is required before apply"
    mark_state "$STARTED" started
    set +e
    run_helper apply-config
    status=$?
    set -e
    if [ "$status" -ne 0 ]; then
      run_helper rollback --before "$BEFORE" || die "Download lifecycle setup failed and API rollback also failed; protected backups remain available"
      mark_state "$BLOCKED" "configuration-apply-failed"; rm -f -- "$STARTED"
      die "Download lifecycle setup apply failed and pre-download-lifecycle API configuration was restored"
    fi
    if ! run_helper verify --before "$BEFORE" --validation-root "$VALIDATION_ROOT"; then
      run_helper rollback --before "$BEFORE" || die "Download lifecycle setup verification and rollback both failed; protected backups remain available"
      mark_state "$BLOCKED" "final-verification-failed"; rm -f -- "$STARTED"
      die "Download lifecycle setup verification failed and API configuration was restored"
    fi
    mark_state "$MARKER" completed; rm -f -- "$STARTED"
  fi
  run_helper verify --before "$BEFORE" --validation-root "$VALIDATION_ROOT"
  verify_baseline; verify_media; check_security
  pass "Download lifecycle setup apply completed"
}

do_verify() {
  [ -f "$MARKER" ] || die "Download lifecycle setup is not complete; final verification is unavailable"
  run_checks; verify_baseline; verify_media; check_security; pass "Download lifecycle setup verification completed"
}

do_rollback() {
  require_root "--rollback"; require_commands
  [ -f "$BEFORE" ] || die "protected Download lifecycle setup API backup is absent"
  run_helper rollback --before "$BEFORE"
  [ ! -e "$VALIDATION_ROOT" ] || die "validation workspace remains; refusing broad cleanup"
  rm -f -- "$MARKER" "$STARTED" "$PREVIEW"
  check_containers; check_security; verify_baseline; verify_media
  pass "Download lifecycle setup API rollback completed; backups were preserved"
}

if [ "${VEINFIN_DOWNLOAD_LIFECYCLE_LIBRARY_ONLY:-0}" = 1 ]; then return 0 2>/dev/null || exit 0; fi
[ "$#" -eq 1 ] || { usage >&2; exit 2; }
case "$1" in
  --help) usage ;;
  --check|--preview|--apply|--verify|--rollback)
    enter_privileged "$@"
    case "$1" in
      --check) run_checks ;;
      --preview) do_preview ;;
      --apply) do_apply ;;
      --verify) do_verify ;;
      --rollback) do_rollback ;;
    esac
    ;;
  *) usage >&2; exit 2 ;;
esac
