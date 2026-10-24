#!/usr/bin/env bash

VF_PREFLIGHT_FAILURES=0

vf_check_pass() { printf 'PASS: %s\n' "$*"; }
vf_check_warn() { printf 'WARN: %s\n' "$*"; }
vf_check_fail() { printf 'FAIL: %s\n' "$*"; VF_PREFLIGHT_FAILURES=$((VF_PREFLIGHT_FAILURES + 1)); }

vf_total_ram_mib() {
  if [ -r /proc/meminfo ]; then
    awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo
  elif vf_command_exists sysctl; then
    vf_bytes=$(sysctl -n hw.memsize 2>/dev/null || printf 0)
    printf '%s\n' $((vf_bytes / 1024 / 1024))
  else
    printf '0\n'
  fi
}

vf_total_swap_mib() {
  if [ -r /proc/meminfo ]; then
    awk '/^SwapTotal:/ {print int($2 / 1024)}' /proc/meminfo
  elif vf_command_exists sysctl; then
    vf_swap=$(sysctl -n vm.swapusage 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="total") {gsub("M", "", $(i+2)); print int($(i+2)); exit}}')
    printf '%s\n' "${vf_swap:-0}"
  else
    printf '0\n'
  fi
}

vf_cpu_count() {
  if vf_command_exists getconf; then
    getconf _NPROCESSORS_ONLN 2>/dev/null || printf 'unknown\n'
  elif vf_command_exists sysctl; then
    sysctl -n hw.ncpu 2>/dev/null || printf 'unknown\n'
  else
    printf 'unknown\n'
  fi
}

vf_port_occupied() {
  vf_protocol=$1
  vf_port=$2
  if vf_command_exists ss; then
    if [ "$vf_protocol" = tcp ]; then
      ss -lntH 2>/dev/null | awk -v port="$vf_port" '$4 ~ (":" port "$") {found=1} END {exit !found}'
    else
      ss -lnuH 2>/dev/null | awk -v port="$vf_port" '$4 ~ (":" port "$") {found=1} END {exit !found}'
    fi
  elif vf_command_exists lsof; then
    if [ "$vf_protocol" = tcp ]; then
      lsof -nP -iTCP:"$vf_port" -sTCP:LISTEN >/dev/null 2>&1
    else
      lsof -nP -iUDP:"$vf_port" >/dev/null 2>&1
    fi
  else
    return 2
  fi
}

vf_check_permissions() {
  if [ -f "$VEINFIN_ENV_FILE" ]; then
    vf_mode=$(vf_file_mode "$VEINFIN_ENV_FILE")
    [ "$vf_mode" = 600 ] && vf_check_pass ".env permissions are 0600" || vf_check_fail ".env permissions must be 0600"
  else
    vf_check_fail "generated .env is absent"
  fi

  if [ -d "$RUNTIME_ROOT/secrets" ]; then
    vf_mode=$(vf_file_mode "$RUNTIME_ROOT/secrets")
    [ "$vf_mode" = 700 ] && vf_check_pass "secret directory permissions are 0700" || vf_check_fail "secret directory permissions must be 0700"
    for vf_secret_path in "$RUNTIME_ROOT"/secrets/*; do
      [ -e "$vf_secret_path" ] || continue
      [ -f "$vf_secret_path" ] || continue
      vf_mode=$(vf_file_mode "$vf_secret_path")
      [ "$vf_mode" = 600 ] || vf_check_fail "a secret file does not have mode 0600"
    done
  else
    vf_check_fail "secret directory is absent"
  fi
}

vf_run_preflight() {
  VF_PREFLIGHT_FAILURES=0
  vf_os=$(uname -s)
  vf_arch=$(uname -m)
  if [ -r /etc/os-release ]; then
    vf_os_name=$(awk -F= '/^PRETTY_NAME=/{gsub(/^"|"$/, "", $2); print $2}' /etc/os-release)
  else
    vf_os_name=$vf_os
  fi
  vf_info "Operating system: $vf_os_name"
  vf_info "Architecture: $vf_arch"
  case "$vf_arch" in
    x86_64|amd64) vf_check_pass "architecture is compatible with locked amd64 images" ;;
    *) vf_check_fail "architecture is not the verified Debian amd64 target" ;;
  esac

  vf_ram=$(vf_total_ram_mib)
  vf_swap=$(vf_total_swap_mib)
  vf_cpus=$(vf_cpu_count)
  vf_info "CPU cores: $vf_cpus"
  vf_info "RAM: ${vf_ram} MiB"
  vf_info "Swap: ${vf_swap} MiB"
  if [ "$vf_ram" -lt 8192 ]; then
    vf_check_warn "full stack has less than 8 GiB RAM; at least 12 GiB is recommended"
  elif [ "$vf_ram" -lt 12288 ]; then
    vf_check_warn "full stack meets the 8 GiB floor, but at least 12 GiB is recommended"
  else
    vf_check_pass "RAM meets the 12 GiB recommendation"
  fi

  for vf_required in awk chmod grep mkdir mktemp mv od sed sort stat tr uname wc; do
    vf_command_exists "$vf_required" && vf_check_pass "required command available: $vf_required" || vf_check_fail "required command missing: $vf_required"
  done
  if vf_command_exists openssl || { [ -r /dev/urandom ] && vf_command_exists od; }; then
    vf_check_pass "secure random source is available"
  else
    vf_check_fail "secure random source is unavailable"
  fi

  if vf_command_exists docker; then
    vf_check_pass "Docker command is available"
    docker compose version >/dev/null 2>&1 && vf_check_pass "Docker Compose plugin is available" || vf_check_fail "Docker Compose plugin is unavailable"
  else
    vf_check_fail "Docker is unavailable"
    vf_check_fail "Docker Compose is unavailable"
  fi

  if [ -d "$MEDIA_ROOT" ]; then
    vf_check_pass "configured media root exists"
  else
    vf_check_fail "configured media root does not exist"
  fi

  if vf_command_exists findmnt && [ -d "$MEDIA_ROOT" ]; then
    vf_mount_target=$(findmnt -n -T "$MEDIA_ROOT" -o TARGET 2>/dev/null || true)
    if [ "$vf_mount_target" = "$MEDIA_ROOT" ]; then
      vf_check_pass "media root is a mounted filesystem"
    else
      vf_check_fail "media root is not its own mounted filesystem"
    fi
  else
    vf_check_fail "media mount readiness cannot be proven"
  fi

  for vf_media_dir in torrents/movies torrents/tv torrents/anime library/movies library/tv library/anime; do
    [ -d "$MEDIA_ROOT/$vf_media_dir" ] && vf_check_pass "media directory exists: $vf_media_dir" || vf_check_fail "media directory missing: $vf_media_dir"
  done

  vf_render_device=
  for vf_candidate in /dev/dri/renderD*; do
    if [ -e "$vf_candidate" ]; then vf_render_device=$vf_candidate; break; fi
  done
  if [ "$ENABLE_HARDWARE_TRANSCODING" = true ]; then
    if [ -n "$vf_render_device" ] && [ -e "$TRANSCODING_DEVICE" ]; then
      vf_check_pass "configured hardware-transcoding render device exists"
    else
      vf_check_fail "hardware transcoding is enabled but its render device is unavailable"
    fi
  elif [ -n "$vf_render_device" ]; then
    vf_check_warn "a render device exists, but hardware transcoding remains disabled"
  else
    vf_check_warn "no renderD device found; hardware transcoding remains disabled"
  fi

  for vf_port_spec in "tcp:$HTTPS_PORT" "tcp:$QBITTORRENT_MANAGEMENT_PORT" "tcp:$SONARR_MANAGEMENT_PORT" "tcp:$RADARR_MANAGEMENT_PORT" "tcp:$PROWLARR_MANAGEMENT_PORT" "tcp:$BAZARR_MANAGEMENT_PORT" "tcp:$SEERR_MANAGEMENT_PORT"; do
    vf_protocol=${vf_port_spec%%:*}
    vf_port=${vf_port_spec##*:}
    if vf_port_occupied "$vf_protocol" "$vf_port"; then
      vf_check_fail "$vf_protocol port $vf_port is already occupied"
    else
      vf_port_status=$?
      if [ "$vf_port_status" -eq 2 ]; then
        vf_check_fail "cannot inspect configured ports because ss/lsof is unavailable"
        break
      fi
      vf_check_pass "$vf_protocol port $vf_port is available"
    fi
  done
  if [ "$ENABLE_JELLYFIN_DISCOVERY" = true ]; then
    if vf_port_occupied udp "$JELLYFIN_DISCOVERY_PORT"; then
      vf_check_fail "UDP discovery port is occupied"
    else
      vf_check_pass "UDP discovery port is available"
    fi
  fi

  vf_validate_config && vf_check_pass "configuration values and image pins are valid" || vf_check_fail "configuration validation failed"
  vf_check_permissions
  vf_check_warn "Compose cannot enforce MANAGEMENT_ALLOWED_CIDRS; verify the separate host firewall before deployment"

  if [ "$VF_PREFLIGHT_FAILURES" -eq 0 ]; then
    vf_info "Preflight: checks passed; deployment is not implemented and this is not a deployment-ready result"
    return 0
  fi
  vf_info "Preflight: $VF_PREFLIGHT_FAILURES failed checks; deployment remains unavailable"
  return 1
}
