#!/usr/bin/env bash
set -u
set -o pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT=$ROOT/scripts/deploy/quality-profiles.sh
HELPER=$ROOT/scripts/deploy/quality_profiles.py
POLICY=$ROOT/config/quality-policy.json
UNIT=$ROOT/tests/test_quality_profiles.py
PASSED=0
FAILED=0
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/veinfin-quality_profiles-test.XXXXXX")
trap 'find "$TEST_TMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM
ok() { printf 'PASS: %s\n' "$1"; PASSED=$((PASSED+1)); }
bad() { printf 'FAIL: %s\n' "$1"; FAILED=$((FAILED+1)); }
has() { grep -Fq -- "$2" <<<"$1" && ok "$3" || bad "$3"; }
lacks() { if grep -Fq -- "$2" <<<"$1"; then bad "$3"; else ok "$3"; fi; }

bash -n "$SCRIPT" && ok 'deployment shell syntax' || bad 'deployment shell syntax'
PYTHONPYCACHEPREFIX=$TEST_TMP python3 -m py_compile "$HELPER" "$UNIT" && ok 'Python syntax' || bad 'Python syntax'
PYTHONPYCACHEPREFIX=$TEST_TMP python3 "$UNIT" >/dev/null && ok 'offline quality-policy and preview-gate tests' || bad 'offline quality-policy and preview-gate tests'
python3 "$HELPER" validate-policy --policy "$POLICY" >/dev/null && ok 'tracked policy validates' || bad 'tracked policy validates'

help=$($SCRIPT --help 2>&1)
for mode in --check --preview --apply --verify --rollback; do has "$help" "$mode" "help documents $mode"; done
has "$help" 'verification-only' 'help documents repeated-apply idempotence'
has "$help" 'guarded last resort' 'help documents database rollback boundary'

VEINFIN_QUALITY_PROFILES_LIBRARY_ONLY=1 source "$SCRIPT"
script_text=$(<"$SCRIPT")
helper_text=$(<"$HELPER")
check_function=$(declare -f run_checks)
preview_function=$(declare -f do_preview)
apply_function=$(declare -f do_apply)
rollback_function=$(declare -f do_rollback)

lacks "$check_function" 'compose_recyclarr' 'check does not run Recyclarr'
lacks "$check_function" 'prepare_backup' 'check does not create backups'
has "$preview_function" '--preview --config' 'preview invokes official preview mode'
lacks "$preview_function" 'seerr-apply' 'preview does not mutate Seerr'
has "$apply_function" 'verify_preview_gate' 'apply requires the preview gate'
has "$apply_function" '--instance veinfin-sonarr --instance veinfin-radarr --config' 'apply runs one controlled synchronization for both instances'
has "$apply_function" 'MARKER' 'apply has completion-marker idempotence'
has "$apply_function" 'rollback' 'failed apply invokes rollback'
has "$rollback_function" 'run_helper rollback' 'explicit rollback restores API state'
has "$helper_text" 'sqlite3.connect' 'online consistent SQLite backup is implemented'
has "$helper_text" 'PRAGMA integrity_check' 'backup integrity is checked'
has "$helper_text" 'os.replace' 'protected output uses atomic replacement'
has "$helper_text" 'activeAnimeProfileName' 'Seerr anime default uses the existing connection'
has "$helper_text" 'existing Sonarr series assignment or monitoring changed' 'existing-content non-assignment is enforced'
has "$helper_text" 'qbit_torrents' 'zero torrents are enforced'
has "$helper_text" 'queue' 'Arr queue preservation is enforced'
has "$helper_text" 'history' 'history preservation is enforced'
lacks "$script_text" 'docker restart' 'long-running containers are not restarted'
lacks "$script_text" 'docker compose up' 'long-running containers are not recreated'
lacks "$script_text" 'chmod -R' 'recursive permission changes are absent'
lacks "$script_text" 'chown -R' 'recursive ownership changes are absent'

if grep -Eqi '(192\.168\.|10\.[0-9]+\.)' "$SCRIPT" "$HELPER" "$POLICY" "$UNIT"; then
  bad 'tracked Quality profile setup implementation is deployment-generic'
else
  ok 'tracked Quality profile setup implementation is deployment-generic'
fi
if grep -Eqi '(password|api.?key|token)[[:space:]]*=[[:space:]]*[A-Za-z0-9+/_=-]{24,}' "$SCRIPT" "$HELPER" "$POLICY" "$UNIT"; then
  bad 'no embedded secret values'
else
  ok 'no embedded secret values'
fi

printf '\nTests: %d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
