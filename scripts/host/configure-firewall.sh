#!/usr/bin/env bash
# Managed by VeinFin. Reusable host and Docker firewall policy.
set -euo pipefail

SCRIPT_VERSION=1
HOST_CHAIN=VEINFIN-HOST-IN
DOCKER_CHAIN=VEINFIN-DOCKER
CONFIG_PATH=/etc/veinfin/firewall.conf
INSTALL_PATH=/usr/local/sbin/veinfin-firewall
SERVICE_PATH=/etc/systemd/system/veinfin-firewall.service
DOCKER_DROPIN_PATH=/etc/systemd/system/docker.service.d/veinfin-firewall.conf
ROLLBACK_POINTER=/run/veinfin-firewall.rollback
LOCK_PATH=/run/lock/veinfin-firewall.lock
DEFAULT_MANAGEMENT_TCP_PORTS=3000,5055,6767,7878,8080,8989,9696
ACTIVE_TEMP=

info() { printf 'INFO: %s\n' "$*"; }
pass() { printf 'PASS: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [ -n "${ACTIVE_TEMP:-}" ] && [ -e "$ACTIVE_TEMP" ]; then
    rm -f -- "$ACTIVE_TEMP"
  fi
}
trap cleanup EXIT HUP INT TERM

usage() {
  cat <<'EOF'
VeinFin host and Docker firewall

Usage:
  configure-firewall.sh --help
  configure-firewall.sh --check [--config FILE]
  sudo configure-firewall.sh --apply --config FILE
  sudo configure-firewall.sh --update-public-https --config FILE
  sudo configure-firewall.sh --update-management --config FILE
  sudo configure-firewall.sh --verify
  sudo configure-firewall.sh --remove

Modes:
  --help    Show this help without changing the host.
  --check   Audit prerequisites and conflicts without changing the host. When
            --config is supplied (or an installed config exists), also validate
            policy values, the active SSH peer, and route/interface safety.
  --apply   Install and apply the policy. A timed exact-rules rollback remains
            armed until a separate SSH session successfully runs --verify.
  --update-public-https
            With an installed VeinFin policy, permit only a false-to-true
            public-HTTPS transition. Every other policy value must be exact.
            Existing containers are allowed and the same rollback is armed.
  --update-management
            Enable only the installed allowlisted management-port set. Every
            other policy value remains exact and the same rollback is armed.
  --verify  Verify installed files, rule order, policy, Docker integration, and
            SSH peer coverage; cancel rollback only after every check passes.
  --remove  Remove only VeinFin-owned rules and persistence files.

The script never flushes or replaces Docker-owned chains. It does not deploy
containers, publish ports, change DNS/router/storage, or disable IPv6.
EOF
}

require_root() {
  [ "$EUID" -eq 0 ] || die "$1 must run as root (use sudo)"
}

require_commands() {
  local command_name
  for command_name in awk cat chmod chown cmp cp cut date dirname docker dpkg flock grep head id install ip ip6tables ip6tables-restore ip6tables-save iptables iptables-restore iptables-save mktemp mv nft rm sed sleep sort ss systemctl systemd-run tr uname; do
    command -v "$command_name" >/dev/null 2>&1 || die "required command missing: $command_name"
  done
}

reset_config() {
  MANAGEMENT_ALLOWED_CIDRS=
  MANAGEMENT_ALLOWED_IPV6_CIDRS=
  PROTECTED_LAN_CIDRS=
  SSH_PORT=
  ENABLE_PUBLIC_HTTPS=
  ENABLE_MANAGEMENT_PORTS=
  MANAGEMENT_TCP_PORTS=$DEFAULT_MANAGEMENT_TCP_PORTS
}

load_config() {
  local file=$1 line key value line_number=0
  local seen_management=false seen_lan=false seen_ssh=false seen_https=false seen_ports=false
  [ -f "$file" ] && [ ! -L "$file" ] || die "configuration is not a regular file"
  reset_config
  while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    line=${line%$'\r'}
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) die "invalid configuration line $line_number" ;; esac
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      MANAGEMENT_ALLOWED_CIDRS)
        [ "$seen_management" = false ] || die "duplicate configuration key: $key"
        MANAGEMENT_ALLOWED_CIDRS=$value; seen_management=true ;;
      MANAGEMENT_ALLOWED_IPV6_CIDRS)
        [ -z "$MANAGEMENT_ALLOWED_IPV6_CIDRS" ] || die "duplicate configuration key: $key"
        MANAGEMENT_ALLOWED_IPV6_CIDRS=$value ;;
      PROTECTED_LAN_CIDRS)
        [ "$seen_lan" = false ] || die "duplicate configuration key: $key"
        PROTECTED_LAN_CIDRS=$value; seen_lan=true ;;
      SSH_PORT)
        [ "$seen_ssh" = false ] || die "duplicate configuration key: $key"
        SSH_PORT=$value; seen_ssh=true ;;
      ENABLE_PUBLIC_HTTPS)
        [ "$seen_https" = false ] || die "duplicate configuration key: $key"
        ENABLE_PUBLIC_HTTPS=$value; seen_https=true ;;
      ENABLE_MANAGEMENT_PORTS)
        [ "$seen_ports" = false ] || die "duplicate configuration key: $key"
        ENABLE_MANAGEMENT_PORTS=$value; seen_ports=true ;;
      MANAGEMENT_TCP_PORTS) MANAGEMENT_TCP_PORTS=$value ;;
      *) die "unknown configuration key on line $line_number" ;;
    esac
  done <"$file"
  [ "$seen_management" = true ] || die "missing required configuration key: MANAGEMENT_ALLOWED_CIDRS"
  [ "$seen_lan" = true ] || die "missing required configuration key: PROTECTED_LAN_CIDRS"
  [ "$seen_ssh" = true ] || die "missing required configuration key: SSH_PORT"
  [ "$seen_https" = true ] || die "missing required configuration key: ENABLE_PUBLIC_HTTPS"
  [ "$seen_ports" = true ] || die "missing required configuration key: ENABLE_MANAGEMENT_PORTS"
}

valid_port() {
  [[ $1 =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_ipv4_cidr() {
  local value=$1 address prefix octet
  local -a octets
  [[ $value == */* ]] || return 1
  address=${value%/*}; prefix=${value#*/}
  [[ $prefix =~ ^[0-9]+$ ]] && [ "$prefix" -le 32 ] || return 1
  IFS=. read -r -a octets <<<"$address"
  [ "${#octets[@]}" -eq 4 ] || return 1
  for octet in "${octets[@]}"; do
    [[ $octet =~ ^[0-9]+$ ]] && [ "$octet" -le 255 ] || return 1
  done
}

ipv4_to_int() {
  local address=$1 a b c d
  IFS=. read -r a b c d <<<"$address"
  printf '%u\n' "$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))"
}

ipv4_in_cidr() {
  local address=$1 cidr=$2 prefix network address_number network_number mask
  prefix=${cidr#*/}; network=${cidr%/*}
  address_number=$(ipv4_to_int "$address")
  network_number=$(ipv4_to_int "$network")
  if [ "$prefix" -eq 0 ]; then mask=0; else mask=$(( (0xffffffff << (32 - prefix)) & 0xffffffff )); fi
  [ $((address_number & mask)) -eq $((network_number & mask)) ]
}

validate_ipv4_list() {
  local value=$1 label=$2 item
  local -a items
  [ -n "$value" ] || die "$label must not be empty"
  IFS=, read -r -a items <<<"$value"
  for item in "${items[@]}"; do
    valid_ipv4_cidr "$item" || die "$label contains an invalid IPv4 CIDR"
  done
}

validate_ipv6_list() {
  local value=$1 item address prefix
  local -a items
  [ -z "$value" ] && return 0
  IFS=, read -r -a items <<<"$value"
  for item in "${items[@]}"; do
    [[ $item == */* ]] || die "MANAGEMENT_ALLOWED_IPV6_CIDRS contains an invalid IPv6 CIDR"
    address=${item%/*}; prefix=${item#*/}
    [[ $address == *:* && $prefix =~ ^[0-9]+$ && $prefix -le 128 ]] || die "MANAGEMENT_ALLOWED_IPV6_CIDRS contains an invalid IPv6 CIDR"
    ip -6 route get "$address" >/dev/null 2>&1 || die "MANAGEMENT_ALLOWED_IPV6_CIDRS contains an invalid IPv6 CIDR"
  done
}

validate_port_list() {
  local item
  local -a items
  [ -n "$MANAGEMENT_TCP_PORTS" ] || die "MANAGEMENT_TCP_PORTS must not be empty"
  IFS=, read -r -a items <<<"$MANAGEMENT_TCP_PORTS"
  for item in "${items[@]}"; do valid_port "$item" || die "MANAGEMENT_TCP_PORTS contains an invalid port"; done
}

validate_config() {
  validate_ipv4_list "$MANAGEMENT_ALLOWED_CIDRS" MANAGEMENT_ALLOWED_CIDRS
  validate_ipv4_list "$PROTECTED_LAN_CIDRS" PROTECTED_LAN_CIDRS
  validate_ipv6_list "$MANAGEMENT_ALLOWED_IPV6_CIDRS"
  valid_port "$SSH_PORT" || die "SSH_PORT is invalid"
  case "$ENABLE_PUBLIC_HTTPS" in true|false) ;; *) die "ENABLE_PUBLIC_HTTPS must be true or false" ;; esac
  case "$ENABLE_MANAGEMENT_PORTS" in true|false) ;; *) die "ENABLE_MANAGEMENT_PORTS must be true or false" ;; esac
  validate_port_list
  pass "configuration syntax and values are valid"
}

detect_network() {
  local route count
  route=$(ip -4 route show default | awk '$1 == "default" {print}')
  count=$(printf '%s\n' "$route" | awk 'NF {n++} END {print n+0}')
  [ "$count" -eq 1 ] || die "exactly one IPv4 default route is required"
  EXTERNAL_INTERFACE=$(printf '%s\n' "$route" | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')
  [ -n "$EXTERNAL_INTERFACE" ] || die "default route has no interface"
  case "$EXTERNAL_INTERFACE" in lo|docker0|br-*) die "unsafe default-route interface" ;; esac
  HOST_IPV4=$(ip -4 -o addr show dev "$EXTERNAL_INTERFACE" scope global | awk 'NR==1 {split($4,a,"/"); print a[1]}')
  [ -n "$HOST_IPV4" ] || die "external interface has no global IPv4 address"
  count=$(ip -4 -o addr show dev "$EXTERNAL_INTERFACE" scope global | awk 'END {print NR+0}')
  [ "$count" -eq 1 ] || die "external interface must have exactly one global IPv4 address"
  pass "external interface and host IPv4 route are unambiguous"
}

check_protected_route() {
  local cidr found=false
  local -a cidrs
  IFS=, read -r -a cidrs <<<"$PROTECTED_LAN_CIDRS"
  for cidr in "${cidrs[@]}"; do
    if ipv4_in_cidr "$HOST_IPV4" "$cidr"; then found=true; fi
  done
  [ "$found" = true ] || die "host LAN address is not covered by PROTECTED_LAN_CIDRS"
  pass "protected LAN covers the host LAN address"
}

peer_is_allowed() {
  local peer=$1 cidr
  local -a cidrs
  if [[ $peer == *:* ]]; then
    [ -n "$MANAGEMENT_ALLOWED_IPV6_CIDRS" ] || return 1
    IFS=, read -r -a cidrs <<<"$MANAGEMENT_ALLOWED_IPV6_CIDRS"
    for cidr in "${cidrs[@]}"; do
      ip -6 route get "$peer" >/dev/null 2>&1 || return 1
      # Exact IPv6 hosts are the safe supported management form in this operation.
      [ "${cidr#*/}" = 128 ] && [ "${cidr%/*}" = "$peer" ] && return 0
    done
    return 1
  fi
  IFS=, read -r -a cidrs <<<"$MANAGEMENT_ALLOWED_CIDRS"
  for cidr in "${cidrs[@]}"; do ipv4_in_cidr "$peer" "$cidr" && return 0; done
  return 1
}

check_ssh_peer() {
  local peer
  [ -n "${SSH_CONNECTION:-}" ] || die "active SSH peer cannot be determined"
  peer=${SSH_CONNECTION%% *}
  peer_is_allowed "$peer" || die "active SSH peer is not covered by the management allowlist"
  pass "active SSH peer is covered by the management allowlist"
}

check_platform() {
  [ -r /etc/os-release ] || die "cannot read operating-system metadata"
  # shellcheck disable=SC1091
  . /etc/os-release
  [ "${ID:-}" = debian ] && [ "${VERSION_ID:-}" = 13 ] && [ "${VERSION_CODENAME:-}" = trixie ] || die "supported target is Debian 13 trixie"
  [ "$(dpkg --print-architecture)" = amd64 ] || die "supported architecture is amd64"
  iptables --version | grep -q 'nf_tables' || die "iptables-nft backend is required"
  ip6tables --version | grep -q 'nf_tables' || die "ip6tables-nft backend is required"
  pass "Debian 13 amd64 and iptables-nft are available"
}

check_firewall_managers() {
  local unit state
  for unit in nftables.service ufw.service firewalld.service netfilter-persistent.service; do
    state=$(systemctl is-active "$unit" 2>/dev/null || true)
    [ "$state" != active ] || die "competing firewall manager is active: $unit"
    state=$(systemctl is-enabled "$unit" 2>/dev/null || true)
    case "$state" in enabled|enabled-runtime|static) die "competing firewall manager is enabled: $unit" ;; esac
  done
  pass "no competing firewall manager is active or enabled"
}

check_nft_tables() {
  local extra
  # Docker's iptables backend creates raw tables through the nft compatibility
  # layer for bridge and loopback-publish isolation. Keep rejecting every other
  # table so an independently managed nftables ruleset cannot pass unnoticed.
  extra=$(nft list tables 2>/dev/null | awk '
    $0 != "table ip filter" && $0 != "table ip nat" && $0 != "table ip raw" &&
    $0 != "table ip6 filter" && $0 != "table ip6 nat" && $0 != "table ip6 raw" {print}')
  [ -z "$extra" ] || die "unrecognized nftables tables require manual review"
  pass "no unrecognized nftables table exists"
}

check_filter_rules() {
  local command_name=$1 bad
  bad=$($command_name-save -t filter | awk '
    /^:/ {name=$1; sub(/^:/,"",name); if (name !~ /^(INPUT|FORWARD|OUTPUT|DOCKER.*|VEINFIN-HOST-IN|VEINFIN-DOCKER)$/) bad=1; next}
    /^-A / {
      chain=$2
      if (chain ~ /^(DOCKER.*|VEINFIN-HOST-IN|VEINFIN-DOCKER)$/) next
      if (chain=="INPUT" && $0=="-A INPUT -j VEINFIN-HOST-IN") next
      if (chain=="FORWARD" && ($0=="-A FORWARD -j DOCKER-USER" || $0=="-A FORWARD -j DOCKER-FORWARD")) next
      bad=1
    }
    END {if (bad) print "bad"}')
  [ -z "$bad" ] || die "unrecognized non-Docker filter rules require manual review"
}

check_docker_runtime() {
  local require_empty=${1:-false}
  systemctl is-active --quiet docker.service || die "Docker service is not active"
  docker info >/dev/null 2>&1 || die "Docker daemon is unavailable"
  if [ "$require_empty" = true ]; then
    [ -z "$(docker ps -aq)" ] || die "containers exist; firewall apply must precede deployment"
  fi
  for command_name in iptables ip6tables; do
    "$command_name" -w -n -L DOCKER-USER >/dev/null 2>&1 || die "$command_name DOCKER-USER chain is missing"
  done
  if ss -H -lnt 'sport = :2375 or sport = :2376' | grep -q .; then die "Docker TCP API port 2375 or 2376 is listening"; fi
  pass "Docker is active, Unix-socket-only, and exposes DOCKER-USER for IPv4 and IPv6"
}

preaudit() {
  local require_empty=${1:-false}
  require_commands
  check_platform
  check_firewall_managers
  check_nft_tables
  check_filter_rules iptables
  check_filter_rules ip6tables
  check_docker_runtime "$require_empty"
  pass "no conflicting non-Docker firewall policy was found"
}

derive_ipv6_lan_prefixes() {
  ip -6 route show dev "$EXTERNAL_INTERFACE" proto kernel 2>/dev/null | awk '$1 != "default" && $1 != "unreachable" && $1 != "prohibit" && $1 != "blackhole" {print $1}' | sort -u
}

append_bridge_pairs() {
  local action=$1
  printf '%s\n' \
    "-A $DOCKER_CHAIN -i docker0 -o docker0 -j $action" \
    "-A $DOCKER_CHAIN -i docker0 -o br+ -j $action" \
    "-A $DOCKER_CHAIN -i br+ -o docker0 -j $action" \
    "-A $DOCKER_CHAIN -i br+ -o br+ -j $action"
}

render_rules() {
  local family=$1 include_host_jump=${2:-true} include_docker_jump=${3:-true}
  local cidr port prefix
  local -a cidrs ports
  printf '*filter\n'
  printf ':%s - [0:0]\n' "$HOST_CHAIN"
  printf ':%s - [0:0]\n' "$DOCKER_CHAIN"
  printf -- '-F %s\n-F %s\n' "$HOST_CHAIN" "$DOCKER_CHAIN"
  [ "$include_host_jump" = true ] && printf -- '-I INPUT 1 -j %s\n' "$HOST_CHAIN"
  [ "$include_docker_jump" = true ] && printf -- '-I DOCKER-USER 1 -j %s\n' "$DOCKER_CHAIN"

  printf -- '-A %s -i lo -j ACCEPT\n' "$HOST_CHAIN"
  printf -- '-A %s -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT\n' "$HOST_CHAIN"
  if [ "$family" = 4 ]; then
    printf -- '-A %s -p icmp -j ACCEPT\n' "$HOST_CHAIN"
    printf -- '-A %s -p udp --sport 67 --dport 68 -j ACCEPT\n' "$HOST_CHAIN"
    IFS=, read -r -a cidrs <<<"$MANAGEMENT_ALLOWED_CIDRS"
    for cidr in "${cidrs[@]}"; do printf -- '-A %s -p tcp -s %s --dport %s -m conntrack --ctstate NEW -j ACCEPT\n' "$HOST_CHAIN" "$cidr" "$SSH_PORT"; done
  else
    printf -- '-A %s -p ipv6-icmp -j ACCEPT\n' "$HOST_CHAIN"
    printf -- '-A %s -p udp --sport 547 --dport 546 -j ACCEPT\n' "$HOST_CHAIN"
    if [ -n "$MANAGEMENT_ALLOWED_IPV6_CIDRS" ]; then
      IFS=, read -r -a cidrs <<<"$MANAGEMENT_ALLOWED_IPV6_CIDRS"
      for cidr in "${cidrs[@]}"; do printf -- '-A %s -p tcp -s %s --dport %s -m conntrack --ctstate NEW -j ACCEPT\n' "$HOST_CHAIN" "$cidr" "$SSH_PORT"; done
    fi
  fi
  printf -- '-A %s -j DROP\n' "$HOST_CHAIN"

  printf -- '-A %s -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT\n' "$DOCKER_CHAIN"
  append_bridge_pairs RETURN
  if [ "$family" = 4 ]; then
    IFS=, read -r -a cidrs <<<"$PROTECTED_LAN_CIDRS"
    for cidr in "${cidrs[@]}"; do
      printf -- '-A %s -i docker0 -d %s -j DROP\n' "$DOCKER_CHAIN" "$cidr"
      printf -- '-A %s -i br+ -d %s -j DROP\n' "$DOCKER_CHAIN" "$cidr"
    done
  else
    while IFS= read -r prefix; do
      [ -n "$prefix" ] || continue
      printf -- '-A %s -i docker0 -d %s -j DROP\n' "$DOCKER_CHAIN" "$prefix"
      printf -- '-A %s -i br+ -d %s -j DROP\n' "$DOCKER_CHAIN" "$prefix"
    done < <(derive_ipv6_lan_prefixes)
  fi
  printf -- '-A %s -i docker0 -j ACCEPT\n-A %s -i br+ -j ACCEPT\n' "$DOCKER_CHAIN" "$DOCKER_CHAIN"
  printf -- '-A %s -o docker0 -p tcp -m multiport --dports 2375,2376 -j DROP\n' "$DOCKER_CHAIN"
  printf -- '-A %s -o br+ -p tcp -m multiport --dports 2375,2376 -j DROP\n' "$DOCKER_CHAIN"
  if [ "$ENABLE_PUBLIC_HTTPS" = true ]; then
    printf -- '-A %s -o docker0 -p tcp --dport 443 -j ACCEPT\n-A %s -o br+ -p tcp --dport 443 -j ACCEPT\n' "$DOCKER_CHAIN" "$DOCKER_CHAIN"
  fi
  if [ "$ENABLE_MANAGEMENT_PORTS" = true ]; then
    IFS=, read -r -a ports <<<"$MANAGEMENT_TCP_PORTS"
    if [ "$family" = 4 ]; then
      IFS=, read -r -a cidrs <<<"$MANAGEMENT_ALLOWED_CIDRS"
      for cidr in "${cidrs[@]}"; do for port in "${ports[@]}"; do
        printf -- '-A %s -o docker0 -p tcp -s %s --dport %s -j ACCEPT\n' "$DOCKER_CHAIN" "$cidr" "$port"
        printf -- '-A %s -o br+ -p tcp -s %s --dport %s -j ACCEPT\n' "$DOCKER_CHAIN" "$cidr" "$port"
      done; done
    elif [ -n "$MANAGEMENT_ALLOWED_IPV6_CIDRS" ]; then
      IFS=, read -r -a cidrs <<<"$MANAGEMENT_ALLOWED_IPV6_CIDRS"
      for cidr in "${cidrs[@]}"; do for port in "${ports[@]}"; do
        printf -- '-A %s -o docker0 -p tcp -s %s --dport %s -j ACCEPT\n' "$DOCKER_CHAIN" "$cidr" "$port"
        printf -- '-A %s -o br+ -p tcp -s %s --dport %s -j ACCEPT\n' "$DOCKER_CHAIN" "$cidr" "$port"
      done; done
    fi
  fi
  printf -- '-A %s -o docker0 -j DROP\n-A %s -o br+ -j DROP\n' "$DOCKER_CHAIN" "$DOCKER_CHAIN"
  printf -- '-A %s -j RETURN\nCOMMIT\n' "$DOCKER_CHAIN"
}

jump_is_first() {
  local command_name=$1 parent=$2 child=$3 first
  first=$($command_name -w -S "$parent" | awk '$1=="-A" {print; exit}')
  [ "$first" = "-A $parent -j $child" ]
}

jump_count() {
  local command_name=$1 parent=$2 child=$3
  "$command_name" -w -S "$parent" | awk -v expected="-A $parent -j $child" '$0==expected {n++} END {print n+0}'
}

apply_family() {
  local family=$1 command_name restore_command rules_file include_host=true include_docker=true count
  if [ "$family" = 4 ]; then command_name=iptables; restore_command=iptables-restore; else command_name=ip6tables; restore_command=ip6tables-restore; fi
  if "$command_name" -w -n -L "$HOST_CHAIN" >/dev/null 2>&1; then
    count=$(jump_count "$command_name" INPUT "$HOST_CHAIN")
    [ "$count" -le 1 ] || die "$command_name host jump is duplicated"
    [ "$count" -eq 0 ] || include_host=false
  fi
  if "$command_name" -w -n -L "$DOCKER_CHAIN" >/dev/null 2>&1; then
    count=$(jump_count "$command_name" DOCKER-USER "$DOCKER_CHAIN")
    [ "$count" -le 1 ] || die "$command_name Docker jump is duplicated"
    [ "$count" -eq 0 ] || include_docker=false
  fi
  rules_file=$(mktemp /run/veinfin-rules.XXXXXX)
  ACTIVE_TEMP=$rules_file
  chmod 0600 "$rules_file"
  render_rules "$family" "$include_host" "$include_docker" >"$rules_file"
  "$restore_command" --test --noflush <"$rules_file"
  "$restore_command" --noflush <"$rules_file"
  rm -f -- "$rules_file"; ACTIVE_TEMP=
}

runtime_apply() {
  local config_file=$1
  load_config "$config_file"
  validate_config
  wait_for_default_route
  detect_network
  check_protected_route
  iptables -w -n -L DOCKER-USER >/dev/null 2>&1 || die "IPv4 DOCKER-USER chain is missing"
  ip6tables -w -n -L DOCKER-USER >/dev/null 2>&1 || die "IPv6 DOCKER-USER chain is missing"
  install -d -m 0755 /run/lock
  (
    exec 9>"$LOCK_PATH"
    flock -x 9
    apply_family 4
    apply_family 6
  )
  pass "VeinFin IPv4 and IPv6 rules are applied"
}

wait_for_default_route() {
  local attempt count
  attempt=0
  while [ "$attempt" -lt 30 ]; do
    count=$(ip -4 route show default | awk '$1 == "default" {n++} END {print n+0}')
    [ "$count" -eq 1 ] && return 0
    attempt=$((attempt + 1))
    sleep 1
  done
  die "exactly one IPv4 default route did not become available within 30 seconds"
}

canonical_config() {
  cat <<EOF
# Managed by VeinFin. Root-readable host-local firewall configuration.
MANAGEMENT_ALLOWED_CIDRS=$MANAGEMENT_ALLOWED_CIDRS
MANAGEMENT_ALLOWED_IPV6_CIDRS=$MANAGEMENT_ALLOWED_IPV6_CIDRS
PROTECTED_LAN_CIDRS=$PROTECTED_LAN_CIDRS
SSH_PORT=$SSH_PORT
ENABLE_PUBLIC_HTTPS=$ENABLE_PUBLIC_HTTPS
ENABLE_MANAGEMENT_PORTS=$ENABLE_MANAGEMENT_PORTS
MANAGEMENT_TCP_PORTS=$MANAGEMENT_TCP_PORTS
EOF
}

service_content() {
  cat <<'EOF'
# Managed by VeinFin.
[Unit]
Description=VeinFin host and Docker firewall
Wants=network-online.target docker.service
After=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/veinfin-firewall --runtime-apply --config /etc/veinfin/firewall.conf
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

dropin_content() {
  cat <<'EOF'
# Managed by VeinFin. Reapply after Docker recreates its chains.
[Service]
ExecStartPost=/usr/local/sbin/veinfin-firewall --runtime-apply --config /etc/veinfin/firewall.conf
EOF
}

atomic_install_stream() {
  local target=$1 mode=$2 directory
  directory=$(dirname "$target")
  install -d -m 0755 "$directory"
  ACTIVE_TEMP=$(mktemp "$directory/.veinfin.tmp.XXXXXX")
  chmod "$mode" "$ACTIVE_TEMP"
  cat >"$ACTIVE_TEMP"
  chown root:root "$ACTIVE_TEMP"
  mv -f "$ACTIVE_TEMP" "$target"
  ACTIVE_TEMP=
}

path_is_owned() {
  local path=$1
  [ ! -e "$path" ] || { [ -f "$path" ] && [ ! -L "$path" ] && grep -q 'Managed by VeinFin' "$path"; }
}

check_install_paths() {
  local path
  for path in "$CONFIG_PATH" "$INSTALL_PATH" "$SERVICE_PATH" "$DOCKER_DROPIN_PATH"; do
    path_is_owned "$path" || die "refusing to replace an unowned path: $path"
  done
}

snapshot_state() {
  local directory=$1 path name
  umask 077
  iptables-save >"$directory/iptables.v4"
  ip6tables-save >"$directory/iptables.v6"
  chmod 0600 "$directory/iptables.v4" "$directory/iptables.v6"
  : >"$directory/files.manifest"
  for path in "$CONFIG_PATH" "$INSTALL_PATH" "$SERVICE_PATH" "$DOCKER_DROPIN_PATH"; do
    name=$(printf '%s' "$path" | tr '/' '_')
    if [ -f "$path" ] && [ ! -L "$path" ]; then
      cp -p "$path" "$directory/$name"
      printf 'present %s %s\n' "$path" "$name" >>"$directory/files.manifest"
    else
      printf 'absent %s %s\n' "$path" "$name" >>"$directory/files.manifest"
    fi
  done
  {
    systemctl is-enabled --quiet veinfin-firewall.service 2>/dev/null && printf 'enabled\n' || printf 'disabled\n'
    systemctl is-active --quiet veinfin-firewall.service 2>/dev/null && printf 'active\n' || printf 'inactive\n'
  } >"$directory/service.state"
  chmod 0600 "$directory/files.manifest" "$directory/service.state"
}

install_persistence() {
  canonical_config | atomic_install_stream "$CONFIG_PATH" 0600
  atomic_install_stream "$INSTALL_PATH" 0755 <"${BASH_SOURCE[0]}"
  service_content | atomic_install_stream "$SERVICE_PATH" 0644
  dropin_content | atomic_install_stream "$DOCKER_DROPIN_PATH" 0644
  systemctl daemon-reload
}

schedule_rollback() {
  local directory=$1
  [ ! -e "$ROLLBACK_POINTER" ] || die "an earlier firewall rollback is still pending"
  printf '%s\n' "$directory" | atomic_install_stream "$ROLLBACK_POINTER" 0600
  systemd-run --quiet --unit=veinfin-firewall-rollback --on-active=5m "$INSTALL_PATH" --rollback --config "$directory"
  pass "five-minute automatic rollback is armed"
}

cancel_rollback() {
  discard_rollback_state
  pass "automatic rollback is cancelled after successful verification"
}

discard_rollback_state() {
  local directory
  [ -f "$ROLLBACK_POINTER" ] || return 0
  directory=$(head -n 1 "$ROLLBACK_POINTER")
  case "$directory" in /run/veinfin-firewall-rollback.*) ;; *) die "invalid rollback state" ;; esac
  systemctl stop veinfin-firewall-rollback.timer 2>/dev/null || true
  systemctl stop veinfin-firewall-rollback.service 2>/dev/null || true
  systemctl reset-failed veinfin-firewall-rollback.service 2>/dev/null || true
  rm -f -- "$ROLLBACK_POINTER"
  if [ -d "$directory" ]; then find "$directory" -depth -delete; fi
}

restore_files() {
  local directory=$1 state path name target_dir
  while read -r state path name; do
    target_dir=$(dirname "$path")
    if [ "$state" = present ]; then
      install -d -m 0755 "$target_dir"
      cp -p "$directory/$name" "$path"
    else
      rm -f -- "$path"
    fi
  done <"$directory/files.manifest"
}

run_rollback() {
  local directory=${1:-}
  require_root "rollback"
  case "$directory" in /run/veinfin-firewall-rollback.*) ;; *) die "invalid rollback directory" ;; esac
  [ -f "$directory/iptables.v4" ] && [ -f "$directory/iptables.v6" ] || die "rollback snapshots are missing"
  systemctl stop veinfin-firewall-rollback.timer 2>/dev/null || true
  systemctl disable --now veinfin-firewall.service >/dev/null 2>&1 || true
  iptables-restore <"$directory/iptables.v4"
  ip6tables-restore <"$directory/iptables.v6"
  restore_files "$directory"
  systemctl daemon-reload
  if grep -qx enabled "$directory/service.state"; then systemctl enable veinfin-firewall.service >/dev/null; fi
  if grep -qx active "$directory/service.state"; then systemctl start veinfin-firewall.service; fi
  rm -f -- "$ROLLBACK_POINTER"
  warn "previous IPv4/IPv6 rules and persistence files were restored"
  find "$directory" -depth -delete
}

verify_chain() {
  local command_name=$1 parent=$2 child=$3
  "$command_name" -w -n -L "$child" >/dev/null 2>&1 || die "$command_name chain is missing: $child"
  [ "$(jump_count "$command_name" "$parent" "$child")" -eq 1 ] || die "$command_name jump is missing or duplicated: $parent to $child"
  jump_is_first "$command_name" "$parent" "$child" || die "$command_name jump is not first: $parent to $child"
}

verify_policy_rules() {
  local command_name=$1 family=$2 specs cidr
  local -a cidrs ports
  specs=$($command_name -w -S "$HOST_CHAIN"; $command_name -w -S "$DOCKER_CHAIN")
  "$command_name" -w -C "$HOST_CHAIN" -i lo -j ACCEPT >/dev/null 2>&1 || die "$command_name loopback host rule is missing"
  "$command_name" -w -C "$HOST_CHAIN" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT >/dev/null 2>&1 || die "$command_name established host rule is missing"
  "$command_name" -w -C "$HOST_CHAIN" -j DROP >/dev/null 2>&1 || die "$command_name host default drop is missing"
  "$command_name" -w -C "$DOCKER_CHAIN" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT >/dev/null 2>&1 || die "$command_name established Docker rule is missing"
  "$command_name" -w -C "$DOCKER_CHAIN" -i br+ -o br+ -j RETURN >/dev/null 2>&1 || die "$command_name Docker-internal return rule is missing"
  "$command_name" -w -C "$DOCKER_CHAIN" -i br+ -j ACCEPT >/dev/null 2>&1 || die "$command_name container outbound rule is missing"
  "$command_name" -w -C "$DOCKER_CHAIN" -o br+ -p tcp -m multiport --dports 2375,2376 -j DROP >/dev/null 2>&1 || die "$command_name Docker API deny is missing"
  "$command_name" -w -C "$DOCKER_CHAIN" -o br+ -j DROP >/dev/null 2>&1 || die "$command_name Docker default deny is missing"
  if [ "$family" = 4 ]; then
    "$command_name" -w -C "$HOST_CHAIN" -p icmp -j ACCEPT >/dev/null 2>&1 || die "IPv4 ICMP host rule is missing"
    "$command_name" -w -C "$HOST_CHAIN" -p udp --sport 67 --dport 68 -j ACCEPT >/dev/null 2>&1 || die "IPv4 DHCP host rule is missing"
    IFS=, read -r -a cidrs <<<"$MANAGEMENT_ALLOWED_CIDRS"
    for cidr in "${cidrs[@]}"; do
      "$command_name" -w -C "$HOST_CHAIN" -p tcp -s "$cidr" --dport "$SSH_PORT" -m conntrack --ctstate NEW -j ACCEPT >/dev/null 2>&1 || die "IPv4 SSH allowlist rule is missing"
    done
    IFS=, read -r -a cidrs <<<"$PROTECTED_LAN_CIDRS"
    for cidr in "${cidrs[@]}"; do
      "$command_name" -w -C "$DOCKER_CHAIN" -i docker0 -d "$cidr" -j DROP >/dev/null 2>&1 || die "IPv4 protected-LAN Docker rule is missing"
      "$command_name" -w -C "$DOCKER_CHAIN" -i br+ -d "$cidr" -j DROP >/dev/null 2>&1 || die "IPv4 protected-LAN Docker rule is missing"
    done
  else
    "$command_name" -w -C "$HOST_CHAIN" -p ipv6-icmp -j ACCEPT >/dev/null 2>&1 || die "IPv6 ICMP host rule is missing"
    "$command_name" -w -C "$HOST_CHAIN" -p udp --sport 547 --dport 546 -j ACCEPT >/dev/null 2>&1 || die "IPv6 DHCP host rule is missing"
    if [ -n "$MANAGEMENT_ALLOWED_IPV6_CIDRS" ]; then
      IFS=, read -r -a cidrs <<<"$MANAGEMENT_ALLOWED_IPV6_CIDRS"
      for cidr in "${cidrs[@]}"; do
        "$command_name" -w -C "$HOST_CHAIN" -p tcp -s "$cidr" --dport "$SSH_PORT" -m conntrack --ctstate NEW -j ACCEPT >/dev/null 2>&1 || die "IPv6 SSH allowlist rule is missing"
      done
    elif printf '%s\n' "$specs" | grep -q -- "--dport $SSH_PORT .* -j ACCEPT"; then
      die "IPv6 SSH is unexpectedly allowed"
    fi
  fi
  if [ "$ENABLE_PUBLIC_HTTPS" = true ]; then
    "$command_name" -w -C "$DOCKER_CHAIN" -o br+ -p tcp --dport 443 -j ACCEPT >/dev/null 2>&1 || die "$command_name public HTTPS rule is missing"
  elif printf '%s\n' "$specs" | grep -q -- '--dport 443 -j ACCEPT'; then die "$command_name unexpectedly permits public HTTPS"; fi
  if [ "$ENABLE_MANAGEMENT_PORTS" = false ]; then
    local port
    IFS=, read -r -a ports <<<"$MANAGEMENT_TCP_PORTS"
    for port in "${ports[@]}"; do
      if printf '%s\n' "$specs" | grep -q -- "--dport $port .* -j ACCEPT"; then die "$command_name unexpectedly permits a management port"; fi
    done
  elif [ "$family" = 4 ]; then
    IFS=, read -r -a cidrs <<<"$MANAGEMENT_ALLOWED_CIDRS"
    IFS=, read -r -a ports <<<"$MANAGEMENT_TCP_PORTS"
    for cidr in "${cidrs[@]}"; do for port in "${ports[@]}"; do
      "$command_name" -w -C "$DOCKER_CHAIN" -o br+ -p tcp -s "$cidr" --dport "$port" -j ACCEPT >/dev/null 2>&1 || die "$command_name allowlisted management rule is missing"
    done; done
  elif [ -n "$MANAGEMENT_ALLOWED_IPV6_CIDRS" ]; then
    IFS=, read -r -a cidrs <<<"$MANAGEMENT_ALLOWED_IPV6_CIDRS"
    IFS=, read -r -a ports <<<"$MANAGEMENT_TCP_PORTS"
    for cidr in "${cidrs[@]}"; do for port in "${ports[@]}"; do
      "$command_name" -w -C "$DOCKER_CHAIN" -o br+ -p tcp -s "$cidr" --dport "$port" -j ACCEPT >/dev/null 2>&1 || die "$command_name allowlisted IPv6 management rule is missing"
    done; done
  fi
}

verify_files() {
  local mode path
  [ -f "$CONFIG_PATH" ] && [ ! -L "$CONFIG_PATH" ] || die "installed configuration is missing or unsafe"
  mode=$(stat -c '%a' "$CONFIG_PATH"); [ "$mode" = 600 ] || die "installed configuration mode is not 0600"
  mode=$(stat -c '%a' "$INSTALL_PATH"); [ "$mode" = 755 ] || die "installed script mode is not 0755"
  mode=$(stat -c '%a' "$SERVICE_PATH"); [ "$mode" = 644 ] || die "systemd unit mode is not 0644"
  mode=$(stat -c '%a' "$DOCKER_DROPIN_PATH"); [ "$mode" = 644 ] || die "Docker drop-in mode is not 0644"
  for path in "$CONFIG_PATH" "$INSTALL_PATH" "$SERVICE_PATH" "$DOCKER_DROPIN_PATH"; do
    [ "$(stat -c '%u' "$path")" = 0 ] || die "persistence artifact is not root-owned: $path"
  done
  systemctl is-enabled --quiet veinfin-firewall.service || die "firewall service is not enabled"
  systemctl is-active --quiet veinfin-firewall.service || die "firewall service is not active"
  grep -q 'ExecStartPost=.*/usr/local/sbin/veinfin-firewall --runtime-apply' "$DOCKER_DROPIN_PATH" || die "Docker restart hook is missing"
  pass "persistence files, permissions, service, and Docker restart hook are valid"
}

verify_active() {
  load_config "$CONFIG_PATH"
  validate_config
  detect_network
  check_protected_route
  check_ssh_peer
  verify_files
  verify_chain iptables INPUT "$HOST_CHAIN"
  verify_chain iptables DOCKER-USER "$DOCKER_CHAIN"
  verify_chain ip6tables INPUT "$HOST_CHAIN"
  verify_chain ip6tables DOCKER-USER "$DOCKER_CHAIN"
  verify_policy_rules iptables 4
  verify_policy_rules ip6tables 6
  if ss -H -lnt 'sport = :2375 or sport = :2376' | grep -q .; then die "Docker TCP API port 2375 or 2376 is listening"; fi
  pass "active IPv4/IPv6 host and Docker policy is valid"
}

run_check() {
  local config_file=${1:-}
  if [ "$EUID" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "--check requires root access for read-only rule inspection"
    if [ -n "$config_file" ]; then
      exec sudo -n --preserve-env=SSH_CONNECTION "$0" --check --config "$config_file"
    else
      exec sudo -n --preserve-env=SSH_CONNECTION "$0" --check
    fi
  fi
  preaudit
  if [ -n "$config_file" ]; then
    load_config "$config_file"; validate_config; detect_network; check_protected_route; check_ssh_peer
    pass "configuration, route, and SSH safety checks passed"
  elif [ -f "$CONFIG_PATH" ]; then
    load_config "$CONFIG_PATH"; validate_config; detect_network; check_protected_route; check_ssh_peer
    pass "installed configuration, route, and SSH safety checks passed"
  else
    warn "no config supplied or installed; policy values and SSH allowlisting were not assessed"
  fi
  info "Read-only check complete; no firewall state was changed"
}

run_apply() {
  local config_file=$1 rollback_dir
  require_root "--apply"
  preaudit true
  load_config "$config_file"; validate_config; detect_network; check_protected_route; check_ssh_peer
  check_install_paths
  rollback_dir=$(mktemp -d /run/veinfin-firewall-rollback.XXXXXX)
  chmod 0700 "$rollback_dir"
  snapshot_state "$rollback_dir"
  install_persistence
  schedule_rollback "$rollback_dir"
  runtime_apply "$CONFIG_PATH"
  systemctl enable veinfin-firewall.service >/dev/null
  systemctl start veinfin-firewall.service
  verify_active
  info "Policy applied; open a second SSH session and run sudo $INSTALL_PATH --verify before rollback expires"
}

validate_public_https_transition() {
  local config_file=$1
  local old_management old_management6 old_lan old_ssh old_https old_management_enabled old_ports
  [ -f "$CONFIG_PATH" ] && [ ! -L "$CONFIG_PATH" ] || die "installed firewall configuration is missing"
  load_config "$CONFIG_PATH"; validate_config
  old_management=$MANAGEMENT_ALLOWED_CIDRS
  old_management6=$MANAGEMENT_ALLOWED_IPV6_CIDRS
  old_lan=$PROTECTED_LAN_CIDRS
  old_ssh=$SSH_PORT
  old_https=$ENABLE_PUBLIC_HTTPS
  old_management_enabled=$ENABLE_MANAGEMENT_PORTS
  old_ports=$MANAGEMENT_TCP_PORTS
  load_config "$config_file"; validate_config
  [ "$ENABLE_PUBLIC_HTTPS" = true ] || die "public HTTPS update must enable TCP 443"
  [ "$old_https" = false ] || [ "$old_https" = true ] || die "installed public HTTPS state is invalid"
  [ "$MANAGEMENT_ALLOWED_CIDRS" = "$old_management" ] &&
    [ "$MANAGEMENT_ALLOWED_IPV6_CIDRS" = "$old_management6" ] &&
    [ "$PROTECTED_LAN_CIDRS" = "$old_lan" ] &&
    [ "$SSH_PORT" = "$old_ssh" ] &&
    [ "$ENABLE_MANAGEMENT_PORTS" = "$old_management_enabled" ] &&
    [ "$MANAGEMENT_TCP_PORTS" = "$old_ports" ] ||
    die "public HTTPS update may not change any other firewall value"
  pass "public HTTPS is the only requested firewall policy change"
}

run_update_public_https() {
  local config_file=$1 rollback_dir candidate
  require_root "--update-public-https"
  preaudit
  verify_active
  validate_public_https_transition "$config_file"
  candidate=$(mktemp /run/veinfin-firewall-config.XXXXXX)
  ACTIVE_TEMP=$candidate; chmod 0600 "$candidate"; canonical_config >"$candidate"
  if cmp -s "$candidate" "$CONFIG_PATH"; then
    rm -f -- "$candidate"; ACTIVE_TEMP=
    verify_active
    pass "public HTTPS firewall policy is already active"
    return 0
  fi
  rm -f -- "$candidate"; ACTIVE_TEMP=
  check_install_paths
  rollback_dir=$(mktemp -d /run/veinfin-firewall-rollback.XXXXXX)
  chmod 0700 "$rollback_dir"
  snapshot_state "$rollback_dir"
  install_persistence
  schedule_rollback "$rollback_dir"
  runtime_apply "$CONFIG_PATH"
  systemctl enable veinfin-firewall.service >/dev/null
  systemctl start veinfin-firewall.service
  verify_active
  info "Public HTTPS policy applied; verify from a separate SSH session before rollback expires"
}

validate_management_transition() {
  local config_file=$1
  local old_management old_management6 old_lan old_ssh old_https old_management_enabled old_ports
  [ -f "$CONFIG_PATH" ] && [ ! -L "$CONFIG_PATH" ] || die "installed firewall configuration is missing"
  load_config "$CONFIG_PATH"; validate_config
  old_management=$MANAGEMENT_ALLOWED_CIDRS
  old_management6=$MANAGEMENT_ALLOWED_IPV6_CIDRS
  old_lan=$PROTECTED_LAN_CIDRS
  old_ssh=$SSH_PORT
  old_https=$ENABLE_PUBLIC_HTTPS
  old_management_enabled=$ENABLE_MANAGEMENT_PORTS
  old_ports=$MANAGEMENT_TCP_PORTS
  load_config "$config_file"; validate_config
  [ "$ENABLE_MANAGEMENT_PORTS" = true ] || die "management update must enable management ports"
  [ "$old_management_enabled" = false ] || [ "$old_management_enabled" = true ] || die "installed management-port state is invalid"
  [ "$MANAGEMENT_ALLOWED_CIDRS" = "$old_management" ] &&
    [ "$MANAGEMENT_ALLOWED_IPV6_CIDRS" = "$old_management6" ] &&
    [ "$PROTECTED_LAN_CIDRS" = "$old_lan" ] &&
    [ "$SSH_PORT" = "$old_ssh" ] &&
    [ "$ENABLE_PUBLIC_HTTPS" = "$old_https" ] &&
    [ "$MANAGEMENT_TCP_PORTS" = "$old_ports" ] ||
    die "management update may not change any other firewall value"
  pass "management exposure is the only requested firewall policy change"
}

run_update_management() {
  local config_file=$1 rollback_dir candidate
  require_root "--update-management"
  preaudit
  verify_active
  validate_management_transition "$config_file"
  candidate=$(mktemp /run/veinfin-firewall-config.XXXXXX)
  ACTIVE_TEMP=$candidate; chmod 0600 "$candidate"; canonical_config >"$candidate"
  if cmp -s "$candidate" "$CONFIG_PATH"; then
    rm -f -- "$candidate"; ACTIVE_TEMP=
    verify_active
    pass "management firewall policy is already active"
    return 0
  fi
  rm -f -- "$candidate"; ACTIVE_TEMP=
  check_install_paths
  rollback_dir=$(mktemp -d /run/veinfin-firewall-rollback.XXXXXX)
  chmod 0700 "$rollback_dir"
  snapshot_state "$rollback_dir"
  install_persistence
  schedule_rollback "$rollback_dir"
  runtime_apply "$CONFIG_PATH"
  systemctl enable veinfin-firewall.service >/dev/null
  systemctl start veinfin-firewall.service
  verify_active
  info "Allowlisted management policy applied; verify from a separate SSH session before rollback expires"
}

run_verify() {
  require_root "--verify"
  preaudit
  verify_active
  cancel_rollback
  pass "firewall verification succeeded"
}

delete_all_jumps() {
  local command_name=$1 parent=$2 child=$3
  while "$command_name" -w -C "$parent" -j "$child" >/dev/null 2>&1; do "$command_name" -w -D "$parent" -j "$child"; done
}

remove_family() {
  local command_name=$1
  delete_all_jumps "$command_name" INPUT "$HOST_CHAIN"
  delete_all_jumps "$command_name" DOCKER-USER "$DOCKER_CHAIN"
  for chain in "$HOST_CHAIN" "$DOCKER_CHAIN"; do
    if "$command_name" -w -n -L "$chain" >/dev/null 2>&1; then "$command_name" -w -F "$chain"; "$command_name" -w -X "$chain"; fi
  done
}

run_remove() {
  local path
  require_root "--remove"
  for path in "$CONFIG_PATH" "$INSTALL_PATH" "$SERVICE_PATH" "$DOCKER_DROPIN_PATH"; do
    path_is_owned "$path" || die "refusing to remove an unowned path: $path"
  done
  discard_rollback_state
  systemctl disable --now veinfin-firewall.service >/dev/null 2>&1 || true
  remove_family iptables
  remove_family ip6tables
  for path in "$DOCKER_DROPIN_PATH" "$SERVICE_PATH" "$CONFIG_PATH"; do [ ! -e "$path" ] || rm -f -- "$path"; done
  systemctl daemon-reload
  rm -f -- "$INSTALL_PATH"
  pass "VeinFin-owned firewall rules and persistence were removed"
}

if [ "${VEINFIN_FIREWALL_LIBRARY_ONLY:-0}" = 1 ]; then
  return 0 2>/dev/null || exit 0
fi

mode= config_file=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|--check|--apply|--update-public-https|--update-management|--verify|--remove|--runtime-apply|--rollback)
      [ -z "$mode" ] || { usage; exit 2; }
      mode=$1; shift ;;
    --config)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      config_file=$2; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

case "$mode" in
  --help) [ -z "$config_file" ] || { usage; exit 2; }; usage ;;
  --check) run_check "$config_file" ;;
  --apply) [ -n "$config_file" ] || die "--apply requires --config FILE"; run_apply "$config_file" ;;
  --update-public-https) [ -n "$config_file" ] || die "--update-public-https requires --config FILE"; run_update_public_https "$config_file" ;;
  --update-management) [ -n "$config_file" ] || die "--update-management requires --config FILE"; run_update_management "$config_file" ;;
  --verify) [ -z "$config_file" ] || { usage; exit 2; }; run_verify ;;
  --remove) [ -z "$config_file" ] || { usage; exit 2; }; run_remove ;;
  --runtime-apply) require_root "--runtime-apply"; [ -n "$config_file" ] || die "--runtime-apply requires --config FILE"; runtime_apply "$config_file" ;;
  --rollback) run_rollback "$config_file" ;;
  *) usage; exit 2 ;;
esac
