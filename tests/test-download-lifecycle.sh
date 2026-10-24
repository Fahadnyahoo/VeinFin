#!/usr/bin/env bash
set -u
set -o pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT=$ROOT/scripts/deploy/download-lifecycle.sh
HELPER=$ROOT/scripts/deploy/download_lifecycle.py
POLICY=$ROOT/config/download-lifecycle-policy.json
UNIT=$ROOT/tests/test_download_lifecycle.py
PASSED=0
FAILED=0
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/veinfin-download_lifecycle-test.XXXXXX")
trap 'find "$TEST_TMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM
ok() { printf 'PASS: %s\n' "$1"; PASSED=$((PASSED+1)); }
bad() { printf 'FAIL: %s\n' "$1"; FAILED=$((FAILED+1)); }
has() { grep -Fq -- "$2" <<<"$1" && ok "$3" || bad "$3"; }
lacks() { if grep -Fq -- "$2" <<<"$1"; then bad "$3"; else ok "$3"; fi; }

bash -n "$SCRIPT" && ok 'deployment shell syntax' || bad 'deployment shell syntax'
PYTHONPYCACHEPREFIX=$TEST_TMP python3 -m py_compile "$HELPER" "$UNIT" && ok 'Python syntax' || bad 'Python syntax'
PYTHONPYCACHEPREFIX=$TEST_TMP python3 "$UNIT" >/dev/null && ok 'offline cleanup eligibility and artifact tests' || bad 'offline cleanup eligibility and artifact tests'
python3 "$HELPER" validate-policy --policy "$POLICY" >/dev/null && ok 'tracked lifecycle policy validates' || bad 'tracked lifecycle policy validates'

help=$($SCRIPT --help 2>&1)
for mode in --check --preview --apply --verify --rollback; do has "$help" "$mode" "help documents $mode"; done
has "$help" 'verification-only' 'help documents repeated-apply idempotence'
has "$help" 'synthetic proof is deferred' 'help marks live synthetic proof deferred'

VEINFIN_DOWNLOAD_LIFECYCLE_LIBRARY_ONLY=1 source "$SCRIPT"
script_text=$(<"$SCRIPT")
helper_text=$(<"$HELPER")
check_function=$(declare -f run_checks)
preview_function=$(declare -f do_preview)
apply_function=$(declare -f do_apply)
rollback_function=$(declare -f do_rollback)
privilege_function=$(declare -f enter_privileged)
security_function=$(declare -f check_security)

lacks "$check_function" 'apply-config' 'check does not change application configuration'
lacks "$check_function" 'synthetic' 'check does not create validation torrents'
lacks "$preview_function" 'synthetic' 'preview does not create validation torrents'
has "$preview_function" 'run_helper preview' 'preview uses sanitized helper output'
has "$apply_function" 'PREVIEW' 'apply requires a protected preview'
has "$apply_function" 'MARKER' 'apply has completion-marker idempotence'
has "$apply_function" 'BLOCKED' 'apply refuses an unreviewed retry after failure'
has "$apply_function" 'run_helper apply-config' 'apply changes only authenticated production configuration'
lacks "$apply_function" 'run_helper synthetic' 'default apply never creates a synthetic torrent'
lacks "$apply_function" 'cleanup-aborted' 'configuration-only apply has no validation-artifact mutation path'
has "$apply_function" 'run_helper rollback' 'failed apply invokes rollback'
has "$rollback_function" 'run_helper rollback' 'explicit rollback restores API state'
has "$(declare -f do_verify)" 'MARKER' 'final verify requires successful completion'
has "$helper_text" '"share_limits_mode": "MatchAny"' 'production limit uses exact OR mode'
has "$helper_text" '"max_ratio_act": 0' 'production limit action is Stop enum'
has "$helper_text" 'validation_cleanup_authorized' 'live cleanup is explicitly validation-only'
lacks "$helper_text" 'ratioLimit":"0' 'synthetic proof does not fake a share threshold'
has "$helper_text" 'downloadPath' 'admission uses the reviewed incomplete-path parameter'
has "$helper_text" 'useDownloadPath' 'admission explicitly enables its incomplete path'
has "$helper_text" 'transport succeeded but exact synthetic info hash was not admitted' 'transport response is not admission proof'
has "$helper_text" 'torrents/info' 'admission polls live torrent inventory'
has "$helper_text" 'torrents/files' 'admission validates the exact file list'
has "$script_text" 'download_lifecycle-retry1b-apps-before' 'Retry 1B creates a distinct backup'
has "$script_text" 'ORIGINAL_BACKUP' 'the original Download lifecycle setup backup is preserved'
has "$script_text" 'RETRY1_BACKUP' 'the Download lifecycle setup Retry 1 backup is preserved'
has "$helper_text" 'private": 1' 'synthetic torrent metadata is private'
lacks "$helper_text" 'announce' 'synthetic torrent metadata has no tracker'
has "$helper_text" 'os.link' 'hardlink proof uses a real hardlink'
has "$helper_text" 'same_inode' 'hardlink inode equality is required'
has "$helper_text" 'path-outside-validation-root' 'cleanup rejects path escape'
has "$helper_text" 'import-evidence-missing' 'cleanup rejects unimported data'
has "$helper_text" 'hardlink imports are disabled' 'live verification requires Sonarr and Radarr hardlinks'
has "$helper_text" 'os.replace' 'protected output uses atomic replacement'
lacks "$script_text" 'docker restart' 'long-running containers are not restarted'
lacks "$script_text" 'docker compose up' 'long-running containers are not recreated'
lacks "$script_text" 'chmod -R' 'recursive permission changes are absent'
lacks "$script_text" 'chown -R' 'recursive ownership changes are absent'
has "$(<"$ROOT/scripts/installer.sh")" 'download-lifecycle.sh' 'default installer includes configuration-only download lifecycle setup'

if env -u SSH_CONNECTION python3 "$HELPER" validate-ssh </dev/null >"$TEST_TMP/no-context.log" 2>&1; then
  bad 'plain root execution without SSH context fails before mutation'
else
  lacks "$(<"$TEST_TMP/no-context.log")" 'apply-config' 'plain root rejection occurs before mutation'
fi

client=$(python3 -c 'import ipaddress; print(ipaddress.ip_address(1))')
server=$(python3 -c 'import ipaddress; print(ipaddress.ip_address(2))')
connection="$client 32123 $server 22"
cat >"$TEST_TMP/sudo" <<'EOF'
#!/usr/bin/env bash
set -eu
[ "$1" = --preserve-env=SSH_CONNECTION ]
[ "$SSH_CONNECTION" = "$EXPECTED_CONNECTION" ]
printf '%s\n' once >>"$ELEVATION_RECORD"
EOF
chmod 0700 "$TEST_TMP/sudo"
export EXPECTED_CONNECTION=$connection ELEVATION_RECORD=$TEST_TMP/elevations
(
  SSH_CONNECTION=$connection
  SUDO_BIN=$TEST_TMP/sudo
  effective_uid() { printf '1000\n'; }
  validate_ssh_context() { VALIDATED_SSH_CONNECTION=$SSH_CONNECTION; export SSH_CONNECTION; }
  enter_privileged --check
) >/dev/null 2>&1 && ok 'self-elevation preserves the exact validated SSH context' || bad 'self-elevation preserves the exact validated SSH context'
[ "$(wc -l <"$ELEVATION_RECORD" | tr -d ' ')" = 1 ] && ok 'self-elevation executes exactly once' || bad 'self-elevation executes exactly once'

rm -f "$ELEVATION_RECORD"
(
  SSH_CONNECTION=$connection
  SUDO_BIN=$TEST_TMP/sudo
  effective_uid() { printf '0\n'; }
  validate_ssh_context() { VALIDATED_SSH_CONNECTION=$SSH_CONNECTION; export SSH_CONNECTION; }
  enter_privileged --check
) >/dev/null 2>&1
[ ! -e "$ELEVATION_RECORD" ] && ok 'already-privileged execution does not elevate again' || bad 'already-privileged execution does not elevate again'
has "$privilege_function" '--preserve-env=SSH_CONNECTION' 'privilege boundary uses the required sudo preservation flag'
has "$security_function" 'SSH_CONNECTION=$VALIDATED_SSH_CONNECTION /usr/local/sbin/veinfin-firewall --check' 'firewall verifier receives the exact validated peer context'
if grep -Fq -- "$connection" "$SCRIPT" "$HELPER" "$POLICY" "$UNIT" "$ROOT/docs/DOWNLOAD_LIFECYCLE.md"; then
  bad 'active SSH connection value is absent from tracked implementation and documentation'
else
  ok 'active SSH connection value is absent from tracked implementation and documentation'
fi

if grep -Eqi '(192\.168\.|10\.[0-9]+\.)' "$SCRIPT" "$HELPER" "$POLICY" "$UNIT"; then bad 'tracked Download lifecycle setup implementation is deployment-generic'; else ok 'tracked Download lifecycle setup implementation is deployment-generic'; fi
if grep -Eqi '(password|api.?key|token)[[:space:]]*=[[:space:]]*[A-Za-z0-9+/_=-]{24,}' "$SCRIPT" "$HELPER" "$POLICY" "$UNIT"; then bad 'no embedded secret values'; else ok 'no embedded secret values'; fi

printf '\nTests: %d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
