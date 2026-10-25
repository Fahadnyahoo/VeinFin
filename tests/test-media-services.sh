#!/usr/bin/env bash
set -u
set -o pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT=$ROOT/scripts/deploy/media-services.sh
HELPER=$ROOT/scripts/deploy/media_services_api.py
COMPOSE=$ROOT/compose.yaml
OVERRIDE=$ROOT/compose/media-services-loopback.yaml
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
help=$($SCRIPT --help 2>&1)
has "$help" 'scripts/deploy/media-services.sh --check' 'help documents check'
has "$help" 'scripts/deploy/media-services.sh --apply' 'help documents apply'
has "$help" 'scripts/deploy/media-services.sh --verify' 'help documents verify'
has "$help" '6767:127.0.0.1:6767 -L 5055:127.0.0.1:5055 user@host' 'help uses generic SSH tunnels'
has "$help" 'never performs a real sync' 'help documents Recyclarr safety'

VEINFIN_MEDIA_SERVICES_LIBRARY_ONLY=1 source "$SCRIPT"
set +e
trap cleanup EXIT HUP INT TERM
validate_loopback >/dev/null 2>&1 && ok 'exact loopback override accepted' || bad 'exact loopback override accepted'
for replacement in '0.0.0.0' '::' '192.0.2.55'; do
  file=$TEST_ROOT/media_services-$(printf %s "$replacement" | tr ':.' _).yaml
  sed "s/host_ip: 127.0.0.1/host_ip: $replacement/g" "$OVERRIDE" >"$file"
  saved=$MEDIA_SERVICES_LOOPBACK; MEDIA_SERVICES_LOOPBACK=$file
  fails "unsafe bind rejected: $replacement" validate_loopback
  MEDIA_SERVICES_LOOPBACK=$saved
done

script_text=$(<"$SCRIPT")
helper_text=$(<"$HELPER")
compose_text=$(<"$COMPOSE")
bazarr_block=$(printf '%s\n' "$compose_text" | sed -n '/^  bazarr:/,/^  seerr:/p')
seerr_block=$(printf '%s\n' "$compose_text" | sed -n '/^  seerr:/,/^  recyclarr:/p')
recyclarr_block=$(printf '%s\n' "$compose_text" | sed -n '/^  recyclarr:/,/^  flaresolverr:/p')
flare_block=$(printf '%s\n' "$compose_text" | sed -n '/^  flaresolverr:/,/^networks:/p')

has "$script_text" 'pull bazarr seerr recyclarr flaresolverr' 'apply pulls exactly four Media services images'
has "$script_text" 'up -d --no-deps bazarr seerr flaresolverr' 'apply starts exactly three long-running services'
has "$script_text" 'stop bazarr seerr flaresolverr' 'pressure rollback stops only new services'
has "$script_text" 'media_services-preserved-containers.txt' 'five existing fingerprints are preserved'
has "$script_text" 'media_services-rsync-before.txt' 'external rsync identity is guarded'
has "$script_text" 'ps -C rsync -o pid=,lstart=,comm= || true' 'clean host without rsync is supported'
has "$script_text" 'Management password: %s' 'final root-only credential summary retains the generated management password'
has "$script_text" 'sync --preview' 'only official Recyclarr preview is invoked'
lacks "$script_text" 'recyclarr sync >' 'no unguarded Recyclarr sync invocation exists'
has "$script_text" 'validated-not-applied' 'Recyclarr no-apply state is recorded'
has "$script_text" 'chmod 0600' 'secret-bearing rendered files enforce mode 0600'
has "$script_text" 'os.replace(tmp,p)' 'Recyclarr config replacement is atomic'
has "$helper_text" 'len(set(keys.values()) | {bazarr, seerr}) != 5' 'five application API keys must be unique'
has "$helper_text" 'hostname="jellyfin", port=8096' 'Seerr uses Jellyfin Docker DNS'
has "$helper_text" '"sonarr", 8989' 'Bazarr and Seerr use Sonarr Docker DNS'
has "$helper_text" '"radarr", 7878' 'Bazarr and Seerr use Radarr Docker DNS'
has "$helper_text" 'http://flaresolverr:8191' 'Prowlarr uses internal FlareSolverr URL'
has "$helper_text" 'enabled_providers' 'Bazarr provider emptiness is verified'
has "$helper_text" 'Jellyfin has a configured library' 'Jellyfin zero-library state is verified'
has "$helper_text" 'Seerr contains a request' 'Seerr zero-request state is verified'
has "$helper_text" 'Prowlarr contains an indexer' 'Prowlarr zero-indexer state is verified'
lacks "$helper_text" '/Library/Media/Updated' 'helper never triggers a Jellyfin scan'
lacks "$helper_text" 'settings/jellyfin/library?sync' 'helper never triggers a Seerr library sync'
lacks "$helper_text" '/api/v3/series' 'helper never creates a series'
lacks "$helper_text" '/api/v3/movie' 'helper never creates a movie'
lacks "$helper_text" 'magnet:' 'helper contains no torrent payload'

lacks "$bazarr_block" 'ports:' 'Bazarr has no base port'
lacks "$seerr_block" 'ports:' 'Seerr has no base port'
lacks "$flare_block" 'ports:' 'FlareSolverr has no host port'
lacks "$flare_block" 'volumes:' 'FlareSolverr has no mounts'
has "$script_text" "set((c['Config'].get('Volumes') or {}).keys()) == {'/config'}" 'upstream FlareSolverr anonymous volume is narrowly verified'
has "$recyclarr_block" 'profiles: ["automation"]' 'Recyclarr is on-demand only'
has "$recyclarr_block" 'command: ["sync", "--preview"]' 'Recyclarr default command is non-applying preview'
lacks "$recyclarr_block" 'MEDIA_ROOT' 'Recyclarr has no media access'
lacks "$seerr_block" 'MEDIA_ROOT' 'Seerr has no media access'
has "$bazarr_block" '${MEDIA_ROOT:?Set MEDIA_ROOT}/library/movies:/data/library/movies' 'Bazarr movie mount is sliced'
has "$bazarr_block" '${MEDIA_ROOT:?Set MEDIA_ROOT}/library/tv:/data/library/tv' 'Bazarr TV mount is sliced'
has "$bazarr_block" '${MEDIA_ROOT:?Set MEDIA_ROOT}/library/anime:/data/library/anime' 'Bazarr anime mount is sliced'
lacks "$bazarr_block" '${MEDIA_ROOT:?Set MEDIA_ROOT}:/data' 'Bazarr lacks broad media access'
lacks "$compose_text" '/var/run/docker.sock' 'Compose never mounts the raw Docker socket'

mock=$TEST_ROOT/check
DEPLOY_ROOT=$mock; RUNTIME_ROOT=$mock/runtime; CONFIG_ROOT=$mock/config; MEDIA_ROOT=$mock/media
require_commands() { :; }; runtime_identity() { RUNTIME_UID=$(id -u); RUNTIME_GID=$(id -g); }; ensure_work() { :; }
load_image_pins() { :; }; validate_loopback() { :; }; check_media() { :; }; check_existing() { :; }; check_credentials() { :; }; validate_compose() { :; }
output=$(run_checks 2>&1)
[ ! -e "$mock" ] && ok 'check mode is non-mutating' || bad 'check mode is non-mutating'
if printf '%s\n' "$output" | grep -Eq 'PASSWORD=|API_KEY=|sha256:[0-9a-f]{64}'; then bad 'check logs redact secrets'; else ok 'check logs redact secrets'; fi

mkdir -p "$TEST_ROOT/render/secrets" "$TEST_ROOT/render/runtime/config/recyclarr"
chmod 0700 "$TEST_ROOT/render/secrets" "$TEST_ROOT/render/runtime/config/recyclarr"
printf '%032d\n' 1 >"$TEST_ROOT/render/secrets/sonarr-api-key"
printf '%032d\n' 2 >"$TEST_ROOT/render/secrets/radarr-api-key"
chmod 0600 "$TEST_ROOT/render/secrets/"*-api-key
RUNTIME_ROOT=$TEST_ROOT/render/runtime
mkdir -p "$RUNTIME_ROOT/secrets"
cp "$TEST_ROOT/render/secrets/"*-api-key "$RUNTIME_ROOT/secrets/"
chmod 0600 "$RUNTIME_ROOT/secrets/"*-api-key
RUNTIME_UID=$(id -u); RUNTIME_GID=$(id -g)
write_recyclarr_config >/dev/null 2>&1 && ok 'Recyclarr config renders in a temporary root' || bad 'Recyclarr config renders in a temporary root'
[ "$(file_mode "$RUNTIME_ROOT/config/recyclarr/recyclarr.yml")" = 600 ] && ok 'Recyclarr config mode is 0600' || bad 'Recyclarr config mode is 0600'
before=$(cksum "$RUNTIME_ROOT/config/recyclarr/recyclarr.yml")
write_recyclarr_config >/dev/null 2>&1
[ "$before" = "$(cksum "$RUNTIME_ROOT/config/recyclarr/recyclarr.yml")" ] && ok 'repeated config generation is idempotent' || bad 'repeated config generation is idempotent'

printf '\nTests: %d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
