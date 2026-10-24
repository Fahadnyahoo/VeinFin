#!/usr/bin/env bash
set -u
set -o pipefail

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT=$REPO_ROOT/scripts/deploy/jellyfin.sh
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
assert_contains "$help_output" 'scripts/deploy/jellyfin.sh --check' 'help documents check mode'
assert_contains "$help_output" 'pull' 'help limits apply to the locked Jellyfin image'
assert_contains "$help_output" 'ssh -N -L 8096:127.0.0.1:8096 user@host' 'help documents a generic loopback tunnel'

VEINFIN_JELLYFIN_LIBRARY_ONLY=1 source "$SCRIPT"
set +e

if validate_loopback_override >/dev/null 2>&1; then test_pass 'committed override is accepted as loopback-only'; else test_fail 'committed override is accepted as loopback-only'; fi

bad_override=$TEST_ROOT/wildcard.yaml
sed 's/host_ip: 127.0.0.1/host_ip: 0.0.0.0/' "$LOOPBACK_COMPOSE" >"$bad_override"
LOOPBACK_COMPOSE=$bad_override
expect_failure 'wildcard Jellyfin publication is rejected' validate_loopback_override
LOOPBACK_COMPOSE=$REPO_ROOT/compose/jellyfin-loopback.yaml

bad_lock=$TEST_ROOT/images.lock
sed 's/JELLYFIN_IMAGE_TAG|jellyfin\/jellyfin|12.3|sha256:[0-9a-f]*/JELLYFIN_IMAGE_TAG|jellyfin\/jellyfin|12.3|sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' "$IMAGE_LOCK" >"$bad_lock"
IMAGE_LOCK=$bad_lock
expect_failure 'incorrect Jellyfin image lock is rejected' load_image_pin
IMAGE_LOCK=$REPO_ROOT/config/images.lock
if load_image_pin >/dev/null 2>&1; then test_pass 'locked Jellyfin image is accepted'; else test_fail 'locked Jellyfin image is accepted'; fi

fake_media=$TEST_ROOT/media
mkdir -p "$fake_media/library/movies" "$fake_media/library/tv" "$fake_media/library/anime"
MEDIA_ROOT=$fake_media
findmnt() { printf '/\n'; }
expect_failure 'media root that is not its own mount is rejected' check_media
unset -f findmnt

RUNTIME_UID=$(id -u)
RUNTIME_GID=$(id -g)
CONFIG_ROOT=$TEST_ROOT/config-root
MEDIA_ROOT=$TEST_ROOT/media-root
RUNTIME_ROOT=$TEST_ROOT/runtime
DEPLOY_ROOT=$TEST_ROOT/deploy
PROJECT_NAME=veinfin
first_env=$TEST_ROOT/first.env
second_env=$TEST_ROOT/second.env
render_env >"$first_env"
render_env >"$second_env"
cmp -s "$first_env" "$second_env" && test_pass 'target-local environment generation is idempotent' || test_fail 'target-local environment generation is idempotent'
grep -Fxq 'PUBLIC_HOSTNAME=local.invalid' "$first_env" && test_pass 'local deployment does not require a public hostname' || test_fail 'local deployment does not require a public hostname'
grep -Fxq 'ENABLE_HARDWARE_TRANSCODING=false' "$first_env" && test_pass 'hardware transcoding remains disabled' || test_fail 'hardware transcoding remains disabled'
grep -Fxq 'MANAGEMENT_PASSWORD=' "$first_env" && test_pass 'deployment generates no administrator or management password' || test_fail 'deployment generates no administrator or management password'
if grep -Eq '^(MANAGEMENT_PASSWORD|[A-Z0-9_]*(API_KEY|SECRET|TOKEN))=.+$' "$first_env"; then test_fail 'generated environment contains no secret value'; else test_pass 'generated environment contains no secret value'; fi

script_text=$(<"$SCRIPT")
assert_contains "$script_text" 'pull jellyfin' 'apply pulls only the Jellyfin service image'
assert_contains "$script_text" 'up -d --no-deps jellyfin' 'apply starts exactly Jellyfin without dependencies'
assert_contains "$script_text" '$MEDIA_ROOT/library | /data/library | false' 'verification requires a read-only library mount'
assert_contains "$script_text" '$CONFIG_ROOT/jellyfin/config | /config | true' 'verification requires writable config mount'
assert_contains "$script_text" '$CONFIG_ROOT/jellyfin/cache | /cache | true' 'verification requires writable cache mount'
assert_contains "$script_text" 'grep -qi torrent' 'verification rejects torrent mounts'
assert_contains "$script_text" "[ \"\$devices\" = '[]' ]" 'verification rejects hardware devices'
assert_contains "$script_text" 'require_root "--apply"' 'apply requires root'
assert_not_contains "$script_text" 'docker compose up -d' 'script has no unrestricted Compose up command'
assert_not_contains "$script_text" '/var/run/docker.sock' 'deployment never mounts the Docker socket'

listener_root=$TEST_ROOT/listener-baseline
mkdir -p "$listener_root/state"
RUNTIME_ROOT=$listener_root
listener_source=$TEST_ROOT/listeners.source
printf 'tcp 0.0.0.0:22\n' >"$listener_source"
snapshot_listeners() { cat "$listener_source"; }
record_listener_baseline
printf 'tcp 0.0.0.0:22\ntcp 127.0.0.1:8096\n' >"$listener_source"
record_listener_baseline
if [ "$(cat "$listener_root/state/jellyfin-listeners-before.txt")" = 'tcp 0.0.0.0:22' ]; then test_pass 'repeated apply preserves the original listener baseline'; else test_fail 'repeated apply preserves the original listener baseline'; fi
[ "$(file_mode "$listener_root/state/jellyfin-listeners-before.txt")" = 600 ] && test_pass 'listener baseline is mode 0600' || test_fail 'listener baseline is mode 0600'
if verify_listener_delta >/dev/null 2>&1; then test_pass 'only loopback Jellyfin may differ from the listener baseline'; else test_fail 'only loopback Jellyfin may differ from the listener baseline'; fi
printf 'tcp 0.0.0.0:22\ntcp 127.0.0.1:8096\ntcp 0.0.0.0:9999\n' >"$listener_source"
expect_failure 'an unrelated new listener is rejected' verify_listener_delta

mock_root=$TEST_ROOT/check-root
ENV_FILE=$mock_root/.env
DEPLOY_ROOT=$mock_root
RUNTIME_ROOT=$mock_root/runtime
CONFIG_ROOT=$mock_root/config
MEDIA_ROOT=$mock_root/media
require_commands() { :; }
runtime_identity() { RUNTIME_UID=$(id -u); RUNTIME_GID=$(id -g); }
check_paths() { :; }
check_media() { :; }
check_container_scope() { :; }
check_image_scope() { :; }
check_port() { :; }
validate_compose() { :; }
check_output=$(run_check 2>&1)
[ ! -e "$mock_root" ] && test_pass 'check mode creates no persistent output' || test_fail 'check mode creates no persistent output'
assert_contains "$check_output" 'Read-only Jellyfin check passed' 'check mode reports immutability'
if printf '%s\n' "$check_output" | grep -Eq 'sha256:[0-9a-f]{64}|PASSWORD=|SECRET=|TOKEN='; then test_fail 'check output is secret-safe'; else test_pass 'check output is secret-safe'; fi

mkdir -p "$TEST_ROOT/mock-apply/runtime/state"
RUNTIME_ROOT=$TEST_ROOT/mock-apply/runtime
compose_log=$TEST_ROOT/compose.log
require_root() { :; }
run_checks() { :; }
prepare_directories() { :; }
snapshot_listeners() { printf 'tcp 127.0.0.1:22\n'; }
record_listener_baseline() { :; }
atomic_write_env() { :; }
validate_compose() { :; }
compose_cmd() { local ignored=$1; shift; printf '%s\n' "$*" >>"$compose_log"; }
existing_jellyfin_id() { printf 'mock-jellyfin-id\n'; }
wait_for_health() { :; }
run_verify() { :; }
if run_apply >/dev/null 2>&1; then test_pass 'mocked apply completes without host networking operations'; else test_fail 'mocked apply completes without host networking operations'; fi
[ "$(grep -c '^pull jellyfin$' "$compose_log")" -eq 1 ] && test_pass 'mocked apply selects one image pull' || test_fail 'mocked apply selects one image pull'
[ "$(grep -c '^up -d --no-deps jellyfin$' "$compose_log")" -eq 1 ] && test_pass 'mocked apply selects exactly the Jellyfin service' || test_fail 'mocked apply selects exactly the Jellyfin service'

printf '\nTests: %d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
