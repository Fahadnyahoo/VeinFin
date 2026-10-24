#!/usr/bin/env bash
set -u
set -o pipefail

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT=$REPO_ROOT/scripts/deploy/qbittorrent.sh
TEST_ROOT=$(mktemp -d)
PASSED=0
FAILED=0

cleanup_test() { find "$TEST_ROOT" -depth -delete 2>/dev/null || true; }
trap cleanup_test EXIT HUP INT TERM
test_pass() { printf 'PASS: %s\n' "$1"; PASSED=$((PASSED + 1)); }
test_fail() { printf 'FAIL: %s\n' "$1"; FAILED=$((FAILED + 1)); }
assert_contains() { grep -Fq -- "$2" <<<"$1" && test_pass "$3" || test_fail "$3"; }
assert_not_contains() { if grep -Fq -- "$2" <<<"$1"; then test_fail "$3"; else test_pass "$3"; fi; }
expect_failure() { local name=$1; shift; if ( "$@" ) >/dev/null 2>&1; then test_fail "$name"; else test_pass "$name"; fi; }
file_mode() { if stat -c '%a' "$1" >/dev/null 2>&1; then stat -c '%a' "$1"; else stat -f '%Lp' "$1"; fi; }

if bash -n "$SCRIPT"; then test_pass 'deployment script has valid Bash syntax'; else test_fail 'deployment script has valid Bash syntax'; fi
help_output=$($SCRIPT --help 2>&1)
assert_contains "$help_output" 'scripts/deploy/qbittorrent.sh --check' 'help documents check mode'
assert_contains "$help_output" 'pull/start only qBittorrent' 'help limits apply to qBittorrent'
assert_contains "$help_output" 'ssh -N -L 8080:127.0.0.1:8080 user@host' 'help documents a generic loopback tunnel'
assert_contains "$help_output" '--previous-password-file FILE' 'help documents explicit credential rotation input'
if printf '%s\n' "$help_output" | grep -Eq 'PASSWORD=[^[:space:]]+|sha256:[0-9a-f]{64}'; then test_fail 'help output is credential-safe'; else test_pass 'help output is credential-safe'; fi

VEINFIN_QBITTORRENT_LIBRARY_ONLY=1 source "$SCRIPT"
set +e
trap cleanup_test EXIT HUP INT TERM

if validate_loopback_override >/dev/null 2>&1; then test_pass 'committed override is accepted as loopback-only'; else test_fail 'committed override is accepted as loopback-only'; fi

for replacement in '0.0.0.0' '::' '192.0.2.44'; do
  bad_override=$TEST_ROOT/bad-$(printf '%s' "$replacement" | tr ':.' '__').yaml
  sed "s/host_ip: 127.0.0.1/host_ip: $replacement/" "$QBITTORRENT_LOOPBACK_COMPOSE" >"$bad_override"
  QBITTORRENT_LOOPBACK_COMPOSE=$bad_override
  expect_failure "unsafe qBittorrent bind $replacement" validate_loopback_override
done
QBITTORRENT_LOOPBACK_COMPOSE=$REPO_ROOT/compose/qbittorrent-loopback.yaml

peer_override=$TEST_ROOT/peer.yaml
awk '{print} /protocol: tcp/ && !done {print "      - target: 6881\n        published: \"6881\"\n        host_ip: 127.0.0.1\n        protocol: tcp"; done=1}' "$QBITTORRENT_LOOPBACK_COMPOSE" >"$peer_override"
QBITTORRENT_LOOPBACK_COMPOSE=$peer_override
expect_failure 'peer-port publication' validate_loopback_override
QBITTORRENT_LOOPBACK_COMPOSE=$REPO_ROOT/compose/qbittorrent-loopback.yaml

bad_lock=$TEST_ROOT/images.lock
sed 's/QBITTORRENT_IMAGE_TAG|lscr.io\/linuxserver\/qbittorrent|\([^|]*\)|sha256:[0-9a-f]*/QBITTORRENT_IMAGE_TAG|lscr.io\/linuxserver\/qbittorrent|\1|sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' "$IMAGE_LOCK" >"$bad_lock"
IMAGE_LOCK=$bad_lock
expect_failure 'wrong qBittorrent digest' load_image_pins
IMAGE_LOCK=$REPO_ROOT/config/images.lock
if load_image_pins >/dev/null 2>&1; then test_pass 'locked qBittorrent image is accepted'; else test_fail 'locked qBittorrent image is accepted'; fi

CONFIG_ROOT=/
MEDIA_ROOT=$TEST_ROOT/media
DEPLOY_ROOT=$TEST_ROOT/deploy
expect_failure 'root config path' check_paths
CONFIG_ROOT=$TEST_ROOT/config

mkdir -p "$MEDIA_ROOT/torrents/movies" "$MEDIA_ROOT/torrents/tv" "$MEDIA_ROOT/torrents/anime"
findmnt() { printf '/\n'; }
expect_failure 'media root that is not its own mount' check_media
unset -f findmnt

script_text=$(<"$SCRIPT")
compose_text=$(<"$REPO_ROOT/compose.yaml")
assert_contains "$script_text" 'pull qbittorrent' 'apply pulls only qBittorrent'
assert_contains "$script_text" 'up -d --no-deps qbittorrent' 'apply starts exactly qBittorrent without dependencies'
assert_contains "$script_text" '$CONFIG_ROOT/qbittorrent | /config | true' 'verification requires writable config mount'
assert_contains "$script_text" '$MEDIA_ROOT/torrents | /data/torrents | true' 'verification requires writable torrent-root mount'
assert_contains "$script_text" 'grep -qi library' 'verification rejects library mounts'
assert_contains "$script_text" "bindings\" = '8080/tcp | 127.0.0.1 | 8080'" 'verification permits exactly one Web UI publication'
assert_contains "$script_text" '"upnp":false' 'bootstrap disables UPnP and NAT-PMP'
assert_contains "$script_text" '"web_ui_csrf_protection_enabled":true' 'bootstrap retains CSRF protection'
assert_contains "$script_text" '"web_ui_host_header_validation_enabled":true' 'bootstrap retains host-header validation'
assert_contains "$script_text" '"max_ratio_act":0' 'automatic torrent deletion is not enabled'
assert_contains "$script_text" "printf 'category=%s&savePath=%s'" 'category request paths have no trailing newline'
assert_contains "$script_text" 'refusing to replace a category while torrents exist' 'category repair requires an empty torrent list'
assert_contains "$script_text" 'print("__MISMATCH__")' 'category comparison preserves trailing-path differences'
assert_not_contains "$script_text" 'api/v2/torrents/add' 'deployment never calls the add-torrent API'
assert_not_contains "$script_text" 'magnet:' 'deployment contains no magnet link'
assert_not_contains "$script_text" '/var/run/docker.sock' 'deployment never mounts the Docker socket'
qbittorrent_block=$(printf '%s\n' "$compose_text" | sed -n '/^  qbittorrent:/,/^  sonarr:/p')
assert_not_contains "$qbittorrent_block" 'init: true' 'qBittorrent leaves its s6 overlay as PID 1'
assert_contains "$script_text" 'vf_random_hex 32' 'deployment reuses secure installer secret generation'
assert_contains "$script_text" '[ -f "$secret_path" ]' 'existing management password is preserved by default'
assert_contains "$script_text" 'previous-password file must be a regular mode-0600 file' 'rotation requires an explicit protected previous-password file'

listener_root=$TEST_ROOT/listener-baseline
mkdir -p "$listener_root/state"
RUNTIME_ROOT=$listener_root
listener_source=$TEST_ROOT/listeners.source
printf 'tcp 0.0.0.0:22\ntcp 127.0.0.1:8096\n' >"$listener_source"
snapshot_listeners() { cat "$listener_source"; }
chown() { :; }
record_listener_baseline
printf 'tcp 0.0.0.0:22\ntcp 127.0.0.1:8096\ntcp 127.0.0.1:8080\n' >"$listener_source"
record_listener_baseline
if ! grep -q ':8080' "$listener_root/state/qbittorrent-listeners-before.txt"; then test_pass 'repeated apply preserves the pre-qBittorrent listener baseline'; else test_fail 'repeated apply preserves the pre-qBittorrent listener baseline'; fi
[ "$(file_mode "$listener_root/state/qbittorrent-listeners-before.txt")" = 600 ] && test_pass 'qBittorrent listener baseline is mode 0600' || test_fail 'qBittorrent listener baseline is mode 0600'
if verify_listener_delta >/dev/null 2>&1; then test_pass 'only loopback qBittorrent may differ from its listener baseline'; else test_fail 'only loopback qBittorrent may differ from its listener baseline'; fi
printf 'tcp 0.0.0.0:22\ntcp 127.0.0.1:8096\ntcp 127.0.0.1:8080\ntcp 0.0.0.0:9999\n' >"$listener_source"
expect_failure 'unexpected listener' verify_listener_delta
unset -f chown

mock_root=$TEST_ROOT/check-root
ENV_FILE=$mock_root/.env
DEPLOY_ROOT=$mock_root
RUNTIME_ROOT=$mock_root/runtime
CONFIG_ROOT=$mock_root/config
MEDIA_ROOT=$mock_root/media
require_commands() { :; }
runtime_identity() { RUNTIME_UID=$(id -u); RUNTIME_GID=$(id -g); }
load_image_pins() { :; }
validate_loopback_override() { :; }
check_paths() { :; }
check_media() { :; }
check_existing_scope() { :; }
check_image_scope() { :; }
check_port() { :; }
check_env_contract() { :; }
validate_compose() { :; }
check_output=$(run_check 2>&1)
[ ! -e "$mock_root" ] && test_pass 'check mode creates no persistent output' || test_fail 'check mode creates no persistent output'
assert_contains "$check_output" 'Read-only qBittorrent check passed' 'check mode reports immutability'
if printf '%s\n' "$check_output" | grep -Eq 'PASSWORD=|SECRET=|TOKEN=|sha256:[0-9a-f]{64}'; then test_fail 'check output is secret-safe'; else test_pass 'check output is secret-safe'; fi

mkdir -p "$TEST_ROOT/mock-apply"
compose_log=$TEST_ROOT/compose.log
require_root() { :; }
jellyfin_fingerprint() { printf 'same-jellyfin\n'; }
pgrep() { printf '3\n'; }
run_checks() { :; }
prepare_directories() { :; }
prepare_credentials() { :; }
record_listener_baseline() { :; }
validate_compose() { :; }
compose_cmd() { local ignored=$1; shift; printf '%s\n' "$*" >>"$compose_log"; }
verify_single_id() { printf 'mock-qbittorrent-id\n'; }
wait_for_health() { :; }
bootstrap_qbittorrent() { :; }
run_verify() { :; }
write_credential_artifacts() { :; }
if run_apply >/dev/null 2>&1; then test_pass 'mocked apply is idempotent and completes'; else test_fail 'mocked apply is idempotent and completes'; fi
[ "$(grep -c '^pull qbittorrent$' "$compose_log")" -eq 1 ] && test_pass 'mocked apply selects one image pull' || test_fail 'mocked apply selects one image pull'
[ "$(grep -c '^up -d --no-deps qbittorrent$' "$compose_log")" -eq 1 ] && test_pass 'mocked apply selects exactly qBittorrent' || test_fail 'mocked apply selects exactly qBittorrent'

printf '\nTests: %d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
