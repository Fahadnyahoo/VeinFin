#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=${VEINFIN_REPO_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd -P)}
DEPLOY_ROOT=${VEINFIN_DEPLOY_ROOT:-$REPO_ROOT}
RUNTIME_ROOT=$DEPLOY_ROOT/runtime
CONFIG_ROOT=${VEINFIN_CONFIG_ROOT:-/var/lib/veinfin}
PROJECT_NAME=${VEINFIN_PROJECT_NAME:-veinfin}
MANIFEST=${VEINFIN_LIBRARIES_MANIFEST:-$RUNTIME_ROOT/state/libraries-media.conf}
REPORT=$RUNTIME_ROOT/state/libraries-media-report.json
BASELINE=$RUNTIME_ROOT/state/libraries-preserved-containers.txt
MARKER=$RUNTIME_ROOT/state/libraries-scan-complete
SCAN_STARTED=$RUNTIME_ROOT/state/libraries-scan-started
MEDIA_HELPER=$SCRIPT_DIR/libraries_api.py
FIREWALL=${VEINFIN_FIREWALL_SCRIPT:-/usr/local/sbin/veinfin-firewall}

info() { printf 'INFO: %s\n' "$*"; }
pass() { printf 'PASS: %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
as_root() { if [ "$EUID" -eq 0 ]; then "$@"; else sudo -n --preserve-env=SSH_CONNECTION "$@"; fi; }
docker_cmd() { as_root docker "$@"; }
file_mode() { stat -c '%a' "$1"; }
service_id() { docker_cmd ps -aq --filter "label=com.docker.compose.project=$PROJECT_NAME" --filter "label=com.docker.compose.service=$1"; }
single_id() { local id; id=$(service_id "$1"); [ -n "$id" ] && [ "$(printf '%s\n' "$id" | awk 'NF{n++}END{print n+0}')" -eq 1 ] || return 1; printf '%s\n' "$id"; }
fingerprint() { docker_cmd inspect --format '{{.Id}}|{{.State.StartedAt}}|{{.RestartCount}}' "$1"; }

usage() {
  cat <<'EOF'
VeinFin Library setup Jellyfin library deployment

Usage:
  scripts/deploy/libraries.sh --help
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/libraries.sh --check
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/libraries.sh --apply
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/libraries.sh --verify

Modes:
  --check   Read-only validation of the protected runtime manifest, storage,
            media inventory shape, nine containers, HTTPS, and isolation.
  --apply   Probe every expected MKV with Jellyfin's bundled ffprobe, create
            exactly Movies, TV Shows, and Anime, and perform one controlled
            library scan. A protected marker prevents a second scan.
  --verify  Re-probe media, validate Jellyfin recognition and playback-info
            samples, and prove containers, HTTPS, firewall, and storage stayed
            unchanged. No watch state or media file is changed.

The mode-0600 root-owned manifest is deployment-local and must define:
HOST_MEDIA_PATH, CONTAINER_MEDIA_PATH, EXPECTED_SERIES_NAME, EPISODE_PATTERN,
EXPECTED_EPISODES, EXPECTED_LANGUAGE, and EXPECTED_COUNTRY. Tracked files never
contain a personal media title or path. This workflow does not rename media.
EOF
}

require_root() { [ "$EUID" -eq 0 ] || die "$1 must run as root (use sudo)"; }
manifest_value() {
  local key=$1
  awk -F= -v key="$key" '$1==key{n++;v=substr($0,index($0,"=")+1)}END{if(n!=1||v=="")exit 1;print v}' "$MANIFEST"
}

load_manifest() {
  [ -f "$MANIFEST" ] && [ ! -L "$MANIFEST" ] || die "protected Library setup manifest is missing"
  [ "$(file_mode "$MANIFEST")" = 600 ] && [ "$(stat -c '%u:%g' "$MANIFEST")" = 0:0 ] || die "Library setup manifest must be root-owned mode 0600"
  HOST_MEDIA_PATH=$(manifest_value HOST_MEDIA_PATH) || die "manifest HOST_MEDIA_PATH is missing"
  CONTAINER_MEDIA_PATH=$(manifest_value CONTAINER_MEDIA_PATH) || die "manifest CONTAINER_MEDIA_PATH is missing"
  EXPECTED_SERIES_NAME=$(manifest_value EXPECTED_SERIES_NAME) || die "manifest EXPECTED_SERIES_NAME is missing"
  EPISODE_PATTERN=$(manifest_value EPISODE_PATTERN) || die "manifest EPISODE_PATTERN is missing"
  EXPECTED_EPISODES=$(manifest_value EXPECTED_EPISODES) || die "manifest EXPECTED_EPISODES is missing"
  EXPECTED_LANGUAGE=$(manifest_value EXPECTED_LANGUAGE) || die "manifest EXPECTED_LANGUAGE is missing"
  EXPECTED_COUNTRY=$(manifest_value EXPECTED_COUNTRY) || die "manifest EXPECTED_COUNTRY is missing"
  [[ $HOST_MEDIA_PATH == /srv/media/library/anime/* ]] || die "host media path must be below the Anime root"
  [[ $CONTAINER_MEDIA_PATH == /data/library/anime/* ]] || die "container media path must be below the Anime root"
  [[ $EXPECTED_EPISODES =~ ^[1-9][0-9]*$ ]] || die "expected episode count is invalid"
  [[ $EXPECTED_LANGUAGE =~ ^[a-z]{2,3}$ ]] || die "metadata language is invalid"
  [[ $EXPECTED_COUNTRY =~ ^[A-Z]{2}$ ]] || die "metadata country is invalid"
}

env_value() { awk -F= -v key="$1" '$1==key{n++;v=substr($0,index($0,"=")+1)}END{if(n!=1)exit 1;print v}' "$REPO_ROOT/.env"; }

require_commands() {
  local command_name
  for command_name in awk curl docker find findmnt grep lsblk mountpoint openssl pgrep python3 ss stat; do command -v "$command_name" >/dev/null || die "required command missing: $command_name"; done
  [ -x "$MEDIA_HELPER" ] && [ -x "$FIREWALL" ] || die "Library setup helper or firewall verifier is unavailable"
  docker_cmd info >/dev/null || die "Docker daemon is unavailable"
}

check_containers() {
  local service id allowed= count all_id
  for service in reverse-proxy jellyfin qbittorrent sonarr radarr prowlarr bazarr seerr flaresolverr; do
    id=$(single_id "$service") || die "exactly one $service container is required"
    [ "$(docker_cmd inspect --format '{{.State.Running}}|{{.State.Health.Status}}' "$id")" = true\|healthy ] || die "$service is not healthy"
    allowed="$allowed$id\n"
  done
  count=$(docker_cmd ps -aq | awk 'NF{n++}END{print n+0}'); [ "$count" -eq 9 ] || die "runtime must contain exactly nine containers"
  for all_id in $(docker_cmd ps -aq); do printf '%b' "$allowed" | grep -Fxq "$all_id" || die "unrelated container exists"; done
  pass "all nine expected containers are healthy"
}

check_storage() {
  local jellyfin_id mount_info
  mountpoint -q /srv/media || die "/srv/media is not a mounted filesystem"
  findmnt -rn -o OPTIONS /srv/media | grep -Eq '(^|,)rw(,|$)' || die "/srv/media is not read-write"
  [ -d "$HOST_MEDIA_PATH" ] && [ ! -L "$HOST_MEDIA_PATH" ] || die "configured media directory is unavailable"
  jellyfin_id=$(single_id jellyfin)
  mount_info=$(docker_cmd inspect --format '{{range .Mounts}}{{if eq .Destination "/data/library"}}{{.Source}}|{{.RW}}{{end}}{{end}}' "$jellyfin_id")
  [ "$mount_info" = /srv/media/library\|false ] || die "Jellyfin library mount is not exact and read-only"
  pass "media storage is mounted and Jellyfin sees it read-only"
}

check_media_shape() {
  local count nonempty
  count=$(find "$HOST_MEDIA_PATH" -type f -iname '*.mkv' ! -lname '*' -print | awk 'END{print NR+0}')
  nonempty=$(find "$HOST_MEDIA_PATH" -type f -iname '*.mkv' ! -lname '*' -size +0c -print | awk 'END{print NR+0}')
  [ "$count" -eq "$EXPECTED_EPISODES" ] && [ "$nonempty" -eq "$EXPECTED_EPISODES" ] || die "media inventory does not have the expected non-empty MKV count"
  pass "media inventory has the expected non-empty MKV count"
}

check_security() {
  local host code
  "$FIREWALL" --check >/dev/null || die "firewall verification failed"
  ! ss -H -lnt '( sport = :80 or sport = :2375 or sport = :2376 or sport = :8191 )' | grep -q . || die "a prohibited TCP listener exists"
  ! ss -H -lnu 'sport = :443' | grep -q . || die "UDP 443 is listening"
  [ "$(ss -H -lnt 'sport = :443' | awk 'NF{n++}END{print n+0}')" -ge 1 ] || die "HTTPS listener is missing"
  host=$(env_value PUBLIC_HOSTNAME) || die "public hostname is unavailable"
  code=$(curl -fsS --max-time 15 -o /dev/null -w '%{http_code}' "https://$host/health" || true)
  [ "$code" = 200 ] || die "public Jellyfin HTTPS health check failed"
  pass "HTTPS and firewall isolation remain valid"
}

check_rsync_and_legacy() {
  local rw_legacy ro_legacy
  [ "$(pgrep -x rsync 2>/dev/null | awk 'NF{n++}END{print n+0}')" -eq 0 ] || die "active rsync detected; stop before Library setup"
  read -r ro_legacy rw_legacy < <(lsblk -b -nrpo TYPE,SIZE,RO,MOUNTPOINTS | awk '$1=="part" && $2>=900000000000 && $2<=1100000000000 && $4!="" {if($3==1)ro++;else rw++}END{print ro+0,rw+0}')
  [ "$ro_legacy" -eq 1 ] && [ "$rw_legacy" -eq 0 ] || die "protected 1 TB read-only disk contract changed"
  pass "no rsync is active and the protected 1 TB disk remains read-only"
}

run_checks() { require_root "this mode"; require_commands; load_manifest; check_containers; check_storage; check_media_shape; check_rsync_and_legacy; check_security; }

record_baseline() {
  local service id state=$RUNTIME_ROOT/state
  install -d -o root -g root -m 0700 "$state"
  if [ ! -e "$BASELINE" ]; then
    { for service in reverse-proxy jellyfin qbittorrent sonarr radarr prowlarr bazarr seerr flaresolverr; do id=$(single_id "$service"); printf '%s=%s\n' "$service" "$(fingerprint "$id")"; done; } |
      python3 -c 'import os,secrets,sys; p=sys.argv[1]; t=p+"."+secrets.token_hex(8); f=os.open(t,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600); h=os.fdopen(f,"w"); h.write(sys.stdin.read()); h.flush(); os.fsync(h.fileno()); h.close(); os.replace(t,p)' "$BASELINE"
  fi
  [ "$(file_mode "$BASELINE")" = 600 ] || die "container baseline permissions are unsafe"
}

verify_baseline() {
  local service id expected actual
  [ -f "$BASELINE" ] && [ ! -L "$BASELINE" ] && [ "$(file_mode "$BASELINE")" = 600 ] || die "protected container baseline is missing"
  for service in reverse-proxy jellyfin qbittorrent sonarr radarr prowlarr bazarr seerr flaresolverr; do
    id=$(single_id "$service"); expected=$(awk -F= -v key="$service" '$1==key{print substr($0,index($0,"=")+1)}' "$BASELINE"); actual=$(fingerprint "$id")
    [ -n "$expected" ] && [ "$actual" = "$expected" ] || die "$service container identity, start time, or restart count changed"
  done
  pass "all nine container identities, start times, and restart counts are preserved"
}

probe_media() {
  "$MEDIA_HELPER" probe --host-media-path "$HOST_MEDIA_PATH" --container-media-path "$CONTAINER_MEDIA_PATH" \
    --episode-pattern "$EPISODE_PATTERN" --expected-count "$EXPECTED_EPISODES" --report "$REPORT"
}

jellyfin_action() {
  local action=$1 username
  username=$(env_value MANAGEMENT_USERNAME) || die "management username is unavailable"
  "$MEDIA_HELPER" "$action" --username "$username" --password-file "$RUNTIME_ROOT/secrets/management-password" \
    --expected-series-name "$EXPECTED_SERIES_NAME" --expected-count "$EXPECTED_EPISODES" \
    --language "$EXPECTED_LANGUAGE" --country "$EXPECTED_COUNTRY" --report "$REPORT"
}

mark_state() {
  local target=$1 value=$2 temporary
  temporary=$(mktemp "$RUNTIME_ROOT/state/.$(basename "$target").XXXXXX"); chmod 0600 "$temporary"; printf '%s\n' "$value" >"$temporary"; mv -f "$temporary" "$target"
}

do_apply() {
  run_checks; record_baseline; verify_baseline; probe_media
  if [ -e "$MARKER" ]; then
    [ -f "$MARKER" ] && [ ! -L "$MARKER" ] && [ "$(file_mode "$MARKER")" = 600 ] || die "scan marker is unsafe"
    info "controlled scan already completed; verifying without scanning"
    jellyfin_action verify
  else
    [ ! -e "$SCAN_STARTED" ] || die "an earlier scan start is recorded without completion; inspect Jellyfin and the protected report before recovery"
    mark_state "$SCAN_STARTED" started
    jellyfin_action apply
    mark_state "$MARKER" completed
    rm -f -- "$SCAN_STARTED"
  fi
  verify_baseline; check_security
  pass "Library setup apply completed"
}

do_verify() { run_checks; verify_baseline; probe_media; jellyfin_action verify; verify_baseline; check_security; pass "Library setup verification completed"; }

if [ "${VEINFIN_LIBRARIES_LIBRARY_ONLY:-0}" = 1 ]; then return 0 2>/dev/null || exit 0; fi
mode=${1:-}
[ "$#" -eq 1 ] || { usage; exit 2; }
case "$mode" in
  --help) usage ;;
  --check) run_checks; pass "Library setup read-only readiness check completed" ;;
  --apply) do_apply ;;
  --verify) do_verify ;;
  *) usage; exit 2 ;;
esac
