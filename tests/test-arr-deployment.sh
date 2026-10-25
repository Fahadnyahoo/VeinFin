#!/usr/bin/env bash
set -u
set -o pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT=$ROOT/scripts/deploy/arr.sh
HELPER=$ROOT/scripts/deploy/arr_api.py
TEST_ROOT=$(mktemp -d)
PASSED=0
FAILED=0
cleanup() { find "$TEST_ROOT" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
ok() { printf 'PASS: %s\n' "$1"; PASSED=$((PASSED+1)); }
bad() { printf 'FAIL: %s\n' "$1"; FAILED=$((FAILED+1)); }
has() { grep -Fq -- "$2" <<<"$1" && ok "$3" || bad "$3"; }
lacks() { if grep -Fq -- "$2" <<<"$1"; then bad "$3"; else ok "$3"; fi; }
fails() { local name=$1; shift; if ("$@") >/dev/null 2>&1; then bad "$name"; else ok "$name"; fi; }

bash -n "$SCRIPT" && ok 'deployment shell syntax' || bad 'deployment shell syntax'
python3 -c 'import ast,pathlib,sys; ast.parse(pathlib.Path(sys.argv[1]).read_text())' "$HELPER" && ok 'API helper syntax' || bad 'API helper syntax'
help=$("$SCRIPT" --help 2>&1)
has "$help" 'scripts/deploy/arr.sh --check' 'help documents check'
has "$help" 'Pull/start only Sonarr, Radarr, and Prowlarr' 'help limits service selection'
has "$help" '8989:127.0.0.1:8989 user@host' 'help uses a generic Sonarr tunnel'
has "$help" 'never adds a torrent, movie, series, indexer' 'help documents no-content boundary'

VEINFIN_ARR_LIBRARY_ONLY=1 source "$SCRIPT"
set +e
trap cleanup EXIT HUP INT TERM
validate_loopback >/dev/null 2>&1 && ok 'exact loopback override accepted' || bad 'exact loopback override accepted'
for replacement in '0.0.0.0' '::' '192.0.2.55'; do
  file=$TEST_ROOT/arr-$(printf %s "$replacement" | tr ':.' _).yaml
  sed "s/host_ip: 127.0.0.1/host_ip: $replacement/g" "$ARR_LOOPBACK" >"$file"
  saved=$ARR_LOOPBACK; ARR_LOOPBACK=$file
  fails "unsafe bind rejected: $replacement" validate_loopback
  ARR_LOOPBACK=$saved
done

script_text=$(<"$SCRIPT")
helper_text=$(<"$HELPER")
compose_text=$(<"$ROOT/compose.yaml")
has "$script_text" 'pull sonarr radarr prowlarr' 'apply pulls exactly three services'
has "$script_text" 'up -d --no-deps sonarr radarr prowlarr' 'apply starts exactly three services'
has "$script_text" 'stop sonarr radarr prowlarr' 'rollback stops only new services'
has "$script_text" 'arr-preserved-containers.txt' 'existing fingerprints are preserved'
has "$script_text" 'external rsync process count changed' 'external copy process is guarded'
has "$script_text" 'pgrep -x rsync || true' 'clean host without rsync is supported'
has "$script_text" 'hardlink shared device/inode' 'hardlink verification is implemented'
has "$script_text" 'find "$TEST_TORRENT_DIR" -depth -delete' 'hardlink source cleanup is implemented'
has "$script_text" 'find "$TEST_LIBRARY_DIR" -depth -delete' 'hardlink destination cleanup is implemented'
has "$helper_text" 'http://prowlarr:9696' 'Prowlarr uses Docker DNS for itself'
has "$helper_text" 'http://sonarr:8989' 'Prowlarr uses Sonarr Docker DNS'
has "$helper_text" 'http://radarr:7878' 'Prowlarr uses Radarr Docker DNS'
has "$helper_text" '"host": "qbittorrent"' 'clients use qBittorrent Docker DNS'
has "$helper_text" '"VeinFin qBittorrent TV": "tv"' 'TV category is exact'
has "$helper_text" '"VeinFin qBittorrent Anime": "anime"' 'Anime category is exact'
has "$helper_text" '"VeinFin qBittorrent Movies": "movies"' 'movie category is exact'
has "$helper_text" '/data/library/tv' 'TV root is exact'
has "$helper_text" '/data/library/anime' 'Anime root is exact'
has "$helper_text" '/data/library/movies' 'movie root is exact'
has "$helper_text" 'copyUsingHardlinks' 'hardlink import is enabled'
has "$helper_text" 'enableCompletedDownloadHandling' 'completed handling is enabled'
has "$helper_text" 'removeCompletedDownloads=True' 'completed removal support is enabled'
has "$helper_text" 'remotepathmapping' 'remote mappings are verified absent'
has "$helper_text" 'prowlarr.get("indexer") != []' 'indexers are verified absent'
lacks "$helper_text" '/api/v3/series' 'helper does not create a series'
lacks "$helper_text" '/api/v3/movie' 'helper does not create a movie'
lacks "$helper_text" 'magnet:' 'helper has no magnet URI'
lacks "$script_text" '/var/run/docker.sock' 'deployment never mounts Docker socket'

sonarr_block=$(printf '%s\n' "$compose_text" | sed -n '/^  sonarr:/,/^  radarr:/p')
radarr_block=$(printf '%s\n' "$compose_text" | sed -n '/^  radarr:/,/^  prowlarr:/p')
prowlarr_block=$(printf '%s\n' "$compose_text" | sed -n '/^  prowlarr:/,/^  bazarr:/p')
lacks "$sonarr_block" 'ports:' 'Sonarr has no base port'
lacks "$radarr_block" 'ports:' 'Radarr has no base port'
lacks "$prowlarr_block" 'ports:' 'Prowlarr has no base port'
has "$sonarr_block" '${MEDIA_ROOT:?Set MEDIA_ROOT}:/data' 'Sonarr has one broad data mount'
has "$radarr_block" '${MEDIA_ROOT:?Set MEDIA_ROOT}:/data' 'Radarr has one broad data mount'
lacks "$prowlarr_block" 'MEDIA_ROOT' 'Prowlarr has no media mount'

CONFIG_ROOT=/
MEDIA_ROOT=$TEST_ROOT/media
DEPLOY_ROOT=$TEST_ROOT/deploy
fails 'unsafe root rejected' check_media
CONFIG_ROOT=$TEST_ROOT/config
mkdir -p "$MEDIA_ROOT/library/tv" "$MEDIA_ROOT/library/anime" "$MEDIA_ROOT/library/movies" "$MEDIA_ROOT/torrents/tv" "$MEDIA_ROOT/torrents/anime"
findmnt() { printf '/\n'; }
fails 'missing media path rejected' check_media
unset -f findmnt

mock=$TEST_ROOT/check
ENV_FILE=$mock/.env
RUNTIME_ROOT=$mock/runtime
CONFIG_ROOT=$mock/config
MEDIA_ROOT=$mock/media
DEPLOY_ROOT=$mock
require_commands() { :; }
runtime_identity() { RUNTIME_UID=$(id -u); RUNTIME_GID=$(id -g); }
load_image_pins() { :; }
validate_loopback() { :; }
check_media() { :; }
check_scope() { :; }
check_ports_credentials() { :; }
validate_compose() { :; }
check_qbittorrent() { :; }
output=$(run_check 2>&1)
[ ! -e "$mock" ] && ok 'check mode is non-mutating' || bad 'check mode is non-mutating'
has "$output" 'Read-only automation check passed' 'check reports immutability'
if printf '%s\n' "$output" | grep -Eq 'PASSWORD=|API_KEY=|sha256:[0-9a-f]{64}'; then bad 'check logs redact secrets'; else ok 'check logs redact secrets'; fi

mkdir -p "$TEST_ROOT/hard/media/torrents" "$TEST_ROOT/hard/media/library"
MEDIA_ROOT=$TEST_ROOT/hard/media
RUNTIME_UID=$(id -u); RUNTIME_GID=$(id -g)
hardlink_test >/dev/null 2>&1 && ok 'temporary hardlink test passes' || bad 'temporary hardlink test passes'
if find "$MEDIA_ROOT" -name '.veinfin-hardlink-test-*' -print -quit | grep -q .; then bad 'hardlink test leaves no artifact'; else ok 'hardlink test leaves no artifact'; fi

printf '\nTests: %d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
