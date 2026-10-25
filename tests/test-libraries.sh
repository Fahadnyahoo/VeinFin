#!/usr/bin/env bash
set -u
set -o pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT=$ROOT/scripts/deploy/libraries.sh
HELPER=$ROOT/scripts/deploy/libraries_api.py
PASSED=0
FAILED=0
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/veinfin-libraries-test.XXXXXX")
trap 'find "$TEST_TMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM
ok() { printf 'PASS: %s\n' "$1"; PASSED=$((PASSED+1)); }
bad() { printf 'FAIL: %s\n' "$1"; FAILED=$((FAILED+1)); }
has() { grep -Fq -- "$2" <<<"$1" && ok "$3" || bad "$3"; }
lacks() { if grep -Fq -- "$2" <<<"$1"; then bad "$3"; else ok "$3"; fi; }

bash -n "$SCRIPT" && ok 'deployment shell syntax' || bad 'deployment shell syntax'
PYTHONPYCACHEPREFIX=$TEST_TMP python3 -m py_compile "$HELPER" && ok 'media helper Python syntax' || bad 'media helper Python syntax'
help=$($SCRIPT --help 2>&1)
has "$help" 'libraries.sh --check' 'help documents check'
has "$help" 'libraries.sh --apply' 'help documents apply'
has "$help" 'libraries.sh --verify' 'help documents verify'
has "$help" 'prevents a second scan' 'help documents single-scan guard'
has "$help" 'does not rename media' 'help documents mutation boundary'

VEINFIN_LIBRARIES_LIBRARY_ONLY=1 source "$SCRIPT"
script_text=$(<"$SCRIPT")
helper_text=$(<"$HELPER")
check_function=$(declare -f run_checks)
apply_function=$(declare -f do_apply)

lacks "$check_function" 'jellyfin_action apply' 'check does not mutate Jellyfin'
lacks "$check_function" 'probe_media' 'check does not probe every media file'
has "$apply_function" 'record_baseline' 'apply records container baseline'
has "$apply_function" 'probe_media' 'apply probes media before library mutation'
has "$apply_function" 'MARKER' 'apply guards the controlled scan'
has "$script_text" 'libraries-preserved-containers.txt' 'container identity baseline is protected'
has "$script_text" 'libraries-scan-complete' 'single-scan marker is explicit'
has "$script_text" 'libraries-scan-started' 'interrupted scan blocks an ambiguous rerun'
has "$script_text" 'mountpoint -q /srv/media' 'media mount is required'
has "$script_text" 'Jellyfin library mount is not exact and read-only' 'Jellyfin media mount must remain read-only'
has "$script_text" 'pgrep -x rsync' 'active rsync is guarded'
has "$script_text" 'veinfin-firewall' 'existing firewall verification is retained'
has "$script_text" 'sport = :80' 'HTTP port remains prohibited'
has "$script_text" 'sport = :2375' 'Docker TCP API remains prohibited'
has "$script_text" 'sport = :8191' 'FlareSolverr host publication remains prohibited'
lacks "$script_text" 'docker compose up' 'Library setup does not recreate containers'
lacks "$script_text" 'docker restart' 'Library setup does not restart containers'
lacks "$script_text" 'chmod -R' 'Library setup does not recursively change ownership or mode'
lacks "$script_text" 'chown -R' 'Library setup does not recursively change ownership'

has "$helper_text" '"Movies": ("movies", "/data/library/movies")' 'Movies library contract is exact'
has "$helper_text" '"TV Shows": ("tvshows", "/data/library/tv")' 'TV Shows library contract is exact'
has "$helper_text" '"Anime": ("tvshows", "/data/library/anime")' 'Anime library contract is exact'
has "$helper_text" '"refreshLibrary": "false"' 'library creation suppresses implicit scan'
has "$helper_text" '"/Library/Refresh"' 'controlled scan endpoint is explicit'
has "$helper_text" '/usr/lib/jellyfin-ffmpeg/ffprobe' 'bundled ffprobe is used'
has "$helper_text" '/usr/lib/jellyfin-ffmpeg/ffmpeg' 'bundled ffmpeg is used for decode samples'
has "$helper_text" '"-f", "null", "-"' 'decode samples create no output files'
has "$helper_text" 'PlaybackInfo' 'playback information is verified'
lacks "$helper_text" 'IsPlayed' 'watch state is not changed'
lacks "$helper_text" 'ProviderIds":' 'metadata provider IDs are not written'

if command -v git >/dev/null 2>&1; then
  if git -C "$ROOT" ls-files -- 'runtime/**' '.env' | grep -Eq '(libraries-media-report|libraries-media\.conf|episode_container_paths)'; then
    bad 'runtime media inventory is absent from tracked files'
  else
    ok 'runtime media inventory is absent from tracked files'
  fi
else
  ok 'tracked-file privacy scan skipped without Git'
fi

printf '\nTests: %d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
