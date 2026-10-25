#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
VEINFIN_REPO_DIR=${VEINFIN_REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd -P)}

# shellcheck source=scripts/lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=scripts/lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=scripts/lib/preflight.sh
. "$SCRIPT_DIR/lib/preflight.sh"

vf_usage() {
  cat <<'EOF'
VeinFin configuration foundation

Usage:
  ./install.sh --help
  ./install.sh --check [--root PATH]
  ./install.sh --dry-run [configuration options]
  ./install.sh --generate-config --profile PROFILE [configuration options]
  sudo --preserve-env=SSH_CONNECTION ./install.sh --install [configuration options]
  sudo --preserve-env=SSH_CONNECTION ./install.sh --verify [--root PATH]

Modes:
  --help             Show this help without changing files.
  --check            Run non-mutating host and configuration preflight checks.
  --dry-run          Validate prospective configuration and report planned writes.
  --generate-config  Create runtime directories, secrets, rendered files, and .env.
  --install          Run or resume the validated deployment stage sequence.
  --verify           Read-only final verification of a completed installation.

Configuration options:
  --root PATH        Output root; defaults to VEINFIN_ROOT or the repository root.
  --input FILE       Read non-secret KEY=VALUE settings without sourcing the file.
  --set KEY=VALUE    Override one non-secret setting; may be repeated.
  --profile PROFILE  Select public-https or lan-only when generating configuration.
  --force            Replace an existing .env after validation; secrets are preserved.
  --rotate-secrets   Explicitly rotate the generated management password and rewrite .env.

Only --install deploys or changes host policy. It never formats, partitions,
initializes, repairs, or mounts storage. The management password is generated
locally and never printed. Input files and --set reject secret-bearing keys.
EOF
}

vf_prompt_configuration() {
  [ -t 0 ] || return 0
  if [ "$INSTALLATION_PROFILE" = public-https ] && [[ "$PUBLIC_HOSTNAME" == *.example.test ]]; then
    read -r -p "Public Jellyfin hostname: " PUBLIC_HOSTNAME
  fi
  read -r -p "Server management bind address [$MANAGEMENT_BIND_IP]: " vf_answer
  MANAGEMENT_BIND_IP=${vf_answer:-$MANAGEMENT_BIND_IP}
  read -r -p "Management URL host [$MANAGEMENT_URL_HOST]: " vf_answer
  MANAGEMENT_URL_HOST=${vf_answer:-$MANAGEMENT_URL_HOST}
  read -r -p "Reserved management source CIDRs, comma-separated [$MANAGEMENT_ALLOWED_CIDRS]: " vf_answer
  MANAGEMENT_ALLOWED_CIDRS=${vf_answer:-$MANAGEMENT_ALLOWED_CIDRS}
  read -r -p "Timezone [$TZ]: " vf_answer
  TZ=${vf_answer:-$TZ}
  read -r -p "Application config root [$CONFIG_ROOT]: " vf_answer
  CONFIG_ROOT=${vf_answer:-$CONFIG_ROOT}
  read -r -p "Media root [$MEDIA_ROOT]: " vf_answer
  MEDIA_ROOT=${vf_answer:-$MEDIA_ROOT}
}

vf_install_marker() { printf '%s/runtime/state/install/%02d-%s.complete\n' "$VF_ROOT" "$1" "$2"; }

vf_stage_hash() {
  vf_hash_stage=$1
  {
    case "$vf_hash_stage" in
      configuration) printf '%s\n' "$INSTALLATION_PROFILE" "$ENABLE_MIGRATION_STAGES" "$COMPOSE_PROJECT_NAME" "$TZ" "$PUID" "$PGID" "$UMASK" "$CONFIG_ROOT" "$MEDIA_ROOT" ;;
      host) sha256sum "$VEINFIN_REPO_DIR/scripts/host/prepare-debian.sh" ;;
      storage) printf '%s\n' "$MEDIA_ROOT" "$PUID" "$PGID" ;;
      firewall) printf '%s\n' "$MANAGEMENT_ALLOWED_CIDRS" "$PROTECTED_LAN_CIDRS" "$SSH_PORT" "$CONTROL_PANEL_MANAGEMENT_PORT" "$QBITTORRENT_MANAGEMENT_PORT" "$SONARR_MANAGEMENT_PORT" "$RADARR_MANAGEMENT_PORT" "$PROWLARR_MANAGEMENT_PORT" "$BAZARR_MANAGEMENT_PORT" "$SEERR_MANAGEMENT_PORT"; sha256sum "$VEINFIN_REPO_DIR/scripts/host/configure-firewall.sh" ;;
      core|jellyfin) printf '%s\n' "$JELLYFIN_IMAGE_TAG" "$CONFIG_ROOT" "$MEDIA_ROOT" "$PUID" "$PGID"; sha256sum "$VEINFIN_REPO_DIR/compose.yaml" "$VEINFIN_REPO_DIR/scripts/deploy/jellyfin.sh" ;;
      qbittorrent) printf '%s\n' "$QBITTORRENT_IMAGE_TAG" "$MEDIA_ROOT" "$QBITTORRENT_MANAGEMENT_PORT"; sha256sum "$VEINFIN_REPO_DIR/scripts/deploy/qbittorrent.sh" ;;
      arr) printf '%s\n' "$SONARR_IMAGE_TAG" "$RADARR_IMAGE_TAG" "$PROWLARR_IMAGE_TAG" "$MEDIA_ROOT"; sha256sum "$VEINFIN_REPO_DIR/scripts/deploy/arr.sh" ;;
      media_services) printf '%s\n' "$BAZARR_IMAGE_TAG" "$SEERR_IMAGE_TAG" "$FLARESOLVERR_IMAGE_TAG" "$RECYCLARR_IMAGE_TAG"; sha256sum "$VEINFIN_REPO_DIR/scripts/deploy/media-services.sh" ;;
      https) printf '%s\n' "$PUBLIC_HOSTNAME" "$PUBLIC_BIND_IP" "$HTTPS_PORT" "$CADDY_IMAGE_TAG"; sha256sum "$VEINFIN_REPO_DIR/scripts/deploy/https.sh" ;;
      lan_access) printf '%s\n' "$MANAGEMENT_BIND_IP" "$JELLYFIN_MANAGEMENT_PORT"; sha256sum "$VEINFIN_REPO_DIR/compose/lan-only.yaml" "$VEINFIN_REPO_DIR/scripts/deploy/lan-profile.sh" ;;
      libraries) sha256sum "$VEINFIN_REPO_DIR/scripts/deploy/libraries.sh" "$RUNTIME_ROOT/state/libraries-media-manifest.conf" 2>/dev/null || true ;;
      indexers) sha256sum "$VEINFIN_REPO_DIR/scripts/deploy/indexers-subtitles.sh" ;;
      quality) sha256sum "$VEINFIN_REPO_DIR/scripts/deploy/quality-profiles.sh" "$VEINFIN_REPO_DIR/config/quality-policy.json" ;;
      lifecycle) sha256sum "$VEINFIN_REPO_DIR/scripts/deploy/download-lifecycle.sh" "$VEINFIN_REPO_DIR/config/download-lifecycle-policy.json" ;;
      panel) printf '%s\n' "$MANAGEMENT_BIND_IP" "$MANAGEMENT_URL_HOST" "$CONTROL_PANEL_MANAGEMENT_PORT"; sha256sum "$VEINFIN_REPO_DIR/panel/Dockerfile" "$VEINFIN_REPO_DIR/panel/app.py" "$VEINFIN_REPO_DIR/compose/control-panel.yml" ;;
      plugins) sha256sum "$VEINFIN_REPO_DIR/config/plugins.lock" "$VEINFIN_REPO_DIR/config/legacy-ui-assets.lock" "$VEINFIN_REPO_DIR/config/jellyfin-enhanced-profile.json" "$VEINFIN_REPO_DIR/scripts/deploy/plugins.sh" "$VEINFIN_REPO_DIR/scripts/deploy/plugins.py" "$VEINFIN_REPO_DIR/scripts/deploy/legacy_ui.py" "$VEINFIN_REPO_DIR/templates/jellyfin/legacy-cinematic.css" ;;
      final) sha256sum "$VEINFIN_REPO_DIR/scripts/deploy/control-panel.sh" "$VEINFIN_REPO_DIR/scripts/deploy/plugins.sh" "$VEINFIN_REPO_DIR/scripts/installer.sh" ;;
    esac
  } | sha256sum | awk '{print $1}'
}

vf_marker_current() {
  vf_current_marker=$1 vf_current_stage=$2
  [ -f "$vf_current_marker" ] && grep -Fxq "hash=$(vf_stage_hash "$vf_current_stage")" "$vf_current_marker"
}

vf_mark_install_stage() {
  vf_stage_dir=$VF_ROOT/runtime/state/install
  mkdir -p "$vf_stage_dir"; chmod 0700 "$vf_stage_dir"
  printf 'hash=%s\n' "$(vf_stage_hash "$2")" | vf_atomic_write "$(vf_install_marker "$1" "$2")" 0600
}

vf_stage_verify() {
  vf_stage=$1
  case "$vf_stage" in
    configuration) vf_validate_config ;;
    host) command -v docker >/dev/null && docker info >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 ;;
    storage) vf_verify_media_layout ;;
    firewall) SSH_CONNECTION=${SSH_CONNECTION:-} /usr/local/sbin/veinfin-firewall --verify >/dev/null 2>&1 ;;
    core|jellyfin) "$VEINFIN_REPO_DIR/scripts/deploy/jellyfin.sh" --verify >/dev/null 2>&1 ;;
    qbittorrent) "$VEINFIN_REPO_DIR/scripts/deploy/qbittorrent.sh" --verify >/dev/null 2>&1 ;;
    arr) "$VEINFIN_REPO_DIR/scripts/deploy/arr.sh" --verify >/dev/null 2>&1 ;;
    media_services) "$VEINFIN_REPO_DIR/scripts/deploy/media-services.sh" --verify >/dev/null 2>&1 ;;
    https) "$VEINFIN_REPO_DIR/scripts/deploy/https.sh" --verify --hostname "$PUBLIC_HOSTNAME" >/dev/null 2>&1 ;;
    lan_access) "$VEINFIN_REPO_DIR/scripts/deploy/lan-profile.sh" --verify >/dev/null 2>&1 ;;
    libraries) "$VEINFIN_REPO_DIR/scripts/deploy/libraries.sh" --verify >/dev/null 2>&1 ;;
    indexers) "$VEINFIN_REPO_DIR/scripts/deploy/indexers-subtitles.sh" --verify >/dev/null 2>&1 ;;
    quality) "$VEINFIN_REPO_DIR/scripts/deploy/quality-profiles.sh" --verify >/dev/null 2>&1 ;;
    lifecycle) "$VEINFIN_REPO_DIR/scripts/deploy/download-lifecycle.sh" --verify >/dev/null 2>&1 ;;
    panel) "$VEINFIN_REPO_DIR/scripts/deploy/control-panel.sh" --verify >/dev/null 2>&1 ;;
    plugins) "$VEINFIN_REPO_DIR/scripts/deploy/plugins.sh" --verify >/dev/null 2>&1 && "$VEINFIN_REPO_DIR/scripts/deploy/plugins.sh" --verify-integrations >/dev/null 2>&1 ;;
    final) "$VEINFIN_REPO_DIR/scripts/deploy/control-panel.sh" --verify >/dev/null 2>&1 && "$VEINFIN_REPO_DIR/scripts/deploy/plugins.sh" --verify >/dev/null 2>&1 && "$VEINFIN_REPO_DIR/scripts/deploy/plugins.sh" --verify-integrations >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

vf_render_initial_firewall() {
  vf_firewall=$RUNTIME_ROOT/generated/firewall.conf
  mkdir -p "$RUNTIME_ROOT/generated"; chmod 0700 "$RUNTIME_ROOT/generated"
  {
    printf 'MANAGEMENT_ALLOWED_CIDRS=%s\n' "$MANAGEMENT_ALLOWED_CIDRS"
    printf 'MANAGEMENT_ALLOWED_IPV6_CIDRS=\n'
    printf 'PROTECTED_LAN_CIDRS=%s\n' "$PROTECTED_LAN_CIDRS"
    printf 'SSH_PORT=%s\n' "$SSH_PORT"
    printf 'ENABLE_PUBLIC_HTTPS=false\nENABLE_MANAGEMENT_PORTS=false\n'
    printf 'MANAGEMENT_TCP_PORTS=%s,%s,%s,%s,%s,%s,%s,%s\n' "$CONTROL_PANEL_MANAGEMENT_PORT" "$JELLYFIN_MANAGEMENT_PORT" "$SEERR_MANAGEMENT_PORT" "$BAZARR_MANAGEMENT_PORT" "$RADARR_MANAGEMENT_PORT" "$QBITTORRENT_MANAGEMENT_PORT" "$SONARR_MANAGEMENT_PORT" "$PROWLARR_MANAGEMENT_PORT"
  } | vf_atomic_write "$vf_firewall" 0600
}

vf_verify_media_layout() {
  findmnt -T "$MEDIA_ROOT" >/dev/null 2>&1 && [ -w "$MEDIA_ROOT" ] || return 1
  for vf_media_path in torrents/incomplete torrents/movies torrents/tv torrents/anime library/movies library/tv library/anime; do
    [ -d "$MEDIA_ROOT/$vf_media_path" ] && [ ! -L "$MEDIA_ROOT/$vf_media_path" ] || return 1
  done
}

vf_prepare_media_layout() {
  findmnt -T "$MEDIA_ROOT" >/dev/null 2>&1 && [ -w "$MEDIA_ROOT" ] || vf_die "media root must already be mounted and writable"
  for vf_media_path in torrents torrents/incomplete torrents/movies torrents/tv torrents/anime library library/movies library/tv library/anime; do
    [ ! -L "$MEDIA_ROOT/$vf_media_path" ] || vf_die "refusing symlinked media path: $vf_media_path"
    install -d -o "$PUID" -g "$PGID" -m 0775 "$MEDIA_ROOT/$vf_media_path"
  done
  vf_verify_media_layout || vf_die "clean media directory layout verification failed"
}

vf_stage_apply() {
  vf_stage=$1
  case "$vf_stage" in
    configuration) vf_validate_config ;;
    host) "$VEINFIN_REPO_DIR/scripts/host/prepare-debian.sh" --apply ;;
    storage) vf_prepare_media_layout ;;
    firewall) vf_render_initial_firewall; "$VEINFIN_REPO_DIR/scripts/host/configure-firewall.sh" --apply --config "$RUNTIME_ROOT/generated/firewall.conf" ;;
    core) "$VEINFIN_REPO_DIR/scripts/deploy/jellyfin.sh" --apply ;;
    jellyfin) "$VEINFIN_REPO_DIR/scripts/deploy/jellyfin.sh" --verify ;;
    qbittorrent) "$VEINFIN_REPO_DIR/scripts/deploy/qbittorrent.sh" --apply ;;
    arr) "$VEINFIN_REPO_DIR/scripts/deploy/arr.sh" --apply ;;
    media_services) "$VEINFIN_REPO_DIR/scripts/deploy/media-services.sh" --apply ;;
    https) "$VEINFIN_REPO_DIR/scripts/deploy/https.sh" --apply --hostname "$PUBLIC_HOSTNAME"; "$VEINFIN_REPO_DIR/scripts/deploy/https.sh" --verify --hostname "$PUBLIC_HOSTNAME" ;;
    lan_access) "$VEINFIN_REPO_DIR/scripts/deploy/lan-profile.sh" --apply ;;
    libraries) "$VEINFIN_REPO_DIR/scripts/deploy/libraries.sh" --apply ;;
    indexers) "$VEINFIN_REPO_DIR/scripts/deploy/indexers-subtitles.sh" --apply ;;
    quality) "$VEINFIN_REPO_DIR/scripts/deploy/quality-profiles.sh" --preview; "$VEINFIN_REPO_DIR/scripts/deploy/quality-profiles.sh" --apply ;;
    lifecycle) "$VEINFIN_REPO_DIR/scripts/deploy/download-lifecycle.sh" --preview; "$VEINFIN_REPO_DIR/scripts/deploy/download-lifecycle.sh" --apply ;;
    panel) "$VEINFIN_REPO_DIR/scripts/deploy/control-panel.sh" --apply; "$VEINFIN_REPO_DIR/scripts/deploy/control-panel.sh" --verify ;;
    plugins) "$VEINFIN_REPO_DIR/scripts/deploy/plugins.sh" --apply; "$VEINFIN_REPO_DIR/scripts/deploy/plugins.sh" --verify; "$VEINFIN_REPO_DIR/scripts/deploy/plugins.sh" --configure-integrations; "$VEINFIN_REPO_DIR/scripts/deploy/plugins.sh" --verify-integrations ;;
    final) "$VEINFIN_REPO_DIR/scripts/deploy/control-panel.sh" --verify; "$VEINFIN_REPO_DIR/scripts/deploy/plugins.sh" --verify; "$VEINFIN_REPO_DIR/scripts/deploy/plugins.sh" --verify-integrations ;;
    *) vf_die "unknown installation stage" ;;
  esac
}

vf_all_install_markers_current() {
  vf_check_number=1
  for vf_check_name in $(vf_core_stages); do
    vf_marker_current "$(vf_install_marker "$vf_check_number" "$vf_check_name")" "$vf_check_name" || return 1
    vf_check_number=$((vf_check_number + 1))
  done
}

vf_core_stages() {
  if [ "$INSTALLATION_PROFILE" = public-https ]; then
    printf '%s\n' 'configuration host storage firewall core jellyfin qbittorrent arr media_services https panel plugins final'
  else
    printf '%s\n' 'configuration host storage firewall core jellyfin qbittorrent arr media_services lan_access panel plugins final'
  fi
}

vf_write_optional_stage_status() {
  vf_optional_status=$RUNTIME_ROOT/state/optional-stages.status
  {
    if [ "$INSTALLATION_PROFILE" = lan-only ]; then printf 'public-https=SKIPPED_PROFILE_LAN_ONLY\n'; else printf 'public-https=APPLIED\n'; fi
    if [ "$ENABLE_MIGRATION_STAGES" = true ]; then
      printf 'existing-media-inventory=REQUESTED_SEPARATE_OPERATOR_STAGE\nsonarr-adoption=REQUESTED_SEPARATE_OPERATOR_STAGE\nlegacy-jellyfin-migration=REQUESTED_SEPARATE_OPERATOR_STAGE\n'
    else
      printf 'existing-media-inventory=SKIPPED_NOT_REQUESTED\nsonarr-adoption=SKIPPED_NOT_REQUESTED\nlegacy-jellyfin-migration=SKIPPED_NOT_REQUESTED\n'
    fi
  } | vf_atomic_write "$vf_optional_status" 0600
}

vf_stage_rollback() {
  case "$1" in
    core|jellyfin) docker compose --project-directory "$VEINFIN_REPO_DIR" --env-file "$VEINFIN_ENV_FILE" -f "$VEINFIN_REPO_DIR/compose.yaml" -f "$VEINFIN_REPO_DIR/compose/jellyfin-loopback.yaml" stop jellyfin >/dev/null 2>&1 || true ;;
    lan_access) "$VEINFIN_REPO_DIR/scripts/deploy/lan-profile.sh" --rollback >/dev/null 2>&1 || true ;;
    plugins) "$VEINFIN_REPO_DIR/scripts/deploy/plugins.sh" --rollback >/dev/null 2>&1 || true ;;
    *) vf_warn "Stage $1 uses its own guarded rollback or stops only newly introduced services" ;;
  esac
}

vf_run_install() {
  [ "$(id -u)" -eq 0 ] || vf_die "--install must run as root"
  [ -n "${SSH_CONNECTION:-}" ] || vf_die "--install requires the active SSH connection context"
  [ -f "$VEINFIN_ENV_FILE" ] && [ "$(stat -c '%a' "$VEINFIN_ENV_FILE")" = 600 ] || vf_die "a mode-0600 generated .env is required"
  vf_validate_config
  vf_prepare_runtime
  vf_write_optional_stage_status
  export VEINFIN_DEPLOY_ROOT="$VF_ROOT" VEINFIN_CONFIG_ROOT="$CONFIG_ROOT" VEINFIN_MEDIA_ROOT="$MEDIA_ROOT"
  export VEINFIN_PROJECT_NAME="$COMPOSE_PROJECT_NAME" VEINFIN_ENV_FILE="$VEINFIN_ENV_FILE"
  if [ -f "$RUNTIME_ROOT/state/control_panel-complete" ] && vf_all_install_markers_current; then
    "$VEINFIN_REPO_DIR/scripts/deploy/control-panel.sh" --verify
    if [ "$INSTALLATION_PROFILE" = lan-only ]; then "$VEINFIN_REPO_DIR/scripts/deploy/lan-profile.sh" --verify; else "$VEINFIN_REPO_DIR/scripts/deploy/https.sh" --verify --hostname "$PUBLIC_HOSTNAME"; fi
    "$VEINFIN_REPO_DIR/scripts/deploy/plugins.sh" --verify
    "$VEINFIN_REPO_DIR/scripts/deploy/plugins.sh" --verify-integrations
    vf_info "Installation is complete and unchanged; every stage was verification-only"
    return 0
  fi
  vf_frontier=0 vf_scan_number=1
  for vf_scan_name in $(vf_core_stages); do
    [ -f "$(vf_install_marker "$vf_scan_number" "$vf_scan_name")" ] || break
    vf_frontier=$vf_scan_number
    vf_scan_number=$((vf_scan_number + 1))
  done
  vf_number=1
  for vf_name in $(vf_core_stages); do
    vf_marker=$(vf_install_marker "$vf_number" "$vf_name")
    if vf_marker_current "$vf_marker" "$vf_name"; then
      if [ ! -f "$RUNTIME_ROOT/state/control_panel-complete" ] && [ "$vf_number" -eq "$vf_frontier" ]; then
        vf_stage_verify "$vf_name" || vf_die "completed installation stage failed verification: $vf_name"
      fi
      vf_info "Stage $vf_number $vf_name: verified"
    elif [ -f "$vf_marker" ]; then
      vf_info "Stage $vf_number $vf_name: validated configuration changed; applying only this stage"
      if ! vf_stage_apply "$vf_name"; then vf_stage_rollback "$vf_name"; vf_die "installation failed at changed stage $vf_number: $vf_name"; fi
      vf_stage_verify "$vf_name" || vf_die "changed stage failed post-apply verification: $vf_name"
      vf_mark_install_stage "$vf_number" "$vf_name"
    elif vf_stage_verify "$vf_name"; then
      vf_mark_install_stage "$vf_number" "$vf_name"
      vf_info "Stage $vf_number $vf_name: adopted after verification"
    else
      vf_info "Stage $vf_number $vf_name: applying"
      if ! vf_stage_apply "$vf_name"; then vf_stage_rollback "$vf_name"; vf_die "installation failed at stage $vf_number: $vf_name"; fi
      vf_stage_verify "$vf_name" || vf_die "installation stage failed post-apply verification: $vf_name"
      vf_mark_install_stage "$vf_number" "$vf_name"
    fi
    vf_number=$((vf_number + 1))
  done
  vf_info "Core installation complete for profile $INSTALLATION_PROFILE; optional-stage status is recorded accurately"
  vf_info "Supported pinned plugins are verified; experimental plugins and the optional Download lifecycle setup synthetic test remain deferred"
}

vf_verify_install() {
  [ "$(id -u)" -eq 0 ] || vf_die "--verify must run as root"
  [ -n "${SSH_CONNECTION:-}" ] || vf_die "--verify requires the active SSH connection context"
  [ -f "$RUNTIME_ROOT/state/control_panel-complete" ] || vf_die "installation completion marker is absent"
  "$VEINFIN_REPO_DIR/scripts/deploy/control-panel.sh" --verify
  if [ "$INSTALLATION_PROFILE" = lan-only ]; then "$VEINFIN_REPO_DIR/scripts/deploy/lan-profile.sh" --verify; else "$VEINFIN_REPO_DIR/scripts/deploy/https.sh" --verify --hostname "$PUBLIC_HOSTNAME"; fi
  "$VEINFIN_REPO_DIR/scripts/deploy/plugins.sh" --verify
  "$VEINFIN_REPO_DIR/scripts/deploy/plugins.sh" --verify-integrations
  vf_info "Final installation verification passed"
}

VF_MODE=
VF_INPUT_FILE=
VF_FORCE=false
VF_ROTATE_SECRETS=false
VF_PROFILE_SET=false
VF_PROFILE_VALUE=
VF_SET_VALUES=()
VF_SET_COUNT=0
VF_ROOT=${VEINFIN_ROOT:-$VEINFIN_REPO_DIR}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|--check|--dry-run|--generate-config|--install|--verify)
      [ -z "$VF_MODE" ] || vf_die "choose exactly one mode"
      VF_MODE=$1
      shift
      ;;
    --root)
      [ "$#" -ge 2 ] || vf_die "--root requires a path"
      VF_ROOT=$2
      shift 2
      ;;
    --input)
      [ "$#" -ge 2 ] || vf_die "--input requires a file"
      VF_INPUT_FILE=$2
      shift 2
      ;;
    --set)
      [ "$#" -ge 2 ] || vf_die "--set requires KEY=VALUE"
      VF_SET_VALUES[$VF_SET_COUNT]=$2
      VF_SET_COUNT=$((VF_SET_COUNT + 1))
      shift 2
      ;;
    --profile)
      [ "$#" -ge 2 ] || vf_die "--profile requires public-https or lan-only"
      VF_PROFILE_VALUE=$2
      VF_PROFILE_SET=true
      shift 2
      ;;
    --force)
      VF_FORCE=true
      shift
      ;;
    --rotate-secrets)
      VF_ROTATE_SECRETS=true
      VF_FORCE=true
      shift
      ;;
    *) vf_die "unknown argument: $1" ;;
  esac
done

[ -n "$VF_MODE" ] || { vf_usage; exit 2; }
if [ "$VF_MODE" = --help ]; then
  vf_usage
  exit 0
fi
if [ "$VF_ROTATE_SECRETS" = true ] && [ "$VF_MODE" != --generate-config ]; then
  vf_die "--rotate-secrets is valid only with --generate-config"
fi
if [ "$VF_FORCE" = true ] && [ "$VF_MODE" != --generate-config ]; then
  vf_die "--force is valid only with --generate-config"
fi

vf_valid_path "$VF_ROOT" || vf_die "output root must be a safe absolute path other than /"
RUNTIME_ROOT="$VF_ROOT/runtime"
VEINFIN_ENV_FILE="$VF_ROOT/.env"

vf_load_defaults
RUNTIME_ROOT="$VF_ROOT/runtime"

vf_selected_profile=$VF_PROFILE_VALUE

if { [ "$VF_MODE" = --check ] || [ "$VF_MODE" = --install ] || [ "$VF_MODE" = --verify ]; } && [ -f "$VEINFIN_ENV_FILE" ]; then
  vf_read_env_file "$VEINFIN_ENV_FILE" true
  RUNTIME_ROOT="$VF_ROOT/runtime"
fi
if [ -n "$VF_INPUT_FILE" ]; then
  vf_safe_scalar "$VF_INPUT_FILE" || vf_die "--input path contains a control character"
  vf_read_env_file "$VF_INPUT_FILE" false
fi
if [ -n "$vf_selected_profile" ]; then INSTALLATION_PROFILE=$vf_selected_profile; fi
vf_set_index=0
while [ "$vf_set_index" -lt "$VF_SET_COUNT" ]; do
  vf_override=${VF_SET_VALUES[$vf_set_index]}
  case "$vf_override" in
    *=*) vf_assign_setting "${vf_override%%=*}" "${vf_override#*=}" false ;;
    *) vf_die "--set requires KEY=VALUE" ;;
  esac
  vf_set_index=$((vf_set_index + 1))
done
RUNTIME_ROOT="$VF_ROOT/runtime"

case "$VF_MODE" in
  --dry-run)
    [ "$VF_PROFILE_SET" = true ] || vf_die "--dry-run requires explicit --profile public-https or --profile lan-only"
    vf_prompt_configuration
    vf_validate_config
    vf_info "Dry run passed: configuration is valid"
    vf_info "Would write .env and generated runtime files beneath the selected output root"
    vf_info "Would preserve the existing management password unless --rotate-secrets is supplied"
    vf_info "No files were created or changed"
    ;;
  --generate-config)
    [ "$VF_PROFILE_SET" = true ] || vf_die "--generate-config requires explicit --profile public-https or --profile lan-only"
    if [ -f "$VEINFIN_ENV_FILE" ] && [ "$VF_FORCE" != true ]; then
      vf_info "Existing .env preserved; use --force to regenerate configuration"
      exit 0
    fi
    vf_prompt_configuration
    vf_validate_config
    vf_prepare_runtime
    vf_generate_or_load_secrets
    vf_write_env
    vf_render_templates
    vf_write_credentials_summary
    vf_info "Configuration generated successfully"
    vf_info "The management password was written with restrictive permissions and was not printed"
    ;;
  --check)
    vf_run_preflight
    ;;
  --install)
    vf_run_install
    ;;
  --verify)
    vf_verify_install
    ;;
esac
