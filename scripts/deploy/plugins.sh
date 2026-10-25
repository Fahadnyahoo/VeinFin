#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=${VEINFIN_REPO_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd -P)}
DEPLOY_ROOT=${VEINFIN_DEPLOY_ROOT:-$REPO_ROOT}
RUNTIME_ROOT=$DEPLOY_ROOT/runtime
STATE=$RUNTIME_ROOT/state
BACKUPS=$RUNTIME_ROOT/backups/plugins
LOCK=$REPO_ROOT/config/plugins.lock
ENHANCED_PROFILE=$REPO_ROOT/config/jellyfin-enhanced-profile.json
ASSET_LOCK=$REPO_ROOT/config/legacy-ui-assets.lock
HELPER=$SCRIPT_DIR/plugins.py
LEGACY_HELPER=$SCRIPT_DIR/legacy_ui.py
STAGING=$RUNTIME_ROOT/generated/plugins
MARKER=$STATE/plugins-complete
STARTED=$STATE/plugins-started
BACKUP_POINTER=$STATE/plugins-backup-path
INTEGRATIONS_MARKER=$STATE/jellyfin-enhanced-integrations-complete
SEERR_MARKER=$STATE/jellyfin-enhanced-seerr-complete
PROFILE_MARKER=$STATE/jellyfin-enhanced-profile.sha256
INTEGRATIONS_BACKUP_POINTER=$STATE/jellyfin-enhanced-backup-path
INTEGRATIONS_BACKUPS=$RUNTIME_ROOT/backups/jellyfin-enhanced-integrations
WORK_DIR=
VALIDATED_SSH_CONNECTION=
SUDO_BIN=${VEINFIN_SUDO_BIN:-sudo}

# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/lib/common.sh"

info(){ printf 'INFO: %s\n' "$*"; }
pass(){ printf 'PASS: %s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
cleanup(){ [ -z "${WORK_DIR:-}" ] || [ ! -d "$WORK_DIR" ] || find "$WORK_DIR" -depth -delete 2>/dev/null || true; vf_cleanup; }
trap cleanup EXIT HUP INT TERM

usage(){ cat <<'EOF'
VeinFin supported Jellyfin plugin installer

Usage:
  scripts/deploy/plugins.sh --help
  scripts/deploy/plugins.sh --check
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/plugins.sh --apply
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/plugins.sh --verify
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/plugins.sh --rollback
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/plugins.sh --configure-integrations
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/plugins.sh --verify-integrations
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/plugins.sh --rollback-integrations

The installer accepts no repository or artifact URL arguments. It installs only
the immutable Jellyfin 10.11 allowlist in config/plugins.lock, makes a protected Jellyfin
backup, performs one controlled Jellyfin stop/start, and restores the backup if
Jellyfin cannot become healthy. A repeated apply is verification-only.

The integration command configures Jellyfin Enhanced through Jellyfin's supported
plugin API, reads provider keys only from protected runtime secret files, performs
Sonarr, Radarr, Bazarr, URL-mapping, and exposure checks, and does not restart
Jellyfin. Repeated integration configuration is verification-only.
Profile-version changes use a protected pre-change backup and can be restored
through the supported plugin API without restarting Jellyfin.
EOF
}

env_value(){ awk -F= -v key="$1" '$1==key{n++;v=substr($0,index($0,"=")+1)}END{if(n!=1)exit 1;print v}' "$REPO_ROOT/.env"; }
is_lan_only(){ [ "$(env_value INSTALLATION_PROFILE)" = lan-only ]; }
protected_services(){
  if is_lan_only; then printf '%s\n' jellyfin qbittorrent sonarr radarr prowlarr bazarr seerr flaresolverr veinfin-panel veinfin-agent; else printf '%s\n' reverse-proxy jellyfin qbittorrent sonarr radarr prowlarr bazarr seerr flaresolverr veinfin-panel veinfin-agent; fi
}
service_id(){ docker ps -aq --filter "label=com.docker.compose.project=$(env_value COMPOSE_PROJECT_NAME)" --filter "label=com.docker.compose.service=$1"; }
file_mode(){ stat -c '%a' "$1"; }
ensure_work(){ if [ -z "$WORK_DIR" ]; then WORK_DIR=$(mktemp -d /tmp/veinfin-plugins.XXXXXX); chmod 0700 "$WORK_DIR"; fi; }

validate_ssh_context(){
  [ -n "${SSH_CONNECTION:-}" ] || die "SSH_CONNECTION is required"
  ss -H -tn state established | "$SCRIPT_DIR/download_lifecycle.py" validate-ssh >/dev/null || die "SSH connection context is invalid"
  VALIDATED_SSH_CONNECTION=$SSH_CONNECTION; export SSH_CONNECTION
}

enter_privileged(){
  validate_ssh_context
  if [ "$(id -u)" -ne 0 ]; then exec "$SUDO_BIN" --preserve-env=SSH_CONNECTION "$SCRIPT_DIR/plugins.sh" "$@"; fi
}

require_commands(){
  local command
  for command in awk curl docker find install mktemp python3 sha256sum ss stat tar; do
    command -v "$command" >/dev/null || die "required command missing: $command"
  done
  docker info >/dev/null || die "Docker is unavailable"
}

check_containers(){
  local service id status count=0
  for service in $(protected_services); do
    id=$(service_id "$service"); [ -n "$id" ] || die "$service is absent"
    status=$(docker inspect --format '{{.State.Running}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.RestartCount}}' "$id")
    [ "$status" = 'true|healthy|0' ] || die "$service is not healthy with zero restarts"
    count=$((count + 1))
  done
  expected=11; is_lan_only && expected=10
  [ "$count" -eq "$expected" ] || die "unexpected protected container count"
}

verify_boundaries(){
  SSH_CONNECTION=$VALIDATED_SSH_CONNECTION /usr/local/sbin/veinfin-firewall --verify >/dev/null || die "firewall verification failed"
  ! ss -H -lnt 'sport = :80 or sport = :2375 or sport = :2376 or sport = :8191' | grep -q . || die "a prohibited TCP listener is present"
  if is_lan_only; then
    [ -z "$(service_id reverse-proxy)" ] || die "Caddy is present in LAN-only profile"
    ss -H -lnt 'sport = :8096' | awk '{print $4}' | grep -Fqx "$(env_value MANAGEMENT_BIND_IP):$(env_value JELLYFIN_MANAGEMENT_PORT)" || die "Jellyfin private LAN listener is absent"
    ! ss -H -lnt 'sport = :443' | grep -q . || die "public HTTPS listener is present in LAN-only profile"
  else
    [ "$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 20 "https://$(env_value PUBLIC_HOSTNAME)/health")" = 200 ] || die "public HTTPS health failed"
    if ss -H -lnt 'sport = :8096' | awk '{print $4}' | grep -Evq '^(127\.0\.0\.1|\[::1\]):8096$'; then die "Jellyfin has a non-loopback TCP 8096 listener"; fi
    ss -H -lnt 'sport = :443' | grep -q '0.0.0.0:443' || die "public HTTPS listener is absent"
  fi
  ss -H -lnt 'sport = :8096' | awk '{print $4}' | grep -Eq '^(127\.0\.0\.1|\[::1\]):8096$' || die "Jellyfin loopback listener is absent"
}

plugin_args(){
  printf '%s\n' --username "$(env_value MANAGEMENT_USERNAME)" --password-file "$RUNTIME_ROOT/secrets/management-password"
}

snapshot(){
  local output=$1 args=()
  mapfile -t args < <(plugin_args)
  "$HELPER" snapshot --lock "$LOCK" --output "$output" --expected-version 10.11.11 "${args[@]}"
}

verify_plugins(){
  local args=()
  mapfile -t args < <(plugin_args)
  "$HELPER" verify-live --lock "$LOCK" --baseline "$STATE/plugins-baseline.json" --expected-version 10.11.11 "${args[@]}"
}

configure_plugins(){
  local user
  user=$(env_value MANAGEMENT_USERNAME)
  "$LEGACY_HELPER" configure --base-url http://127.0.0.1:8096 --username "$user" \
    --password-file "$RUNTIME_ROOT/secrets/management-password" --output "$STATE/legacy-ui-desired-configuration.json"
  "$LEGACY_HELPER" run-task --base-url http://127.0.0.1:8096 --username "$user" \
    --password-file "$RUNTIME_ROOT/secrets/management-password" --task-key IntroSkipperDetectSegmentsTask \
    --scan-timeout 14400 --output "$STATE/legacy-ui-intro-segments.json"
  "$LEGACY_HELPER" run-task --base-url http://127.0.0.1:8096 --username "$user" \
    --password-file "$RUNTIME_ROOT/secrets/management-password" --task-key TaskExtractMediaSegments \
    --scan-timeout 3600 --output "$STATE/legacy-ui-intro-segments.json"
}

integration_args(){
  printf '%s\n' --username "$(env_value MANAGEMENT_USERNAME)" \
    --password-file "$RUNTIME_ROOT/secrets/management-password" \
    --profile "$ENHANCED_PROFILE" \
    --sonarr-key-file "$RUNTIME_ROOT/secrets/sonarr-api-key" \
    --radarr-key-file "$RUNTIME_ROOT/secrets/radarr-api-key" \
    --bazarr-key-file "$RUNTIME_ROOT/secrets/bazarr-api-key" \
    --seerr-key-file "$RUNTIME_ROOT/secrets/seerr-api-key" \
    --tmdb-key-file "$RUNTIME_ROOT/secrets/tmdb-api-key"
}

profile_fingerprint(){ sha256sum "$ENHANCED_PROFILE" "$HELPER" | sha256sum | awk '{print $1}'; }

safe_secret(){
  local secret=$1
  [ -f "$secret" ] && [ ! -L "$secret" ] && [ "$(file_mode "$secret")" = 600 ] \
    && [ "$(stat -c '%u:%g' "$secret")" = 0:0 ] && [ -s "$secret" ] || die "$(basename "$secret") is missing or unsafe"
}

check_integration_containers(){
  local service id status
  for service in jellyfin sonarr radarr bazarr seerr; do
    id=$(service_id "$service"); [ -n "$id" ] || die "$service is absent"
    status=$(docker inspect --format '{{.State.Running}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.RestartCount}}' "$id")
    case "$status" in true\|healthy\|0|true\|none\|0) ;; *) die "$service is not healthy with zero restarts";; esac
  done
}

verify_internal_service_urls(){
  local jellyfin_id service_port service port
  jellyfin_id=$(service_id jellyfin)
  for service_port in sonarr:8989 radarr:7878 bazarr:6767 seerr:5055; do
    service=${service_port%:*}; port=${service_port#*:}
    docker exec "$jellyfin_id" curl -fsS --max-time 10 "http://$service:$port/" >/dev/null \
      || die "Jellyfin cannot reach the $service Docker service URL"
  done
}

integration_preflight(){
  require_commands
  [ -f "$REPO_ROOT/.env" ] && [ ! -L "$REPO_ROOT/.env" ] && [ "$(file_mode "$REPO_ROOT/.env")" = 600 ] || die ".env is missing or unsafe"
  safe_secret "$RUNTIME_ROOT/secrets/management-password"
  safe_secret "$RUNTIME_ROOT/secrets/sonarr-api-key"
  safe_secret "$RUNTIME_ROOT/secrets/radarr-api-key"
  safe_secret "$RUNTIME_ROOT/secrets/bazarr-api-key"
  safe_secret "$RUNTIME_ROOT/secrets/seerr-api-key"
  [ ! -e "$RUNTIME_ROOT/secrets/tmdb-api-key" ] || safe_secret "$RUNTIME_ROOT/secrets/tmdb-api-key"
  [ -f "$ENHANCED_PROFILE" ] && [ ! -L "$ENHANCED_PROFILE" ] || die "Jellyfin Enhanced profile is missing or unsafe"
  "$HELPER" validate-lock --lock "$LOCK"
  check_integration_containers
  verify_boundaries
  verify_internal_service_urls
}

verify_integrations(){
  local args=()
  mapfile -t args < <(integration_args)
  "$HELPER" verify-integrations --lock "$LOCK" "${args[@]}"
}

do_configure_integrations(){
  enter_privileged --configure-integrations
  integration_preflight
  local expected current=
  expected=$(profile_fingerprint)
  [ ! -f "$PROFILE_MARKER" ] || current=$(tr -d '\r\n' <"$PROFILE_MARKER")
  if [ -f "$INTEGRATIONS_MARKER" ] && [ -f "$SEERR_MARKER" ] && [ "$current" = "$expected" ]; then
    info "Jellyfin Enhanced integrations are already complete; running verification only"
    verify_integrations
  else
    local args=() stamp backup previous_marker=legacy fingerprint_file
    install -d -o root -g root -m 0700 "$INTEGRATIONS_BACKUPS" "$STATE"
    stamp=$(date -u +%Y%m%dT%H%M%SZ); backup=$INTEGRATIONS_BACKUPS/$stamp.json
    fingerprint_file=$INTEGRATIONS_BACKUPS/$stamp.container-fingerprints
    record_fingerprints "$fingerprint_file"
    if [ -f "$PROFILE_MARKER" ]; then previous_marker=$(tr -d '\r\n' <"$PROFILE_MARKER"); fi
    printf '%s\n' "$previous_marker" | vf_atomic_write "$backup.profile-marker" 0600
    mapfile -t args < <(integration_args)
    "$HELPER" configure-integrations --lock "$LOCK" --backup "$backup" "${args[@]}"
    check_fingerprints "$fingerprint_file"
    printf '%s\n' "$backup" | vf_atomic_write "$INTEGRATIONS_BACKUP_POINTER" 0600
    printf 'complete\n' | vf_atomic_write "$INTEGRATIONS_MARKER" 0600; chown root:root "$INTEGRATIONS_MARKER"
    printf 'complete\n' | vf_atomic_write "$SEERR_MARKER" 0600; chown root:root "$SEERR_MARKER"
    printf '%s\n' "$expected" | vf_atomic_write "$PROFILE_MARKER" 0600; chown root:root "$PROFILE_MARKER" "$INTEGRATIONS_BACKUP_POINTER" "$backup" "$backup.profile-marker" "$fingerprint_file"
  fi
  integration_preflight
  verify_integrations
  pass "Jellyfin Enhanced Sonarr, Radarr, Bazarr, mappings, and exposure boundaries verified without restart"
}

do_rollback_integrations(){
  enter_privileged --rollback-integrations
  require_commands
  [ -f "$ENHANCED_PROFILE" ] && [ ! -L "$ENHANCED_PROFILE" ] || die "Jellyfin Enhanced profile is missing or unsafe"
  safe_secret "$RUNTIME_ROOT/secrets/management-password"
  [ -f "$INTEGRATIONS_BACKUP_POINTER" ] && [ ! -L "$INTEGRATIONS_BACKUP_POINTER" ] \
    && [ "$(file_mode "$INTEGRATIONS_BACKUP_POINTER")" = 600 ] || die "Jellyfin Enhanced backup pointer is missing or unsafe"
  local backup previous_marker args=()
  backup=$(tr -d '\r\n' <"$INTEGRATIONS_BACKUP_POINTER")
  [ -f "$backup" ] && [ -f "$backup.profile-marker" ] || die "protected Jellyfin Enhanced backup is unavailable"
  mapfile -t args < <(plugin_args)
  "$HELPER" restore-integrations --lock "$LOCK" --profile "$ENHANCED_PROFILE" --backup "$backup" "${args[@]}"
  previous_marker=$(tr -d '\r\n' <"$backup.profile-marker")
  if [ "$previous_marker" = legacy ]; then
    rm -f -- "$PROFILE_MARKER"
  else
    printf '%s\n' "$previous_marker" | vf_atomic_write "$PROFILE_MARKER" 0600; chown root:root "$PROFILE_MARKER"
  fi
  pass "Jellyfin Enhanced configuration restored through the supported API without restart"
}

do_verify_integrations(){
  enter_privileged --verify-integrations
  [ -f "$INTEGRATIONS_MARKER" ] || die "Jellyfin Enhanced integration completion marker is absent"
  [ -f "$SEERR_MARKER" ] || die "Jellyfin Enhanced Seerr completion marker is absent"
  [ -f "$PROFILE_MARKER" ] && [ "$(tr -d '\r\n' <"$PROFILE_MARKER")" = "$(profile_fingerprint)" ] \
    || die "Jellyfin Enhanced profile marker is absent or stale"
  integration_preflight
  verify_integrations
  pass "Jellyfin Enhanced integrations verified without changes"
}

preflight(){
  require_commands
  [ -f "$REPO_ROOT/.env" ] && [ ! -L "$REPO_ROOT/.env" ] && [ "$(file_mode "$REPO_ROOT/.env")" = 600 ] || die ".env is missing or unsafe"
  [ -f "$RUNTIME_ROOT/secrets/management-password" ] && [ ! -L "$RUNTIME_ROOT/secrets/management-password" ] && [ "$(file_mode "$RUNTIME_ROOT/secrets/management-password")" = 600 ] || die "management password file is missing or unsafe"
  "$HELPER" validate-lock --lock "$LOCK"
  python3 -m py_compile "$LEGACY_HELPER"
  [[ $(env_value JELLYFIN_IMAGE_TAG) == 10.11.11@sha256:aefb67e6a7ff1debdd154a78a7bbb780fd0c873d8639210a7f6a2016ad2b35db ]] || die "Jellyfin 10.11.11 image lock is required"
  wait_jellyfin || die "Jellyfin did not become ready"
  check_containers
  verify_boundaries
  [ -S /var/run/docker.sock ] || die "Docker socket is unavailable to the restricted host workflow"
}

stage_artifacts(){
  rm -rf -- "$STAGING"
  install -d -o root -g root -m 0700 "$STAGING"
  "$HELPER" stage --lock "$LOCK" --output "$STAGING"
  local url digest archive top
  IFS='|' read -r _ _ _ _ _ _ url digest < <(awk -F'|' '!/^#/ && NF{print;exit}' "$ASSET_LOCK")
  ensure_work; archive=$WORK_DIR/kefin.tar.gz
  curl -fL --retry 3 --connect-timeout 20 "$url" -o "$archive"
  [ "$(sha256sum "$archive" | awk '{print $1}')" = "$digest" ] || die "KefinTweaks artifact hash mismatch"
  ! tar -tzf "$archive" | grep -Eq '(^/|(^|/)\.\.(/|$))' || die "KefinTweaks archive contains an unsafe path"
  top=$(tar -tzf "$archive" | sed -n '1{s,/.*,,;p;}'); [ "$top" = KefinTweaks-0.5.3 ] || die "KefinTweaks archive root changed"
  install -d -m 0700 "$STAGING/KefinTweaks"
  tar -xzf "$archive" --strip-components=1 -C "$STAGING/KefinTweaks"
  install -m 0640 "$REPO_ROOT/templates/jellyfin/legacy-cinematic.css" "$STAGING/KefinTweaks/veinfin-cinematic.css"
  find "$STAGING" -type d -exec chmod 0700 {} +
  find "$STAGING" -type f -exec chmod 0600 {} +
  pass "all locked plugin artifacts and extracted files match SHA-256"
}

record_fingerprints(){
  local output=$1 service id
  {
    for service in $(protected_services); do
      id=$(service_id "$service")
      printf '%s|%s|%s\n' "$service" "$id" "$(docker inspect --format '{{.RestartCount}}' "$id")"
    done
  } | vf_atomic_write "$output" 0600
  chown root:root "$output"
}

check_fingerprints(){
  local input=$1 service expected_id expected_restarts current_id current_restarts
  while IFS='|' read -r service expected_id expected_restarts; do
    current_id=$(service_id "$service"); current_restarts=$(docker inspect --format '{{.RestartCount}}' "$current_id")
    [ "$current_id" = "$expected_id" ] && [ "$current_restarts" = "$expected_restarts" ] || die "$service identity or restart count changed"
  done <"$input"
}

wait_jellyfin(){
  local attempt=0 id status
  id=$(service_id jellyfin)
  while [ "$attempt" -lt 90 ]; do
    status=$(docker inspect --format '{{.State.Running}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id" 2>/dev/null || true)
    if [ "$status" = 'true|healthy' ] && curl -fsS --max-time 5 http://127.0.0.1:8096/System/Info/Public >/dev/null; then return 0; fi
    sleep 2; attempt=$((attempt + 1))
  done
  return 1
}

make_backup(){
  local stamp backup config_root jellyfin_id kefin
  stamp=$(date -u +%Y%m%dT%H%M%SZ); backup=$BACKUPS/$stamp; config_root=$(env_value CONFIG_ROOT)
  install -d -o root -g root -m 0700 "$BACKUPS" "$backup" "$STATE"
  snapshot "$STATE/plugins-baseline.json"
  record_fingerprints "$backup/container-fingerprints"
  ss -H -lntup | vf_atomic_write "$backup/listeners-before" 0600
  jellyfin_id=$(service_id jellyfin)
  docker stop --time 30 "$jellyfin_id" >/dev/null
  tar --numeric-owner -C "$config_root/jellyfin" -czf "$backup/jellyfin-config.tar.gz" config
  kefin=$config_root/jellyfin/KefinTweaks
  if [ -d "$kefin" ] && [ -z "$(find "$kefin" -mindepth 1 -print -quit)" ]; then
    printf 'empty\n' | vf_atomic_write "$backup/kefin-empty" 0600
  elif [ -d "$kefin" ] && [ ! -L "$kefin" ]; then
    tar --numeric-owner -C "$config_root/jellyfin" -czf "$backup/kefin-tweaks.tar.gz" KefinTweaks
    chmod 0600 "$backup/kefin-tweaks.tar.gz"; chown root:root "$backup/kefin-tweaks.tar.gz"
  else
    die "KefinTweaks backup source is unsafe"
  fi
  chmod 0600 "$backup/jellyfin-config.tar.gz"; chown root:root "$backup/jellyfin-config.tar.gz"
  printf '%s\n' "$backup" | vf_atomic_write "$BACKUP_POINTER" 0600; chown root:root "$BACKUP_POINTER"
  printf '%s\n' "$backup"
}

install_plugins(){
  local config_root uid gid entry name version destination staged
  config_root=$(env_value CONFIG_ROOT); uid=$(env_value PUID); gid=$(env_value PGID)
  [ -d "$config_root/jellyfin/config/plugins" ] && [ ! -L "$config_root/jellyfin/config/plugins" ] || die "Jellyfin plugin directory is missing or unsafe"
  while IFS='|' read -r entry name _ version _; do
    case "$entry" in \#*|'') continue;; esac
    staged=$STAGING/$entry-$version; destination=$config_root/jellyfin/config/plugins/${name}_$version
    [ ! -e "$destination" ] || die "locked plugin destination already exists unexpectedly: $name"
    install -d -o "$uid" -g "$gid" -m 0750 "$destination"
    find "$staged" -maxdepth 1 -type f -exec install -o "$uid" -g "$gid" -m 0640 {} "$destination/" \;
  done <"$LOCK"
  if [ -e "$config_root/jellyfin/KefinTweaks" ]; then
    [ -d "$config_root/jellyfin/KefinTweaks" ] && [ ! -L "$config_root/jellyfin/KefinTweaks" ] || die "KefinTweaks destination is unsafe"
    [ -z "$(find "$config_root/jellyfin/KefinTweaks" -mindepth 1 -print -quit)" ] || die "KefinTweaks destination already contains files"
    rmdir "$config_root/jellyfin/KefinTweaks"
  fi
  cp -a "$STAGING/KefinTweaks" "$config_root/jellyfin/KefinTweaks"
  find "$config_root/jellyfin/KefinTweaks" -type d -exec chmod 0750 {} +
  find "$config_root/jellyfin/KefinTweaks" -type f -exec chmod 0640 {} +
  chown -R "$uid:$gid" "$config_root/jellyfin/KefinTweaks"
}

restore_backup(){
  local backup=${1:-} config_root jellyfin_id failed kefin
  [ -n "$backup" ] && [ -d "$backup" ] && [ -f "$backup/jellyfin-config.tar.gz" ] || die "protected plugin backup is unavailable"
  config_root=$(env_value CONFIG_ROOT); jellyfin_id=$(service_id jellyfin)
  failed=$backup/failed-config
  if [ -e "$failed" ]; then
    kefin=$config_root/jellyfin/KefinTweaks
    [ -d "$kefin" ] && [ ! -L "$kefin" ] || die "KefinTweaks rollback destination is unsafe"
    find "$kefin" -mindepth 1 -depth -delete
    if [ -f "$backup/kefin-tweaks.tar.gz" ]; then
      rmdir "$kefin"; tar --numeric-owner -C "$config_root/jellyfin" -xzf "$backup/kefin-tweaks.tar.gz"
    fi
    docker start "$jellyfin_id" >/dev/null
    wait_jellyfin || die "Jellyfin did not recover after the already-completed rollback"
    rm -f -- "$STARTED" "$MARKER"
    pass "Jellyfin configuration rollback was already complete"
    return 0
  fi
  docker stop --time 30 "$jellyfin_id" >/dev/null 2>&1 || true
  mv "$config_root/jellyfin/config" "$failed"
  tar --numeric-owner -C "$config_root/jellyfin" -xzf "$backup/jellyfin-config.tar.gz"
  kefin=$config_root/jellyfin/KefinTweaks
  [ -d "$kefin" ] && [ ! -L "$kefin" ] || die "KefinTweaks rollback destination is unsafe"
  find "$kefin" -mindepth 1 -depth -delete
  if [ -f "$backup/kefin-tweaks.tar.gz" ]; then
    rmdir "$kefin"; tar --numeric-owner -C "$config_root/jellyfin" -xzf "$backup/kefin-tweaks.tar.gz"
  fi
  docker start "$jellyfin_id" >/dev/null
  wait_jellyfin || die "Jellyfin did not recover after rollback"
  rm -f -- "$STARTED" "$MARKER"
  pass "Jellyfin configuration restored from the protected backup"
}

do_check(){
  enter_privileged --check
  preflight
  [ ! -e "$STARTED" ] || die "an interrupted plugin apply requires review or rollback"
  pass "supported plugin readiness check completed without changes"
}

do_verify_internal(){
  preflight
  verify_plugins
  local backup
  backup=$(tr -d '\r\n' <"$BACKUP_POINTER")
  check_fingerprints "$backup/container-fingerprints"
  pass "locked plugins, Jellyfin state, containers, HTTPS, firewall, and listeners are preserved"
}

do_apply(){
  enter_privileged --apply
  if [ -f "$MARKER" ]; then info "supported plugins are already complete; running verification only"; do_verify_internal; return; fi
  preflight
  [ ! -e "$STARTED" ] || die "an interrupted plugin apply requires explicit rollback"
  stage_artifacts
  printf 'started\n' | vf_atomic_write "$STARTED" 0600; chown root:root "$STARTED"
  local backup jellyfin_id
  backup=$(make_backup); jellyfin_id=$(service_id jellyfin)
  if ! install_plugins; then restore_backup "$backup"; die "plugin installation failed and was rolled back"; fi
  docker start "$jellyfin_id" >/dev/null
  if ! wait_jellyfin || ! configure_plugins || ! verify_plugins; then restore_backup "$backup"; die "plugin health or configuration verification failed and was rolled back"; fi
  check_fingerprints "$backup/container-fingerprints"
  preflight
  printf 'complete\n' | vf_atomic_write "$MARKER" 0600; chown root:root "$MARKER"; rm -f -- "$STARTED"
  pass "supported plugins installed with one controlled Jellyfin stop/start"
}

do_verify(){ enter_privileged --verify; [ -f "$MARKER" ] || die "plugin completion marker is absent"; do_verify_internal; }
do_rollback(){ enter_privileged --rollback; [ -f "$BACKUP_POINTER" ] || die "plugin backup pointer is absent"; restore_backup "$(tr -d '\r\n' <"$BACKUP_POINTER")"; preflight; }

[ "$#" -eq 1 ] || { usage >&2; exit 2; }
case "$1" in
  --help) usage;;
  --check) do_check;;
  --apply) do_apply;;
  --verify) do_verify;;
  --rollback) do_rollback;;
  --configure-integrations) do_configure_integrations;;
  --verify-integrations) do_verify_integrations;;
  --rollback-integrations) do_rollback_integrations;;
  *) usage >&2; exit 2;;
esac
