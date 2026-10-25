#!/usr/bin/env bash
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
INSTALLER="$REPO_DIR/install.sh"
TEST_TMP=$(mktemp -d /tmp/veinfin-installer-tests.XXXXXX)
PASS_COUNT=0

cleanup() {
  if [ -d "$TEST_TMP" ]; then
    find "$TEST_TMP" -depth -delete
  fi
}
trap cleanup EXIT HUP INT TERM

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'PASS: %s\n' "$1"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mode_of() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then stat -c '%a' "$1"; else stat -f '%Lp' "$1"; fi
}

expect_failure() {
  vf_name=$1
  shift
  if "$@" >"$TEST_TMP/failure.log" 2>&1; then
    fail "$vf_name unexpectedly succeeded"
  fi
  pass "$vf_name rejected"
}

bash -n "$REPO_DIR/install.sh" "$REPO_DIR/scripts/installer.sh" "$REPO_DIR/scripts/lib/common.sh" "$REPO_DIR/scripts/lib/config.sh" "$REPO_DIR/scripts/lib/preflight.sh"
pass "shell syntax"

"$INSTALLER" --help >"$TEST_TMP/help.log"
grep -q -- '--generate-config' "$TEST_TMP/help.log" || fail "help omitted generate mode"
grep -q -- '--rotate-secrets' "$TEST_TMP/help.log" || fail "help omitted rotation"
grep -q -- '--profile' "$TEST_TMP/help.log" || fail "help omitted explicit installation profile"
pass "installer help"

for installer_source in "$REPO_DIR/install.sh" "$REPO_DIR/scripts/installer.sh" "$REPO_DIR"/scripts/lib/*.sh; do
  if grep -Eiq 'Who.?s Watching|WhoIsWatching|whos_watching|experimental-plugins\.lock' "$installer_source"; then
    fail "installer references experimental Who’s Watching material"
  fi
done
grep -Eiq 'Who.?s Watching|WhoIsWatching|whos_watching' "$REPO_DIR/config/plugins.lock" && fail "supported plugin lock contains deferred Who’s Watching"
grep -q 'plugins)' "$REPO_DIR/scripts/installer.sh" || fail "supported plugin component is absent from installer"
grep -Eiq 'Who.?s Watching|WhoIsWatching|plugin-installer' "$REPO_DIR/compose.yaml" && fail "default Compose enables plugin installation"
pass "experimental plugins excluded from default installation"

dry_root="$TEST_TMP/dry-root"
"$INSTALLER" --dry-run --profile public-https --root "$dry_root" --set PUBLIC_HOSTNAME=media.test.invalid >"$TEST_TMP/dry.log" 2>&1
[ ! -e "$dry_root" ] || fail "dry-run created output root"
pass "dry-run safety"

output_root="$TEST_TMP/output"
test_media_root="$TEST_TMP/unmounted-media"
"$INSTALLER" --generate-config --profile public-https --root "$output_root" --set PUBLIC_HOSTNAME=media.test.invalid --set MEDIA_ROOT="$test_media_root" >"$TEST_TMP/generate.log" 2>&1
[ -f "$output_root/.env" ] || fail "generation did not create .env"
[ -f "$output_root/runtime/config/caddy/Caddyfile" ] || fail "generation did not render Caddy"
[ -f "$output_root/runtime/generated/endpoints.env" ] || fail "generation did not render endpoints"
[ -f "$output_root/runtime/secrets/credentials-summary.txt" ] || fail "generation did not create summary"
[ -f "$output_root/runtime/state/bootstrap-status.env" ] || fail "generation did not create bootstrap status"
pass "temporary-root generation"

[ "$(mode_of "$output_root/.env")" = 600 ] || fail ".env mode is not 0600"
[ "$(mode_of "$output_root/runtime/secrets")" = 700 ] || fail "secret directory mode is not 0700"
for secret_file in "$output_root"/runtime/secrets/*; do
  [ "$(mode_of "$secret_file")" = 600 ] || fail "secret file mode is not 0600"
done
pass "secure permissions"

grep -q 'media.test.invalid' "$output_root/runtime/config/caddy/Caddyfile" || fail "hostname was not rendered"
grep -q '^FLARESOLVERR_INTERNAL_URL=http://flaresolverr:8191$' "$output_root/runtime/generated/endpoints.env" || fail "FlareSolverr endpoint missing"
grep -q '^ENABLE_HARDWARE_TRANSCODING=false$' "$output_root/.env" || fail "hardware transcoding default is not off"
pass "template rendering"

[ -f "$output_root/runtime/secrets/management-password" ] || fail "management password was not generated"
[ ! -e "$output_root/runtime/secrets/qbittorrent-password" ] || fail "separate qBittorrent password was generated"
[ ! -e "$output_root/runtime/secrets/control-panel-session-secret" ] || fail "premature panel secret was generated"
if find "$output_root/runtime/secrets" -name '*-api-key' -print | grep -q .; then
  fail "premature application API key was generated"
fi
grep -q '^Status: not yet applied;' "$output_root/runtime/secrets/credentials-summary.txt" || fail "credential summary lacks not-yet-applied status"
grep -q 'including qBittorrent' "$output_root/runtime/secrets/credentials-summary.txt" || fail "qBittorrent shared-password intent is missing"
grep -q '^QBITTORRENT_MANAGEMENT_PASSWORD_SOURCE=MANAGEMENT_PASSWORD$' "$output_root/runtime/state/bootstrap-status.env" || fail "qBittorrent does not reference the shared password"
grep -q '^SONARR_API_KEY=PENDING_BOOTSTRAP$' "$output_root/runtime/state/bootstrap-status.env" || fail "API-key pending state is missing"
pass "unified pending credential contract"

env_before=$(cksum "$output_root/.env")
management_before=$(cksum "$output_root/runtime/secrets/management-password")
"$INSTALLER" --generate-config --profile public-https --root "$output_root" --set PUBLIC_HOSTNAME=changed.test.invalid >"$TEST_TMP/repeat.log" 2>&1
[ "$env_before" = "$(cksum "$output_root/.env")" ] || fail "idempotent rerun overwrote .env"
[ "$management_before" = "$(cksum "$output_root/runtime/secrets/management-password")" ] || fail "idempotent rerun changed a secret"
pass "idempotent preservation"

"$INSTALLER" --generate-config --profile public-https --force --root "$output_root" --set PUBLIC_HOSTNAME=changed.test.invalid --set MEDIA_ROOT="$test_media_root" >"$TEST_TMP/force.log" 2>&1
[ "$management_before" = "$(cksum "$output_root/runtime/secrets/management-password")" ] || fail "force changed a preserved secret"
grep -q '^PUBLIC_HOSTNAME=changed.test.invalid$' "$output_root/.env" || fail "force did not update non-secret configuration"
pass "force preserves existing secrets"

"$INSTALLER" --generate-config --profile public-https --rotate-secrets --root "$output_root" --set PUBLIC_HOSTNAME=changed.test.invalid --set MEDIA_ROOT="$test_media_root" >"$TEST_TMP/rotate.log" 2>&1
[ "$management_before" != "$(cksum "$output_root/runtime/secrets/management-password")" ] || fail "explicit rotation did not change secret"
pass "explicit secret rotation"

env_before_check=$(cksum "$output_root/.env")
set +e
"$INSTALLER" --check --root "$output_root" >"$TEST_TMP/check.log" 2>&1
check_result=$?
set -e
[ "$check_result" -ne 0 ] || fail "preflight unexpectedly declared an isolated test root deployment-ready"
grep -q 'Operating system:' "$TEST_TMP/check.log" || fail "preflight omitted operating system"
grep -q 'CPU cores:' "$TEST_TMP/check.log" || fail "preflight omitted CPU count"
grep -q 'RAM:' "$TEST_TMP/check.log" || fail "preflight omitted RAM"
grep -q 'configured media root' "$TEST_TMP/check.log" || fail "preflight omitted media-root result"
grep -q 'deployment remains unavailable' "$TEST_TMP/check.log" || fail "preflight omitted unavailable deployment result"
grep -q 'Compose cannot enforce MANAGEMENT_ALLOWED_CIDRS' "$TEST_TMP/check.log" || fail "preflight omitted the Compose allowlist limitation"
[ "$env_before_check" = "$(cksum "$output_root/.env")" ] || fail "preflight modified .env"
pass "non-mutating readiness preflight"

for secret_file in "$output_root"/runtime/secrets/management-password; do
  secret_value=$(tr -d '\r\n' <"$secret_file")
  for log_file in "$TEST_TMP"/*.log; do
    grep -Fq "$secret_value" "$log_file" && fail "secret value appeared in installer logs"
  done
done
pass "logs contain no secret values"

if find "$output_root" -name '*.tmp.*' -print | grep -q .; then
  fail "atomic generation left temporary files"
fi
pass "atomic generation cleanup"

valid_base=("$INSTALLER" --dry-run --profile public-https --root "$TEST_TMP/invalid-cases" --set PUBLIC_HOSTNAME=valid.test.invalid)
expect_failure "missing explicit profile" "$INSTALLER" --dry-run --root "$TEST_TMP/missing-profile"
expect_failure "placeholder hostname" "$INSTALLER" --dry-run --profile public-https --root "$TEST_TMP/placeholder-case"
expect_failure "invalid hostname" "${valid_base[@]}" --set PUBLIC_HOSTNAME=bad_host
expect_failure "invalid path" "${valid_base[@]}" --set MEDIA_ROOT=relative/path
expect_failure "invalid port" "${valid_base[@]}" --set HTTPS_PORT=70000
expect_failure "invalid UID" "${valid_base[@]}" --set PUID=0
expect_failure "invalid allowlist" "${valid_base[@]}" --set MANAGEMENT_ALLOWED_CIDRS=192.0.2.1/99
expect_failure "unresolved image placeholder" "${valid_base[@]}" --set CADDY_IMAGE_TAG=__PIN_REQUIRED__
expect_failure "image lock mismatch" "${valid_base[@]}" --set CADDY_IMAGE_TAG=2.11.7-alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
expect_failure "invalid Compose project name" "${valid_base[@]}" --set COMPOSE_PROJECT_NAME=Bad.Project
expect_failure "duplicate host port" "${valid_base[@]}" --set RADARR_MANAGEMENT_PORT=8989
expect_failure "wildcard management IPv4 bind" "${valid_base[@]}" --set MANAGEMENT_BIND_IP=0.0.0.0
expect_failure "wildcard management IPv6 bind" "${valid_base[@]}" --set MANAGEMENT_BIND_IP=::
expect_failure "unsafe hardware device path" "${valid_base[@]}" --set ENABLE_HARDWARE_TRANSCODING=true --set TRANSCODING_DEVICE=/dev/dri/../renderD128
expect_failure "newline injection" "${valid_base[@]}" --set $'MANAGEMENT_URL_HOST=localhost\nINJECTED=value'
expect_failure "carriage-return injection" "${valid_base[@]}" --set $'MANAGEMENT_URL_HOST=localhost\rINJECTED=value'
expect_failure "control-character injection" "${valid_base[@]}" --set $'MANAGEMENT_URL_HOST=localhost\tINJECTED=value'

printf 'PUBLIC_HOSTNAME=input.test.invalid\000INJECTED=value\n' >"$TEST_TMP/nul.env"
expect_failure "NUL input" "$INSTALLER" --dry-run --profile public-https --root "$TEST_TMP/nul-output" --input "$TEST_TMP/nul.env"
printf 'PUBLIC_HOSTNAME=input.test.invalid\r\n' >"$TEST_TMP/cr.env"
expect_failure "carriage-return input" "$INSTALLER" --dry-run --profile public-https --root "$TEST_TMP/cr-output" --input "$TEST_TMP/cr.env"

input_root="$TEST_TMP/input-output"
printf 'PUBLIC_HOSTNAME=input.test.invalid\nMANAGEMENT_BIND_IP=127.0.0.1\nMANAGEMENT_ALLOWED_CIDRS=127.0.0.1/32\n' >"$TEST_TMP/settings.env"
"$INSTALLER" --generate-config --profile public-https --root "$input_root" --input "$TEST_TMP/settings.env" >"$TEST_TMP/input.log" 2>&1
grep -q '^PUBLIC_HOSTNAME=input.test.invalid$' "$input_root/.env" || fail "input file was not applied"
pass "noninteractive input file"

environment_root="$TEST_TMP/environment-output"
VEINFIN_ROOT="$environment_root" "$INSTALLER" --generate-config --profile public-https --input "$TEST_TMP/settings.env" >"$TEST_TMP/environment-root.log" 2>&1
[ -f "$environment_root/.env" ] || fail "VEINFIN_ROOT was not honored"
pass "VEINFIN_ROOT output isolation"

lan_root="$TEST_TMP/lan-output"
"$INSTALLER" --generate-config --profile lan-only --root "$lan_root" \
  --set PUBLIC_BIND_IP=127.0.0.1 --set MANAGEMENT_BIND_IP=192.0.2.10 \
  --set MANAGEMENT_URL_HOST=192.0.2.10 --set MANAGEMENT_ALLOWED_CIDRS=192.0.2.20/32 \
  --set PROTECTED_LAN_CIDRS=192.0.2.0/24 --set MEDIA_ROOT="$test_media_root" >"$TEST_TMP/lan.log" 2>&1
grep -Fxq 'INSTALLATION_PROFILE=lan-only' "$lan_root/.env" || fail "LAN profile was not persisted"
grep -Fxq 'JELLYFIN_PUBLIC_URL=http://192.0.2.10:8096' "$lan_root/runtime/generated/endpoints.env" || fail "LAN Jellyfin endpoint was not rendered"
grep -Fq 'lan_access' "$REPO_DIR/scripts/installer.sh" || fail "LAN access stage is absent"
grep -Fq 'SKIPPED_NOT_REQUESTED' "$REPO_DIR/scripts/installer.sh" || fail "optional migration skip status is not explicit"
pass "LAN-only profile avoids public hostname and records optional-stage skips"

grep -q 'vf_number.*-eq.*vf_frontier' "$REPO_DIR/scripts/installer.sh" || fail "resume does not verify only the latest completed stage frontier"
grep -q 'plugins.sh.*--verify-integrations' "$REPO_DIR/scripts/installer.sh" || fail "completed-install verification omits plugin integrations"
grep -A12 'vf_verify_install()' "$REPO_DIR/scripts/installer.sh" | grep -q 'lan-profile.sh.*--verify' || fail "explicit install verification omits the selected exposure profile"
grep -q 'media_services-preserved-containers.txt' "$REPO_DIR/scripts/deploy/lan-profile.sh" || fail "LAN recreation does not refresh its verified Jellyfin preservation fingerprint"
grep -q 'media_services-listeners-before.txt' "$REPO_DIR/scripts/deploy/lan-profile.sh" || fail "LAN publication does not refresh its verified listener baseline"
pass "resume frontier and completed-stack verification are explicit"

example_keys="$TEST_TMP/example-keys"
accepted_keys="$TEST_TMP/accepted-keys"
awk -F= '/^[A-Z][A-Z0-9_]*=/{print $1}' "$REPO_DIR/.env.example" | sort -u >"$example_keys"
sed -n '/^vf_assign_setting()/,/^}/p' "$REPO_DIR/scripts/lib/config.sh" | sed -nE 's/^[[:space:]]*([A-Z][A-Z0-9_]*)\).*/\1/p' | sort -u >"$accepted_keys"
cmp -s "$example_keys" "$accepted_keys" || { diff -u "$example_keys" "$accepted_keys" >&2 || true; fail ".env.example and parser key sets differ"; }
while IFS= read -r key; do grep -Fq "\`$key\`" "$REPO_DIR/docs/CONFIGURATION.md" || fail "accepted key is undocumented: $key"; done <"$accepted_keys"
pass "every example key is accepted and every accepted key is documented"

expect_failure "unknown key" "$INSTALLER" --dry-run --profile lan-only --root "$TEST_TMP/unknown-key" --set PUBLIC_BIND_IP=127.0.0.1 --set UNKNOWN_INSTALL_KEY=value
grep -Fq 'vf_stage_rollback' "$REPO_DIR/scripts/installer.sh" || fail "installer has no stage rollback dispatch"
grep -Fq 'VEINFIN_CONFIG_ROOT="$CONFIG_ROOT"' "$REPO_DIR/scripts/installer.sh" || fail "installer does not pass generated roots to deployment stages"
grep -Fq 'torrents/incomplete torrents/movies torrents/tv torrents/anime library/movies library/tv library/anime' "$REPO_DIR/scripts/installer.sh" || fail "clean media layout is not part of the core installer"
pass "stage failure invokes rollback dispatch"

if command -v git >/dev/null 2>&1; then
  if git -C "$REPO_DIR" ls-files -- .env runtime | grep -q .; then
    fail "generated .env or runtime files are tracked"
  fi
  pass "no tracked generated runtime files"
else
  printf 'SKIP: tracked generated-runtime check (Git unavailable)\n'
fi

if command -v git >/dev/null 2>&1; then
  if git -C "$REPO_DIR" ls-files -- '.DS_Store' '*/.DS_Store' '__MACOSX/**' | grep -q .; then
    fail "Finder or archive metadata is tracked"
  fi
  pass "no tracked Finder or archive metadata"
else
  printf 'SKIP: tracked Finder/archive metadata check (Git unavailable)\n'
fi

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  docker compose --env-file "$REPO_DIR/.env.example" -f "$REPO_DIR/compose.yaml" config >/dev/null
  pass "docker compose config"
else
  printf 'SKIP: docker compose config (Docker Compose unavailable)\n'
fi

printf 'Installer tests passed: %s checks.\n' "$PASS_COUNT"
