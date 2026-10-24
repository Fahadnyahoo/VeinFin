#!/usr/bin/env bash
set -u
set -o pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT=$ROOT/scripts/deploy/sonarr-adoption.sh
HELPER=$ROOT/scripts/deploy/sonarr_adoption.py
PASSED=0
FAILED=0
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/veinfin-sonarr_adoption-test.XXXXXX")
trap 'find "$TEST_TMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM
ok() { printf 'PASS: %s\n' "$1"; PASSED=$((PASSED+1)); }
bad() { printf 'FAIL: %s\n' "$1"; FAILED=$((FAILED+1)); }
has() { grep -Fq -- "$2" <<<"$1" && ok "$3" || bad "$3"; }
lacks() { if grep -Fq -- "$2" <<<"$1"; then bad "$3"; else ok "$3"; fi; }

bash -n "$SCRIPT" && ok 'deployment shell syntax' || bad 'deployment shell syntax'
PYTHONPYCACHEPREFIX=$TEST_TMP python3 -m py_compile "$HELPER" && ok 'adoption helper Python syntax' || bad 'adoption helper Python syntax'
help=$($SCRIPT --help 2>&1)
has "$help" 'sonarr-adoption.sh --check' 'help documents check'
has "$help" 'sonarr-adoption.sh --apply' 'help documents apply'
has "$help" 'sonarr-adoption.sh --verify' 'help documents verify'
has "$help" 'verification-only' 'help documents repeated-apply behavior'
has "$help" 'No mode renames' 'help documents media immutability'

VEINFIN_SONARR_ADOPTION_LIBRARY_ONLY=1 source "$SCRIPT"
script_text=$(<"$SCRIPT")
helper_text=$(<"$HELPER")
check_function=$(declare -f run_checks)
apply_function=$(declare -f do_apply)

lacks "$check_function" 'prepare_recovery' 'check does not write backup or snapshot'
lacks "$check_function" 'run_api apply' 'check does not adopt a series'
has "$apply_function" 'prepare_recovery' 'apply backs up before adoption'
has "$apply_function" 'MARKER' 'apply has completion-marker idempotence'
has "$apply_function" 'STARTED' 'apply blocks ambiguous interrupted adoption'
has "$script_text" 'sonarr_adoption-preserved-containers.txt' 'container baseline is recorded'
has "$script_text" 'sonarr_adoption-listeners-before.txt' 'listener baseline is recorded'
has "$script_text" 'sonarr_adoption-firewall-v4-before.rules' 'firewall baseline is recorded'
has "$script_text" '/^# (Generated|Completed)/d' 'dynamic firewall timestamps are normalized'
has "$script_text" '[0:0]' 'dynamic firewall counters are normalized'
has "$script_text" 'sonarr_adoption-https-before.txt' 'HTTPS baseline is recorded'
has "$script_text" 'sonarr_adoption-sonarr-retry-before' 'fresh retry-specific Sonarr backup is explicit'
has "$script_text" 'sonarr_adoption-media-snapshot.json' 'media size/timestamp snapshot is explicit'
lacks "$script_text" 'docker compose up' 'no container is recreated'
lacks "$script_text" 'docker restart' 'no container is restarted'
lacks "$script_text" 'chmod -R' 'no recursive media permission change exists'
lacks "$script_text" 'chown -R' 'no recursive media ownership change exists'

has "$helper_text" 'series/lookup?term=' 'Sonarr lookup API is used'
has "$helper_text" '"monitor": "none"' 'monitoring is disabled at adoption'
has "$helper_text" '"searchForMissingEpisodes": False' 'missing search is disabled'
has "$helper_text" '"searchForCutoffUnmetEpisodes": False' 'cutoff search is disabled'
has "$helper_text" 'seriesType="anime"' 'series type is Anime'
has "$helper_text" 'rootFolderPath="/data/library/anime"' 'Anime root is exact'
has "$helper_text" '"name": "RescanSeries"' 'only local Sonarr rescan command is requested'
has "$helper_text" 'wait_series_commands_idle' 'automatic refresh and local rescan are serialized'
has "$helper_text" 'wait_file_count_stable' 'episode-file count must stabilize before validation'
has "$helper_text" 'wait_new_refresh' 'automatic RefreshSeries must be observed'
has "$helper_text" 'stable >= 6' 'six consecutive exact file counts are required'
lacks "$helper_text" 'SearchMissing' 'missing-episode command is absent'
lacks "$helper_text" 'EpisodeSearch' 'episode-search command is absent'
lacks "$helper_text" 'RssSync' 'RSS command is absent'
has "$helper_text" 'deleteFiles=false' 'rollback never deletes media'
has "$helper_text" 'addImportListExclusion=false' 'rollback adds no exclusion'
has "$helper_text" 'renameEpisodes' 'renaming must remain disabled'
has "$helper_text" 'copyUsingHardlinks' 'hardlink setting is preserved'
has "$helper_text" 'enableCompletedDownloadHandling' 'Completed Download Handling is preserved'
has "$helper_text" 'downloadclient/test' 'qBittorrent connection is tested without a torrent'
has "$helper_text" 'qbit_torrent_count' 'zero-torrent state is verified'
has "$helper_text" 'media file set, byte size, or timestamp changed' 'media immutability is verified'
lacks "$helper_text" 'os.rename' 'helper does not rename media'
lacks "$helper_text" 'shutil.move' 'helper does not move media'
lacks "$helper_text" 'shutil.copy' 'helper does not copy media'
lacks "$helper_text" 'os.link' 'helper does not hardlink media'

if grep -Fq '331753' "$SCRIPT" "$HELPER"; then
  bad 'tracked Sonarr adoption implementation is deployment-generic'
else
  ok 'tracked Sonarr adoption implementation is deployment-generic'
fi

printf '\nTests: %d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
