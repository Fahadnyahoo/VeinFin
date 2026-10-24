#!/usr/bin/env bash
set -u
set -o pipefail

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT=$REPO_ROOT/scripts/host/configure-firewall.sh
TEST_ROOT=$(mktemp -d)
PASSED=0
FAILED=0

cleanup() {
  find "$TEST_ROOT" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

pass() { printf 'PASS: %s\n' "$1"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=$((FAILED + 1)); }
assert_contains() { grep -Fq -- "$2" <<<"$1" && pass "$3" || fail "$3"; }
assert_not_contains() { if grep -Fq -- "$2" <<<"$1"; then fail "$3"; else pass "$3"; fi; }
expect_failure() { local name=$1; shift; if ( "$@" ) >/dev/null 2>&1; then fail "$name"; else pass "$name"; fi; }

if bash -n "$SCRIPT"; then pass 'firewall script has valid Bash syntax'; else fail 'firewall script has valid Bash syntax'; fi
help_output=$($SCRIPT --help 2>&1)
help_status=$?
[ "$help_status" -eq 0 ] && assert_contains "$help_output" 'sudo configure-firewall.sh --apply --config FILE' 'help documents guarded apply' || fail 'help exits successfully'
assert_contains "$help_output" 'sudo configure-firewall.sh --verify' 'help documents separate verification'
assert_contains "$help_output" 'sudo configure-firewall.sh --update-public-https --config FILE' 'help documents guarded live HTTPS update'
assert_contains "$help_output" 'sudo configure-firewall.sh --remove' 'help documents removal'

VEINFIN_FIREWALL_LIBRARY_ONLY=1 source "$SCRIPT"
set +e
# The sourced implementation has its own reporting helpers; restore the test
# counter after importing its unit-testable functions.
pass() { printf 'PASS: %s\n' "$1"; PASSED=$((PASSED + 1)); }

write_config() {
  local path=$1
  shift
  printf '%s\n' \
    'MANAGEMENT_ALLOWED_CIDRS=192.0.2.10/32,192.0.2.11/32' \
    'PROTECTED_LAN_CIDRS=198.51.100.0/24' \
    'SSH_PORT=22' \
    'ENABLE_PUBLIC_HTTPS=false' \
    'ENABLE_MANAGEMENT_PORTS=false' "$@" >"$path"
}

base_config=$TEST_ROOT/base.conf
write_config "$base_config"
if (load_config "$base_config"; validate_config) >/dev/null 2>&1; then pass 'valid generic configuration is accepted'; else fail 'valid generic configuration is accepted'; fi

load_config "$base_config" >/dev/null
if (SSH_CONNECTION='192.0.2.10 41000 198.51.100.20 22'; check_ssh_peer) >/dev/null 2>&1; then pass 'allowlisted active SSH peer is accepted'; else fail 'allowlisted active SSH peer is accepted'; fi
expect_failure 'non-allowlisted active SSH peer is rejected' bash -c "VEINFIN_FIREWALL_LIBRARY_ONLY=1 source '$SCRIPT'; load_config '$base_config'; SSH_CONNECTION='203.0.113.9 41000 198.51.100.20 22'; check_ssh_peer"

invalid_host=$TEST_ROOT/invalid-host.conf
write_config "$invalid_host"
sed 's#192.0.2.10/32#999.0.2.10/32#' "$invalid_host" >"$invalid_host.new" && mv "$invalid_host.new" "$invalid_host"
expect_failure 'invalid management CIDR is rejected' bash -c "VEINFIN_FIREWALL_LIBRARY_ONLY=1 source '$SCRIPT'; load_config '$invalid_host'; validate_config"

invalid_lan=$TEST_ROOT/invalid-lan.conf
write_config "$invalid_lan"
sed 's#198.51.100.0/24#198.51.100.0/99#' "$invalid_lan" >"$invalid_lan.new" && mv "$invalid_lan.new" "$invalid_lan"
expect_failure 'invalid protected LAN CIDR is rejected' bash -c "VEINFIN_FIREWALL_LIBRARY_ONLY=1 source '$SCRIPT'; load_config '$invalid_lan'; validate_config"

invalid_port=$TEST_ROOT/invalid-port.conf
write_config "$invalid_port"
sed 's/SSH_PORT=22/SSH_PORT=70000/' "$invalid_port" >"$invalid_port.new" && mv "$invalid_port.new" "$invalid_port"
expect_failure 'invalid SSH port is rejected' bash -c "VEINFIN_FIREWALL_LIBRARY_ONLY=1 source '$SCRIPT'; load_config '$invalid_port'; validate_config"

invalid_bool=$TEST_ROOT/invalid-bool.conf
write_config "$invalid_bool"
sed 's/ENABLE_PUBLIC_HTTPS=false/ENABLE_PUBLIC_HTTPS=yes/' "$invalid_bool" >"$invalid_bool.new" && mv "$invalid_bool.new" "$invalid_bool"
expect_failure 'invalid exposure flag is rejected' bash -c "VEINFIN_FIREWALL_LIBRARY_ONLY=1 source '$SCRIPT'; load_config '$invalid_bool'; validate_config"

unknown_key=$TEST_ROOT/unknown.conf
write_config "$unknown_key" 'UNSAFE_OPTION=true'
expect_failure 'unknown configuration keys are rejected' bash -c "VEINFIN_FIREWALL_LIBRARY_ONLY=1 source '$SCRIPT'; load_config '$unknown_key'"

missing_key=$TEST_ROOT/missing.conf
grep -v '^SSH_PORT=' "$base_config" >"$missing_key"
expect_failure 'missing required configuration keys are rejected' bash -c "VEINFIN_FIREWALL_LIBRARY_ONLY=1 source '$SCRIPT'; load_config '$missing_key'"

load_config "$base_config" >/dev/null
EXTERNAL_INTERFACE=test0
derive_ipv6_lan_prefixes() { printf '%s\n' '2001:db8:1::/64' 'fe80::/64'; }
rules4=$(render_rules 4)
rules6=$(render_rules 6)

assert_contains "$rules4" '-I INPUT 1 -j VEINFIN-HOST-IN' 'host policy jump is first by construction'
assert_contains "$rules4" '-s 192.0.2.10/32 --dport 22' 'IPv4 SSH is allowlisted'
assert_contains "$rules4" '-A VEINFIN-HOST-IN -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT' 'established host traffic remains permitted'
assert_contains "$rules4" '-A VEINFIN-HOST-IN -j DROP' 'host input has default deny'
assert_contains "$rules4" '-i br+ -d 198.51.100.0/24 -j DROP' 'container initiation into protected IPv4 LAN is denied'
assert_contains "$rules6" '-i br+ -d 2001:db8:1::/64 -j DROP' 'container initiation into connected IPv6 LAN is denied'
assert_contains "$rules4" '-i br+ -j ACCEPT' 'container outbound internet remains permitted after LAN denies'
assert_contains "$rules4" '-i br+ -o br+ -j RETURN' 'Docker-internal forwarding returns to Docker policy'
assert_contains "$rules4" '--dports 2375,2376 -j DROP' 'Docker TCP API forwarding is explicitly denied'
assert_contains "$rules4" '-o br+ -j DROP' 'future Docker-published ingress is denied by default'
assert_not_contains "$rules4" '--dport 443 -j ACCEPT' 'public HTTPS remains closed when disabled'
assert_not_contains "$rules4" '--dport 8080 -j ACCEPT' 'management ports remain closed when disabled'
assert_not_contains "$rules6" '--dport 22 -m conntrack --ctstate NEW -j ACCEPT' 'IPv6 SSH remains blocked without an IPv6 allowlist'
assert_contains "$rules6" '-p ipv6-icmp -j ACCEPT' 'necessary ICMPv6 remains permitted'
assert_contains "$rules4" '--sport 67 --dport 68 -j ACCEPT' 'IPv4 DHCP replies remain permitted'
assert_contains "$rules6" '--sport 547 --dport 546 -j ACCEPT' 'IPv6 DHCP replies remain permitted'

enabled_config=$TEST_ROOT/enabled.conf
write_config "$enabled_config" 'ENABLE_PUBLIC_HTTPS=true' 'ENABLE_MANAGEMENT_PORTS=true'
# Last duplicate must be rejected rather than silently changing policy.
expect_failure 'duplicate exposure flags are rejected' bash -c "VEINFIN_FIREWALL_LIBRARY_ONLY=1 source '$SCRIPT'; load_config '$enabled_config'"
sed -e 's/ENABLE_PUBLIC_HTTPS=false/ENABLE_PUBLIC_HTTPS=true/' -e 's/ENABLE_MANAGEMENT_PORTS=false/ENABLE_MANAGEMENT_PORTS=true/' "$base_config" >"$enabled_config"
load_config "$enabled_config" >/dev/null
enabled_rules=$(render_rules 4)
assert_contains "$enabled_rules" '-o br+ -p tcp --dport 443 -j ACCEPT' 'public HTTPS rule appears only when enabled'
assert_contains "$enabled_rules" '-s 192.0.2.10/32 --dport 8080 -j ACCEPT' 'management ports require an approved source when enabled'

installed_transition=$TEST_ROOT/installed-transition.conf
https_transition=$TEST_ROOT/https-transition.conf
bad_transition=$TEST_ROOT/bad-transition.conf
cp "$base_config" "$installed_transition"
sed 's/ENABLE_PUBLIC_HTTPS=false/ENABLE_PUBLIC_HTTPS=true/' "$base_config" >"$https_transition"
sed -e 's/ENABLE_PUBLIC_HTTPS=false/ENABLE_PUBLIC_HTTPS=true/' -e 's/SSH_PORT=22/SSH_PORT=2222/' "$base_config" >"$bad_transition"
CONFIG_PATH=$installed_transition
if (validate_public_https_transition "$https_transition") >/dev/null 2>&1; then pass 'live update permits only enabling public HTTPS'; else fail 'live update permits only enabling public HTTPS'; fi
expect_failure 'live update rejects unrelated firewall changes' validate_public_https_transition "$bad_transition"
load_config "$base_config" >/dev/null

first=$TEST_ROOT/first.rules
second=$TEST_ROOT/second.rules
render_rules 4 >"$first"
render_rules 4 >"$second"
cmp -s "$first" "$second" && pass 'repeated rule generation is byte-identical' || fail 'repeated rule generation is byte-identical'
repeat_rules=$(render_rules 4 false false)
assert_not_contains "$repeat_rules" '-I INPUT 1' 'existing host jump is not duplicated on repeat apply'
assert_not_contains "$repeat_rules" '-I DOCKER-USER 1' 'existing Docker jump is not duplicated on repeat apply'

fakeiptables-save() {
  cat <<'EOF'
*filter
:INPUT ACCEPT [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]
:DOCKER-USER - [0:0]
-A FORWARD -j DOCKER-USER
COMMIT
EOF
}
if (check_filter_rules fakeiptables) >/dev/null 2>&1; then pass 'known Docker-only base rules pass conflict inspection'; else fail 'known Docker-only base rules pass conflict inspection'; fi
fakeconflict-save() {
  cat <<'EOF'
*filter
:INPUT ACCEPT [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -p tcp --dport 99 -j ACCEPT
COMMIT
EOF
}
expect_failure 'pre-existing non-Docker rules are refused' check_filter_rules fakeconflict

nft_mock_dir=$TEST_ROOT/nft-mock
mkdir -p "$nft_mock_dir"
cat >"$nft_mock_dir/nft" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'table ip filter' 'table ip nat' 'table ip raw' 'table ip6 filter' 'table ip6 nat' 'table ip6 raw'
EOF
chmod +x "$nft_mock_dir/nft"
if (PATH="$nft_mock_dir:$PATH"; check_nft_tables) >/dev/null 2>&1; then pass 'iptables-nft raw tables used by Docker are recognized'; else fail 'iptables-nft raw tables used by Docker are recognized'; fi
cat >"$nft_mock_dir/nft" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'table ip filter' 'table inet unmanaged'
EOF
chmod +x "$nft_mock_dir/nft"
expect_failure 'independently managed nftables tables are refused' bash -c "VEINFIN_FIREWALL_LIBRARY_ONLY=1 source '$SCRIPT'; PATH='$nft_mock_dir':\"\$PATH\"; check_nft_tables"

service=$(service_content)
dropin=$(dropin_content)
assert_contains "$service" 'After=network-online.target docker.service' 'systemd unit orders after Docker without a cycle'
assert_contains "$service" '--runtime-apply --config /etc/veinfin/firewall.conf' 'systemd unit reapplies the installed config'
assert_contains "$dropin" 'ExecStartPost=/usr/local/sbin/veinfin-firewall --runtime-apply' 'Docker restart hook reapplies firewall policy'
script_text=$(<"$SCRIPT")
check_function=$(declare -f run_check)
assert_not_contains "$check_function" 'runtime_apply' 'check mode cannot apply packet-filter rules'
assert_not_contains "$check_function" 'install_persistence' 'check mode cannot install persistence files'
assert_contains "$script_text" 'require_root "--apply"' 'apply has an explicit root requirement'
assert_contains "$script_text" 'require_root "--verify"' 'verify has an explicit root requirement'
assert_contains "$script_text" 'require_root "--remove"' 'remove has an explicit root requirement'
assert_contains "$script_text" 'iptables-save >"$directory/iptables.v4"' 'rollback records exact IPv4 rules'
assert_contains "$script_text" 'ip6tables-save >"$directory/iptables.v6"' 'rollback records exact IPv6 rules'
assert_contains "$script_text" 'iptables-restore <"$directory/iptables.v4"' 'rollback restores exact IPv4 rules'
assert_contains "$script_text" 'systemctl is-active --quiet veinfin-firewall.service' 'rollback records firewall service activity'
assert_contains "$script_text" 'systemctl start veinfin-firewall.service' 'rollback restores firewall service activity'
assert_contains "$script_text" 'systemd-run --quiet --unit=veinfin-firewall-rollback' 'apply arms a timed systemd rollback'
assert_contains "$script_text" 'cancel_rollback' 'verification has an explicit rollback-cancellation path'
assert_contains "$script_text" 'wait_for_default_route' 'runtime reapply waits for DHCP route readiness'
assert_contains "$script_text" 'preaudit true' 'firewall apply still requires an empty Docker runtime'
assert_contains "$script_text" 'run_update_public_https' 'firewall has a guarded deployed-runtime HTTPS transition'
verify_function=$(declare -f run_verify)
assert_not_contains "$verify_function" 'preaudit true' 'firewall verification permits an intended deployed container'

owned=$TEST_ROOT/owned
unowned=$TEST_ROOT/unowned
printf '# Managed by VeinFin.\n' >"$owned"
printf '# unrelated\n' >"$unowned"
path_is_owned "$owned" && pass 'owned persistence artifact is recognized' || fail 'owned persistence artifact is recognized'
if path_is_owned "$unowned"; then fail 'unowned persistence artifact is refused'; else pass 'unowned persistence artifact is refused'; fi

remove_root=$TEST_ROOT/remove
mkdir -p "$remove_root"
CONFIG_PATH=$remove_root/firewall.conf
INSTALL_PATH=$remove_root/veinfin-firewall
SERVICE_PATH=$remove_root/veinfin-firewall.service
DOCKER_DROPIN_PATH=$remove_root/docker-dropin.conf
ROLLBACK_POINTER=$remove_root/rollback.pointer
unrelated=$remove_root/unrelated
for artifact in "$CONFIG_PATH" "$INSTALL_PATH" "$SERVICE_PATH" "$DOCKER_DROPIN_PATH"; do printf '# Managed by VeinFin.\n' >"$artifact"; done
printf 'keep\n' >"$unrelated"
require_root() { :; }
systemctl() { :; }
remove_family() { :; }
if run_remove >/dev/null 2>&1 && [ -f "$unrelated" ] && [ ! -e "$CONFIG_PATH" ] && [ ! -e "$INSTALL_PATH" ] && [ ! -e "$SERVICE_PATH" ] && [ ! -e "$DOCKER_DROPIN_PATH" ]; then
  pass 'remove deletes only marked VeinFin persistence artifacts'
else
  fail 'remove deletes only marked VeinFin persistence artifacts'
fi

assert_not_contains "$script_text" ' -F DOCKER' 'implementation never flushes a Docker-owned chain'
assert_not_contains "$script_text" ' -X DOCKER' 'implementation never deletes a Docker-owned chain'
assert_not_contains "$script_text" 'network.host' 'implementation does not enable host networking'
assert_not_contains "$script_text" '7359 -j ACCEPT' 'Jellyfin discovery is not enabled by firewall policy'

printf '\nTests: %d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
