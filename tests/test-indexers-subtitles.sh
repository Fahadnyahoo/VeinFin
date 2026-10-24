#!/usr/bin/env bash
set -u
set -o pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT=$ROOT/scripts/deploy/indexers-subtitles.sh
HELPER=$ROOT/scripts/deploy/indexers_subtitles.py
UNIT=$ROOT/tests/test_indexers_subtitles.py
PASSED=0
FAILED=0
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/veinfin-indexers_subtitles-test.XXXXXX")
trap 'find "$TEST_TMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM
ok() { printf 'PASS: %s\n' "$1"; PASSED=$((PASSED+1)); }
bad() { printf 'FAIL: %s\n' "$1"; FAILED=$((FAILED+1)); }
has() { grep -Fq -- "$2" <<<"$1" && ok "$3" || bad "$3"; }
lacks() { if grep -Fq -- "$2" <<<"$1"; then bad "$3"; else ok "$3"; fi; }

bash -n "$SCRIPT" && ok 'deployment shell syntax' || bad 'deployment shell syntax'
PYTHONPYCACHEPREFIX=$TEST_TMP python3 -m py_compile "$HELPER" "$UNIT" && ok 'Python syntax' || bad 'Python syntax'
PYTHONPYCACHEPREFIX=$TEST_TMP python3 "$UNIT" >/dev/null && ok 'offline capability and profile tests' || bad 'offline capability and profile tests'

help=$($SCRIPT --help 2>&1)
for mode in --check --apply --verify --rollback; do has "$help" "$mode" "help documents $mode"; done
has "$help" 'verification-only' 'help documents repeated-apply idempotence'
has "$help" 'No mode' 'help documents media safety boundary'

VEINFIN_INDEXERS_SUBTITLES_LIBRARY_ONLY=1 source "$SCRIPT"
script_text=$(<"$SCRIPT")
helper_text=$(<"$HELPER")
check_function=$(declare -f run_checks)
apply_function=$(declare -f do_apply)
rollback_function=$(declare -f do_rollback)

lacks "$check_function" 'run_api backup' 'check does not create a backup'
lacks "$check_function" 'run_api apply' 'check does not mutate APIs'
has "$apply_function" 'run_api backup' 'apply backs up before mutation'
has "$apply_function" 'MARKER' 'apply has completion-marker idempotence'
has "$apply_function" 'run_api rollback' 'failed apply invokes rollback'
has "$rollback_function" 'run_api rollback' 'explicit rollback restores API state'
has "$helper_text" 'sqlite3.connect' 'online SQLite backup is implemented'
has "$helper_text" 'PRAGMA integrity_check' 'backup integrity is checked'
has "$helper_text" 'os.replace' 'protected outputs are atomic'
has "$helper_text" 'indexer/test' 'official Prowlarr connection test is required'
has "$helper_text" 'credential_free' 'credential-bearing indexers are rejected'
has "$helper_text" 'definitionName' 'candidate IDs resolve from live schemas'
has "$helper_text" 'ApplicationIndexerSync' 'Arr synchronization is explicit'
has "$helper_text" 'applications/test' 'Prowlarr application connections are tested'
has "$helper_text" 'flaresolverr' 'FlareSolverr scope is schema driven'
has "$helper_text" 'enabled_indexers' 'exact enabled indexers are persisted in protected state'
has "$helper_text" 'if apps["prowlarr"].get("indexer")' 'duplicate/non-empty first apply is rejected'
has "$helper_text" 'BAZARR_PROVIDERS = ("embeddedsubtitles", "subtitlecat")' 'provider set is bounded'
has "$helper_text" 'include_machine_translated' 'machine-translated subtitles stay disabled'
has "$helper_text" 'profileId") is not None' 'existing media receives no profile or scan'
has "$helper_text" 'Bazarr wanted/history state is not empty' 'empty subtitle activity is enforced'
has "$helper_text" 'qbit_count' 'zero torrents are enforced'
has "$helper_text" 'episodefile?seriesId=' 'existing Sonarr episode files are preserved'
lacks "$helper_text" 'search-missing' 'subtitle search action is absent'
lacks "$helper_text" 'scan-disk' 'subtitle media scan action is absent'
lacks "$helper_text" 'RssSync' 'RSS search command is absent'
lacks "$script_text" 'docker restart' 'containers are not restarted'
lacks "$script_text" 'docker compose up' 'containers are not recreated'
lacks "$script_text" 'chmod -R' 'recursive permission changes are absent'
lacks "$script_text" 'chown -R' 'recursive ownership changes are absent'

if grep -Eqi '(192\.168\.|10\.[0-9]+\.)' "$SCRIPT" "$HELPER" "$UNIT"; then
  bad 'tracked Indexer and subtitle setup implementation is deployment-generic'
else
  ok 'tracked Indexer and subtitle setup implementation is deployment-generic'
fi
if grep -Eqi '(password|api.?key|token)[[:space:]]*=[[:space:]]*[A-Za-z0-9+/_=-]{24,}' "$SCRIPT" "$HELPER" "$UNIT"; then
  bad 'no embedded secret values'
else
  ok 'no embedded secret values'
fi

printf '\nTests: %d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
