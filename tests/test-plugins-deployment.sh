#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TEST_TMP=$(mktemp -d /tmp/veinfin-plugin-tests.XXXXXX)
trap 'find "$TEST_TMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM
bash -n "$ROOT/scripts/deploy/plugins.sh"
PYTHONPYCACHEPREFIX=$TEST_TMP python3 -m py_compile "$ROOT/scripts/deploy/plugins.py" "$ROOT/tests/test_plugins.py" \
  "$ROOT/tests/browser-seerr-request-smoke.py"
python3 -m unittest "$ROOT/tests/test_plugins.py"
"$ROOT/scripts/deploy/plugins.py" validate-lock --lock "$ROOT/config/plugins.lock"
"$ROOT/scripts/deploy/plugins.sh" --help | grep -q -- '--rollback'
"$ROOT/scripts/deploy/plugins.sh" --help | grep -q -- '--configure-integrations'
grep -q 'configuration rollback was already complete' "$ROOT/scripts/deploy/plugins.sh"
grep -q 'wait_jellyfin || die "Jellyfin did not become ready"' "$ROOT/scripts/deploy/plugins.sh"
grep -q 'kefin-tweaks.tar.gz' "$ROOT/scripts/deploy/plugins.sh"
"$ROOT/scripts/deploy/plugins.sh" --help | grep -q -- '--verify-integrations'
"$ROOT/scripts/deploy/plugins.sh" --help | grep -q -- '--rollback-integrations'
grep -q 'plugins)' "$ROOT/scripts/installer.sh"
grep -q 'config/jellyfin-enhanced-profile.json' "$ROOT/scripts/installer.sh"
grep -q 'plugins.sh" --configure-integrations' "$ROOT/scripts/installer.sh"
grep -q 'plugins.sh" --verify-integrations' "$ROOT/scripts/installer.sh"
if grep -Eq 'https?://|(10|127|169\.254|172\.(1[6-9]|2[0-9]|3[01])|192\.168)(\.[0-9]{1,3}){2}' \
  "$ROOT/config/jellyfin-enhanced-profile.json"; then
  printf 'FAIL: portable profile contains an endpoint or private address\n' >&2; exit 1
fi
if grep -q 'requestMedia(' "$ROOT/tests/browser-seerr-request-smoke.py"; then
  printf 'FAIL: browser Request-control smoke test can submit a request\n' >&2; exit 1
fi
if grep -Eiq 'Who.?s Watching|WhoIsWatching|whos_watching' "$ROOT/config/plugins.lock"; then
  printf 'FAIL: deferred plugin entered supported lock\n' >&2; exit 1
fi
printf 'Plugin deployment tests passed.\n'
