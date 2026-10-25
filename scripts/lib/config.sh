#!/usr/bin/env bash

vf_safe_scalar() {
  vf_scalar=$1
  [[ ! "$vf_scalar" =~ [[:cntrl:]] ]]
}

vf_assign_setting() {
  vf_key=$1
  vf_value=$2
  vf_allow_secrets=${3:-false}

  vf_safe_scalar "$vf_value" || vf_die "$vf_key contains a control character"

  case "$vf_key" in
    INSTALLATION_PROFILE) INSTALLATION_PROFILE=$vf_value ;;
    ENABLE_MIGRATION_STAGES) ENABLE_MIGRATION_STAGES=$vf_value ;;
    COMPOSE_PROJECT_NAME) COMPOSE_PROJECT_NAME=$vf_value ;;
    TZ) TZ=$vf_value ;;
    PUID) PUID=$vf_value ;;
    PGID) PGID=$vf_value ;;
    UMASK) UMASK=$vf_value ;;
    CONFIG_ROOT) CONFIG_ROOT=$vf_value ;;
    MEDIA_ROOT) MEDIA_ROOT=$vf_value ;;
    RUNTIME_ROOT) RUNTIME_ROOT=$vf_value ;;
    PUBLIC_HOSTNAME) PUBLIC_HOSTNAME=$vf_value ;;
    PUBLIC_BIND_IP) PUBLIC_BIND_IP=$vf_value ;;
    HTTPS_PORT) HTTPS_PORT=$vf_value ;;
    MANAGEMENT_BIND_IP) MANAGEMENT_BIND_IP=$vf_value ;;
    MANAGEMENT_URL_SCHEME) MANAGEMENT_URL_SCHEME=$vf_value ;;
    MANAGEMENT_URL_HOST) MANAGEMENT_URL_HOST=$vf_value ;;
    MANAGEMENT_ALLOWED_CIDRS) MANAGEMENT_ALLOWED_CIDRS=$vf_value ;;
    PROTECTED_LAN_CIDRS) PROTECTED_LAN_CIDRS=$vf_value ;;
    SSH_PORT) SSH_PORT=$vf_value ;;
    MANAGEMENT_USERNAME) MANAGEMENT_USERNAME=$vf_value ;;
    QBITTORRENT_MANAGEMENT_PORT) QBITTORRENT_MANAGEMENT_PORT=$vf_value ;;
    SONARR_MANAGEMENT_PORT) SONARR_MANAGEMENT_PORT=$vf_value ;;
    RADARR_MANAGEMENT_PORT) RADARR_MANAGEMENT_PORT=$vf_value ;;
    PROWLARR_MANAGEMENT_PORT) PROWLARR_MANAGEMENT_PORT=$vf_value ;;
    BAZARR_MANAGEMENT_PORT) BAZARR_MANAGEMENT_PORT=$vf_value ;;
    SEERR_MANAGEMENT_PORT) SEERR_MANAGEMENT_PORT=$vf_value ;;
    CONTROL_PANEL_MANAGEMENT_PORT) CONTROL_PANEL_MANAGEMENT_PORT=$vf_value ;;
    JELLYFIN_MANAGEMENT_PORT) JELLYFIN_MANAGEMENT_PORT=$vf_value ;;
    ENABLE_JELLYFIN_DISCOVERY) ENABLE_JELLYFIN_DISCOVERY=$vf_value ;;
    JELLYFIN_DISCOVERY_BIND_IP) JELLYFIN_DISCOVERY_BIND_IP=$vf_value ;;
    JELLYFIN_DISCOVERY_PORT) JELLYFIN_DISCOVERY_PORT=$vf_value ;;
    CADDY_IMAGE_TAG) CADDY_IMAGE_TAG=$vf_value ;;
    JELLYFIN_IMAGE_TAG) JELLYFIN_IMAGE_TAG=$vf_value ;;
    LEGACY_CANDIDATE_ROOT) LEGACY_CANDIDATE_ROOT=$vf_value ;;
    LEGACY_CANDIDATE_PORT) LEGACY_CANDIDATE_PORT=$vf_value ;;
    QBITTORRENT_IMAGE_TAG) QBITTORRENT_IMAGE_TAG=$vf_value ;;
    SONARR_IMAGE_TAG) SONARR_IMAGE_TAG=$vf_value ;;
    RADARR_IMAGE_TAG) RADARR_IMAGE_TAG=$vf_value ;;
    PROWLARR_IMAGE_TAG) PROWLARR_IMAGE_TAG=$vf_value ;;
    BAZARR_IMAGE_TAG) BAZARR_IMAGE_TAG=$vf_value ;;
    SEERR_IMAGE_TAG) SEERR_IMAGE_TAG=$vf_value ;;
    RECYCLARR_IMAGE_TAG) RECYCLARR_IMAGE_TAG=$vf_value ;;
    FLARESOLVERR_IMAGE_TAG) FLARESOLVERR_IMAGE_TAG=$vf_value ;;
    ENABLE_VPN_PROFILE) ENABLE_VPN_PROFILE=$vf_value ;;
    VPN_PROVIDER) VPN_PROVIDER=$vf_value ;;
    ENABLE_HARDWARE_TRANSCODING) ENABLE_HARDWARE_TRANSCODING=$vf_value ;;
    TRANSCODING_DEVICE) TRANSCODING_DEVICE=$vf_value ;;
    MANAGEMENT_PASSWORD)
      [ "$vf_allow_secrets" = true ] || vf_die "$vf_key is generated locally and cannot be supplied through an input file or --set"
      MANAGEMENT_PASSWORD=$vf_value
      ;;
    '') ;;
    *) vf_die "unknown configuration key: $vf_key" ;;
  esac
}

vf_value_by_name() {
  case "$1" in
    ENABLE_MIGRATION_STAGES) printf '%s\n' "$ENABLE_MIGRATION_STAGES" ;;
    HTTPS_PORT) printf '%s\n' "$HTTPS_PORT" ;;
    QBITTORRENT_MANAGEMENT_PORT) printf '%s\n' "$QBITTORRENT_MANAGEMENT_PORT" ;;
    SONARR_MANAGEMENT_PORT) printf '%s\n' "$SONARR_MANAGEMENT_PORT" ;;
    RADARR_MANAGEMENT_PORT) printf '%s\n' "$RADARR_MANAGEMENT_PORT" ;;
    PROWLARR_MANAGEMENT_PORT) printf '%s\n' "$PROWLARR_MANAGEMENT_PORT" ;;
    BAZARR_MANAGEMENT_PORT) printf '%s\n' "$BAZARR_MANAGEMENT_PORT" ;;
    SEERR_MANAGEMENT_PORT) printf '%s\n' "$SEERR_MANAGEMENT_PORT" ;;
    CONTROL_PANEL_MANAGEMENT_PORT) printf '%s\n' "$CONTROL_PANEL_MANAGEMENT_PORT" ;;
    JELLYFIN_DISCOVERY_PORT) printf '%s\n' "$JELLYFIN_DISCOVERY_PORT" ;;
    JELLYFIN_MANAGEMENT_PORT) printf '%s\n' "$JELLYFIN_MANAGEMENT_PORT" ;;
    LEGACY_CANDIDATE_PORT) printf '%s\n' "$LEGACY_CANDIDATE_PORT" ;;
    ENABLE_JELLYFIN_DISCOVERY) printf '%s\n' "$ENABLE_JELLYFIN_DISCOVERY" ;;
    ENABLE_VPN_PROFILE) printf '%s\n' "$ENABLE_VPN_PROFILE" ;;
    ENABLE_HARDWARE_TRANSCODING) printf '%s\n' "$ENABLE_HARDWARE_TRANSCODING" ;;
    CADDY_IMAGE_TAG) printf '%s\n' "$CADDY_IMAGE_TAG" ;;
    JELLYFIN_IMAGE_TAG) printf '%s\n' "$JELLYFIN_IMAGE_TAG" ;;
    QBITTORRENT_IMAGE_TAG) printf '%s\n' "$QBITTORRENT_IMAGE_TAG" ;;
    SONARR_IMAGE_TAG) printf '%s\n' "$SONARR_IMAGE_TAG" ;;
    RADARR_IMAGE_TAG) printf '%s\n' "$RADARR_IMAGE_TAG" ;;
    PROWLARR_IMAGE_TAG) printf '%s\n' "$PROWLARR_IMAGE_TAG" ;;
    BAZARR_IMAGE_TAG) printf '%s\n' "$BAZARR_IMAGE_TAG" ;;
    SEERR_IMAGE_TAG) printf '%s\n' "$SEERR_IMAGE_TAG" ;;
    RECYCLARR_IMAGE_TAG) printf '%s\n' "$RECYCLARR_IMAGE_TAG" ;;
    FLARESOLVERR_IMAGE_TAG) printf '%s\n' "$FLARESOLVERR_IMAGE_TAG" ;;
    *) return 1 ;;
  esac
}

vf_read_env_file() {
  vf_input_file=$1
  vf_allow_secrets=${2:-false}
  [ -f "$vf_input_file" ] || vf_die "configuration input does not exist: $vf_input_file"

  if LC_ALL=C od -An -tu1 "$vf_input_file" | awk '{ for (i = 1; i <= NF; i++) if ($i == 0 || $i == 13 || ($i < 32 && $i != 10) || $i == 127) found = 1 } END { exit !found }'; then
    vf_die "configuration input contains a NUL, carriage return, or control character"
  fi

  while IFS= read -r vf_line || [ -n "$vf_line" ]; do
    case "$vf_line" in
      ''|'#'*) continue ;;
    esac
    case "$vf_line" in
      *=*) ;;
      *) vf_die "invalid configuration line in $vf_input_file" ;;
    esac
    vf_key=${vf_line%%=*}
    vf_value=${vf_line#*=}
    [[ "$vf_key" =~ ^[A-Z][A-Z0-9_]*$ ]] || vf_die "invalid configuration key in $vf_input_file"
    vf_assign_setting "$vf_key" "$vf_value" "$vf_allow_secrets"
  done <"$vf_input_file"
}

vf_load_defaults() {
  MANAGEMENT_PASSWORD=
  vf_read_env_file "$VEINFIN_REPO_DIR/.env.example" true
}

vf_valid_ipv4() {
  vf_ip=$1
  [[ "$vf_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  vf_old_ifs=$IFS
  IFS=.
  set -- $vf_ip
  IFS=$vf_old_ifs
  [ "$#" -eq 4 ] || return 1
  for vf_octet in "$@"; do
    [ "$vf_octet" -ge 0 ] 2>/dev/null && [ "$vf_octet" -le 255 ] 2>/dev/null || return 1
  done
}

vf_valid_ipv6() {
  vf_ip=$1
  [[ "$vf_ip" == *:* ]] || return 1
  [[ "$vf_ip" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
  [[ "$vf_ip" != *:::* ]] || return 1
  vf_double=${vf_ip#*::}
  if [[ "$vf_ip" == *::* ]] && [[ "$vf_double" == *::* ]]; then return 1; fi
  vf_old_ifs=$IFS
  IFS=:
  set -- $vf_ip
  IFS=$vf_old_ifs
  [ "$#" -le 8 ] || return 1
  if [[ "$vf_ip" != *::* ]] && [ "$#" -ne 8 ]; then return 1; fi
  for vf_group in "$@"; do
    [ -z "$vf_group" ] && continue
    [ "${#vf_group}" -le 4 ] || return 1
  done
}

vf_valid_ip() {
  vf_valid_ipv4 "$1" || vf_valid_ipv6 "$1"
}

vf_valid_hostname() {
  vf_host=$1
  [ -n "$vf_host" ] && [ "${#vf_host}" -le 253 ] || return 1
  [[ "$vf_host" != *[!A-Za-z0-9.-]* ]] || return 1
  [[ "$vf_host" == *.* ]] || return 1
  [[ "$vf_host" != .* && "$vf_host" != *. && "$vf_host" != *..* ]] || return 1
  vf_old_ifs=$IFS
  IFS=.
  set -- $vf_host
  IFS=$vf_old_ifs
  for vf_label in "$@"; do
    [ -n "$vf_label" ] && [ "${#vf_label}" -le 63 ] || return 1
    [[ "$vf_label" != -* && "$vf_label" != *- ]] || return 1
  done
}

vf_valid_cidr() {
  vf_cidr=$1
  [[ "$vf_cidr" == */* ]] || return 1
  vf_address=${vf_cidr%/*}
  vf_prefix=${vf_cidr##*/}
  [[ "$vf_prefix" =~ ^[0-9]+$ ]] || return 1
  if vf_valid_ipv4 "$vf_address"; then
    [ "$vf_prefix" -le 32 ]
  elif vf_valid_ipv6 "$vf_address"; then
    [ "$vf_prefix" -le 128 ]
  else
    return 1
  fi
}

vf_valid_allowlist() {
  vf_list=$1
  [ -n "$vf_list" ] || return 1
  vf_old_ifs=$IFS
  IFS=,
  set -- $vf_list
  IFS=$vf_old_ifs
  [ "$#" -ge 1 ] || return 1
  for vf_entry in "$@"; do
    [ "$vf_entry" = "${vf_entry//[[:space:]]/}" ] || return 1
    vf_valid_cidr "$vf_entry" || return 1
  done
}

vf_valid_path() {
  vf_path=$1
  [ -n "$vf_path" ] && [[ "$vf_path" == /* ]] && [ "$vf_path" != / ] || return 1
  vf_safe_scalar "$vf_path" && [[ "$vf_path" =~ ^/[A-Za-z0-9._/-]+$ ]] || return 1
  [[ "/$vf_path/" != */../* && "/$vf_path/" != */./* ]] || return 1
}

vf_valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

vf_valid_id() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 2147483647 ]
}

vf_expected_image_pin() {
  vf_lock_key=$1
  awk -F'|' -v key="$vf_lock_key" '$1 == key { print $3 "@" $4; found++ } END { if (found != 1) exit 1 }' "$VEINFIN_REPO_DIR/config/images.lock"
}

vf_validate_image_pins() {
  for vf_pin_name in CADDY_IMAGE_TAG JELLYFIN_IMAGE_TAG QBITTORRENT_IMAGE_TAG SONARR_IMAGE_TAG RADARR_IMAGE_TAG PROWLARR_IMAGE_TAG BAZARR_IMAGE_TAG SEERR_IMAGE_TAG RECYCLARR_IMAGE_TAG FLARESOLVERR_IMAGE_TAG; do
    vf_pin_value=$(vf_value_by_name "$vf_pin_name")
    vf_expected_pin=$(vf_expected_image_pin "$vf_pin_name") || { vf_error "$vf_pin_name is missing or duplicated in config/images.lock"; return 1; }
    [ "$vf_pin_value" = "$vf_expected_pin" ] || { vf_error "$vf_pin_name must exactly match config/images.lock"; return 1; }
  done
}

vf_validate_config() {
  [ "$INSTALLATION_PROFILE" = public-https ] || [ "$INSTALLATION_PROFILE" = lan-only ] || { vf_error "INSTALLATION_PROFILE must be public-https or lan-only"; return 1; }
  [[ "$COMPOSE_PROJECT_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { vf_error "COMPOSE_PROJECT_NAME must use lowercase letters, digits, hyphens, or underscores and start with a letter or digit"; return 1; }
  if [ "$INSTALLATION_PROFILE" = public-https ]; then
    vf_valid_hostname "$PUBLIC_HOSTNAME" || { vf_error "PUBLIC_HOSTNAME must be a valid fully qualified hostname for public-https"; return 1; }
    [[ "$PUBLIC_HOSTNAME" != *.example.test ]] || { vf_error "PUBLIC_HOSTNAME still contains the documentation placeholder"; return 1; }
  else
    [ "$PUBLIC_BIND_IP" = 127.0.0.1 ] || [ "$PUBLIC_BIND_IP" = ::1 ] || { vf_error "PUBLIC_BIND_IP must be loopback for lan-only"; return 1; }
  fi
  vf_valid_ip "$PUBLIC_BIND_IP" || { vf_error "PUBLIC_BIND_IP must be a valid IPv4 or IPv6 address"; return 1; }
  vf_valid_ip "$MANAGEMENT_BIND_IP" || { vf_error "MANAGEMENT_BIND_IP must be a valid IPv4 or IPv6 address"; return 1; }
  [ "$MANAGEMENT_BIND_IP" != 0.0.0.0 ] && [ "$MANAGEMENT_BIND_IP" != :: ] || { vf_error "MANAGEMENT_BIND_IP must be a specific address, not a wildcard"; return 1; }
  if ! vf_valid_hostname "$MANAGEMENT_URL_HOST" && ! vf_valid_ipv4 "$MANAGEMENT_URL_HOST" && [ "$MANAGEMENT_URL_HOST" != localhost ]; then
    vf_error "MANAGEMENT_URL_HOST must be a hostname, localhost, or IPv4 address"
    return 1
  fi
  vf_valid_allowlist "$MANAGEMENT_ALLOWED_CIDRS" || { vf_error "MANAGEMENT_ALLOWED_CIDRS must be a comma-separated CIDR list"; return 1; }
  vf_valid_allowlist "$PROTECTED_LAN_CIDRS" || { vf_error "PROTECTED_LAN_CIDRS must be a comma-separated CIDR list"; return 1; }
  vf_valid_port "$SSH_PORT" || { vf_error "SSH_PORT must be between 1 and 65535"; return 1; }
  vf_valid_id "$PUID" || { vf_error "PUID must be a non-root numeric ID"; return 1; }
  vf_valid_id "$PGID" || { vf_error "PGID must be a non-root numeric ID"; return 1; }
  [[ "$UMASK" =~ ^0?[0-7]{3}$ ]] || { vf_error "UMASK must contain three or four octal digits"; return 1; }
  [ -n "$TZ" ] && [[ "$TZ" != *..* ]] && [[ "$TZ" =~ ^[A-Za-z0-9_+./-]+$ ]] || { vf_error "TZ has invalid syntax"; return 1; }
  if [ -d /usr/share/zoneinfo ] && [ ! -f "/usr/share/zoneinfo/$TZ" ]; then
    vf_error "TZ is not present in the host zoneinfo database"
    return 1
  fi
  vf_valid_path "$CONFIG_ROOT" || { vf_error "CONFIG_ROOT must be a safe absolute path other than /"; return 1; }
  vf_valid_path "$MEDIA_ROOT" || { vf_error "MEDIA_ROOT must be a safe absolute path other than /"; return 1; }
  vf_valid_path "$RUNTIME_ROOT" || { vf_error "RUNTIME_ROOT must be a safe absolute path other than /"; return 1; }
  vf_valid_path "$LEGACY_CANDIDATE_ROOT" || { vf_error "LEGACY_CANDIDATE_ROOT must be a safe absolute path other than /"; return 1; }
  [ "$CONFIG_ROOT" != "$MEDIA_ROOT" ] || { vf_error "CONFIG_ROOT and MEDIA_ROOT must differ"; return 1; }
  [[ "$MANAGEMENT_USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { vf_error "MANAGEMENT_USERNAME has invalid syntax"; return 1; }
  [ "$MANAGEMENT_URL_SCHEME" = http ] || [ "$MANAGEMENT_URL_SCHEME" = https ] || { vf_error "MANAGEMENT_URL_SCHEME must be http or https"; return 1; }
  [ -z "$VPN_PROVIDER" ] || [[ "$VPN_PROVIDER" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { vf_error "VPN_PROVIDER has invalid syntax"; return 1; }

  for vf_port_name in HTTPS_PORT QBITTORRENT_MANAGEMENT_PORT SONARR_MANAGEMENT_PORT RADARR_MANAGEMENT_PORT PROWLARR_MANAGEMENT_PORT BAZARR_MANAGEMENT_PORT SEERR_MANAGEMENT_PORT CONTROL_PANEL_MANAGEMENT_PORT JELLYFIN_MANAGEMENT_PORT JELLYFIN_DISCOVERY_PORT LEGACY_CANDIDATE_PORT; do
    vf_port_value=$(vf_value_by_name "$vf_port_name")
    vf_valid_port "$vf_port_value" || { vf_error "$vf_port_name must be between 1 and 65535"; return 1; }
  done

  vf_management_ports=$(printf '%s\n' "$QBITTORRENT_MANAGEMENT_PORT" "$SONARR_MANAGEMENT_PORT" "$RADARR_MANAGEMENT_PORT" "$PROWLARR_MANAGEMENT_PORT" "$BAZARR_MANAGEMENT_PORT" "$SEERR_MANAGEMENT_PORT" "$CONTROL_PANEL_MANAGEMENT_PORT" "$JELLYFIN_MANAGEMENT_PORT")
  [ "$(printf '%s\n' "$vf_management_ports" | sort -u | wc -l | tr -d ' ')" = 8 ] || { vf_error "management TCP host ports must be unique"; return 1; }
  if printf '%s\n' "$vf_management_ports" | grep -qx "$HTTPS_PORT"; then
    case "$PUBLIC_BIND_IP" in
      0.0.0.0|::|"$MANAGEMENT_BIND_IP") vf_error "HTTPS_PORT conflicts with a management port on an overlapping bind address"; return 1 ;;
    esac
  fi

  for vf_bool_name in ENABLE_MIGRATION_STAGES ENABLE_JELLYFIN_DISCOVERY ENABLE_VPN_PROFILE ENABLE_HARDWARE_TRANSCODING; do
    vf_bool_value=$(vf_value_by_name "$vf_bool_name")
    [ "$vf_bool_value" = true ] || [ "$vf_bool_value" = false ] || { vf_error "$vf_bool_name must be true or false"; return 1; }
  done

  if [ "$ENABLE_JELLYFIN_DISCOVERY" = true ]; then
    vf_valid_ip "$JELLYFIN_DISCOVERY_BIND_IP" || { vf_error "JELLYFIN_DISCOVERY_BIND_IP must be a valid address"; return 1; }
  fi
  if [ "$ENABLE_HARDWARE_TRANSCODING" = true ]; then
    vf_valid_path "$TRANSCODING_DEVICE" && [[ "$TRANSCODING_DEVICE" =~ ^/dev/dri/renderD[0-9]+$ ]] || {
      vf_error "TRANSCODING_DEVICE must be a safe /dev/dri/renderD<number> path when hardware transcoding is enabled"
      return 1
    }
  elif [ -n "$TRANSCODING_DEVICE" ]; then
    vf_error "TRANSCODING_DEVICE must be empty while hardware transcoding is disabled"
    return 1
  fi

  vf_validate_image_pins
}

vf_prepare_runtime() {
  umask 077
  for vf_dir in "$RUNTIME_ROOT" "$RUNTIME_ROOT/config" "$RUNTIME_ROOT/config/caddy" "$RUNTIME_ROOT/config/recyclarr" "$RUNTIME_ROOT/secrets" "$RUNTIME_ROOT/state" "$RUNTIME_ROOT/generated"; do
    [ ! -L "$vf_dir" ] || vf_die "refusing symlinked runtime directory: $vf_dir"
    mkdir -p "$vf_dir"
    chmod 0700 "$vf_dir"
  done
}

vf_secret_file_for_key() {
  case "$1" in
    MANAGEMENT_PASSWORD) printf '%s\n' management-password ;;
    *) return 1 ;;
  esac
}

vf_generate_or_load_secrets() {
  for vf_secret_key in MANAGEMENT_PASSWORD; do
    vf_secret_name=$(vf_secret_file_for_key "$vf_secret_key")
    vf_secret_path="$RUNTIME_ROOT/secrets/$vf_secret_name"
    if [ -f "$vf_secret_path" ] && [ "${VF_ROTATE_SECRETS:-false}" != true ]; then
      vf_secret_value=$(tr -d '\r\n' <"$vf_secret_path")
      [ -n "$vf_secret_value" ] || vf_die "existing secret file is empty: $vf_secret_name"
    else
      vf_secret_value=$(vf_random_hex 32)
      printf '%s\n' "$vf_secret_value" | vf_atomic_write "$vf_secret_path" 0600
    fi
    vf_assign_setting "$vf_secret_key" "$vf_secret_value" true
  done
}

vf_write_env() {
  {
    printf '# Generated by VeinFin. Contains secrets; mode 0600.\n'
    printf 'INSTALLATION_PROFILE=%s\nENABLE_MIGRATION_STAGES=%s\n' "$INSTALLATION_PROFILE" "$ENABLE_MIGRATION_STAGES"
    printf 'COMPOSE_PROJECT_NAME=%s\n' "$COMPOSE_PROJECT_NAME"
    printf 'TZ=%s\nPUID=%s\nPGID=%s\nUMASK=%s\n' "$TZ" "$PUID" "$PGID" "$UMASK"
    printf 'CONFIG_ROOT=%s\nMEDIA_ROOT=%s\nRUNTIME_ROOT=%s\n' "$CONFIG_ROOT" "$MEDIA_ROOT" "$RUNTIME_ROOT"
    printf 'PUBLIC_HOSTNAME=%s\nPUBLIC_BIND_IP=%s\nHTTPS_PORT=%s\n' "$PUBLIC_HOSTNAME" "$PUBLIC_BIND_IP" "$HTTPS_PORT"
    printf 'MANAGEMENT_BIND_IP=%s\nMANAGEMENT_URL_SCHEME=%s\nMANAGEMENT_URL_HOST=%s\nMANAGEMENT_ALLOWED_CIDRS=%s\nPROTECTED_LAN_CIDRS=%s\nSSH_PORT=%s\nMANAGEMENT_USERNAME=%s\n' "$MANAGEMENT_BIND_IP" "$MANAGEMENT_URL_SCHEME" "$MANAGEMENT_URL_HOST" "$MANAGEMENT_ALLOWED_CIDRS" "$PROTECTED_LAN_CIDRS" "$SSH_PORT" "$MANAGEMENT_USERNAME"
    printf 'QBITTORRENT_MANAGEMENT_PORT=%s\nSONARR_MANAGEMENT_PORT=%s\nRADARR_MANAGEMENT_PORT=%s\nPROWLARR_MANAGEMENT_PORT=%s\nBAZARR_MANAGEMENT_PORT=%s\nSEERR_MANAGEMENT_PORT=%s\nCONTROL_PANEL_MANAGEMENT_PORT=%s\nJELLYFIN_MANAGEMENT_PORT=%s\n' "$QBITTORRENT_MANAGEMENT_PORT" "$SONARR_MANAGEMENT_PORT" "$RADARR_MANAGEMENT_PORT" "$PROWLARR_MANAGEMENT_PORT" "$BAZARR_MANAGEMENT_PORT" "$SEERR_MANAGEMENT_PORT" "$CONTROL_PANEL_MANAGEMENT_PORT" "$JELLYFIN_MANAGEMENT_PORT"
    printf 'ENABLE_JELLYFIN_DISCOVERY=%s\nJELLYFIN_DISCOVERY_BIND_IP=%s\nJELLYFIN_DISCOVERY_PORT=%s\n' "$ENABLE_JELLYFIN_DISCOVERY" "$JELLYFIN_DISCOVERY_BIND_IP" "$JELLYFIN_DISCOVERY_PORT"
    printf 'CADDY_IMAGE_TAG=%s\nJELLYFIN_IMAGE_TAG=%s\nLEGACY_CANDIDATE_ROOT=%s\nLEGACY_CANDIDATE_PORT=%s\nQBITTORRENT_IMAGE_TAG=%s\nSONARR_IMAGE_TAG=%s\nRADARR_IMAGE_TAG=%s\nPROWLARR_IMAGE_TAG=%s\nBAZARR_IMAGE_TAG=%s\nSEERR_IMAGE_TAG=%s\nRECYCLARR_IMAGE_TAG=%s\nFLARESOLVERR_IMAGE_TAG=%s\n' "$CADDY_IMAGE_TAG" "$JELLYFIN_IMAGE_TAG" "$LEGACY_CANDIDATE_ROOT" "$LEGACY_CANDIDATE_PORT" "$QBITTORRENT_IMAGE_TAG" "$SONARR_IMAGE_TAG" "$RADARR_IMAGE_TAG" "$PROWLARR_IMAGE_TAG" "$BAZARR_IMAGE_TAG" "$SEERR_IMAGE_TAG" "$RECYCLARR_IMAGE_TAG" "$FLARESOLVERR_IMAGE_TAG"
    printf 'ENABLE_VPN_PROFILE=%s\nVPN_PROVIDER=%s\nENABLE_HARDWARE_TRANSCODING=%s\nTRANSCODING_DEVICE=%s\n' "$ENABLE_VPN_PROFILE" "$VPN_PROVIDER" "$ENABLE_HARDWARE_TRANSCODING" "$TRANSCODING_DEVICE"
    printf 'MANAGEMENT_PASSWORD=%s\n' "$MANAGEMENT_PASSWORD"
  } | vf_atomic_write "$VEINFIN_ENV_FILE" 0600
}

vf_render_templates() {
  sed "s/{\$PUBLIC_HOSTNAME}/$PUBLIC_HOSTNAME/g" "$VEINFIN_REPO_DIR/templates/caddy/Caddyfile.tmpl" | vf_atomic_write "$RUNTIME_ROOT/config/caddy/Caddyfile" 0600

  {
    printf '# Generated non-secret endpoint contract.\n'
    if [ "$INSTALLATION_PROFILE" = public-https ]; then
      printf 'JELLYFIN_PUBLIC_URL=https://%s\n' "$PUBLIC_HOSTNAME"
    else
      printf 'JELLYFIN_PUBLIC_URL=http://%s:%s\n' "$MANAGEMENT_URL_HOST" "$JELLYFIN_MANAGEMENT_PORT"
    fi
    printf 'JELLYFIN_INTERNAL_URL=http://jellyfin:8096\n'
    printf 'QBITTORRENT_INTERNAL_URL=http://qbittorrent:8080\n'
    printf 'SONARR_INTERNAL_URL=http://sonarr:8989\n'
    printf 'RADARR_INTERNAL_URL=http://radarr:7878\n'
    printf 'PROWLARR_INTERNAL_URL=http://prowlarr:9696\n'
    printf 'BAZARR_INTERNAL_URL=http://bazarr:6767\n'
    printf 'SEERR_INTERNAL_URL=http://seerr:5055\n'
    printf 'FLARESOLVERR_INTERNAL_URL=http://flaresolverr:8191\n'
    printf 'QBITTORRENT_PRIVATE_URL=%s://%s:%s\n' "$MANAGEMENT_URL_SCHEME" "$MANAGEMENT_URL_HOST" "$QBITTORRENT_MANAGEMENT_PORT"
    printf 'SONARR_PRIVATE_URL=%s://%s:%s\n' "$MANAGEMENT_URL_SCHEME" "$MANAGEMENT_URL_HOST" "$SONARR_MANAGEMENT_PORT"
    printf 'RADARR_PRIVATE_URL=%s://%s:%s\n' "$MANAGEMENT_URL_SCHEME" "$MANAGEMENT_URL_HOST" "$RADARR_MANAGEMENT_PORT"
    printf 'PROWLARR_PRIVATE_URL=%s://%s:%s\n' "$MANAGEMENT_URL_SCHEME" "$MANAGEMENT_URL_HOST" "$PROWLARR_MANAGEMENT_PORT"
    printf 'BAZARR_PRIVATE_URL=%s://%s:%s\n' "$MANAGEMENT_URL_SCHEME" "$MANAGEMENT_URL_HOST" "$BAZARR_MANAGEMENT_PORT"
    printf 'SEERR_PRIVATE_URL=%s://%s:%s\n' "$MANAGEMENT_URL_SCHEME" "$MANAGEMENT_URL_HOST" "$SEERR_MANAGEMENT_PORT"
    printf 'CONFIG_ROOT=%s\nMEDIA_ROOT=%s\n' "$CONFIG_ROOT" "$MEDIA_ROOT"
  } | vf_atomic_write "$RUNTIME_ROOT/generated/endpoints.env" 0600

  {
    printf 'compose.yaml\n'
    if [ "$ENABLE_JELLYFIN_DISCOVERY" = true ]; then
      printf 'compose/discovery.yaml\n'
    fi
  } | vf_atomic_write "$RUNTIME_ROOT/generated/compose-files.txt" 0600

  {
    printf '# No application API keys exist until a verified bootstrap creates or captures them.\n'
    printf 'QBITTORRENT_MANAGEMENT_PASSWORD_SOURCE=MANAGEMENT_PASSWORD\n'
    printf 'QBITTORRENT_MANAGEMENT_CREDENTIAL_STATUS=PENDING_APPLICATION\n'
    printf 'SONARR_API_KEY=PENDING_BOOTSTRAP\n'
    printf 'RADARR_API_KEY=PENDING_BOOTSTRAP\n'
    printf 'PROWLARR_API_KEY=PENDING_BOOTSTRAP\n'
    printf 'BAZARR_API_KEY=PENDING_BOOTSTRAP\n'
    printf 'SEERR_API_KEY=PENDING_BOOTSTRAP\n'
  } | vf_atomic_write "$RUNTIME_ROOT/state/bootstrap-status.env" 0600
}

vf_write_credentials_summary() {
  {
    printf 'VeinFin local credential summary\n'
    printf 'Generated for local administrative use. No Visit URL contains credentials.\n'
    printf 'Status: not yet applied; deployment and verified bootstrap have not run.\n\n'
    printf 'Management username: %s\n' "$MANAGEMENT_USERNAME"
    printf 'Management password: %s\n' "$MANAGEMENT_PASSWORD"
    printf 'Intended use: shared local management login, including qBittorrent where supported.\n'
    printf 'Application API keys and control-panel secrets are created only by their verified installation stages.\n'
  } | vf_atomic_write "$RUNTIME_ROOT/secrets/credentials-summary.txt" 0600
}
