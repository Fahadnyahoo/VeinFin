#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=${VEINFIN_REPO_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd -P)}
DEPLOY_ROOT=${VEINFIN_DEPLOY_ROOT:-$REPO_ROOT}
RUNTIME_ROOT=$DEPLOY_ROOT/runtime
STATE=$RUNTIME_ROOT/state
CANDIDATE_ROOT=$RUNTIME_ROOT/legacy-ui-candidate
STAGING=$RUNTIME_ROOT/generated/legacy-ui-plugins
LOCK=$REPO_ROOT/config/plugins.lock
ASSET_LOCK=$REPO_ROOT/config/legacy-ui-assets.lock
COMPOSE=$REPO_ROOT/compose/legacy-ui-candidate.yaml
HELPER=$SCRIPT_DIR/legacy_ui.py
PLUGIN_HELPER=$SCRIPT_DIR/plugins.py
PROJECT=veinfin-legacy-candidate
PORT=${VEINFIN_LEGACY_CANDIDATE_PORT:-18096}
BASE_URL=http://127.0.0.1:$PORT
MARKER=$STATE/legacy-ui-candidate-complete
UI_MARKER=$STATE/legacy-ui-candidate-ui-configured
PROMOTED_MARKER=$STATE/legacy-ui-promoted
PROMOTION_POINTER=$STATE/legacy-ui-promotion-backup-path
STARTED=$STATE/legacy-ui-candidate-started
BASELINE_POINTER=$STATE/legacy-ui-production-baseline-path
SSH_PEER=
WORK=

# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/lib/common.sh"

info(){ printf 'INFO: %s\n' "$*"; }
pass(){ printf 'PASS: %s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
cleanup(){ [ -z "${WORK:-}" ] || [ ! -d "$WORK" ] || find "$WORK" -depth -delete 2>/dev/null || true; vf_cleanup; }
trap cleanup EXIT HUP INT TERM

usage(){ cat <<'EOF'
VeinFin isolated Jellyfin 10.11 legacy-UI candidate

Usage:
  scripts/deploy/legacy-ui.sh --help
  scripts/deploy/legacy-ui.sh --check
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/legacy-ui.sh --apply
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/legacy-ui.sh --verify
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/legacy-ui.sh --promote
  sudo --preserve-env=SSH_CONNECTION scripts/deploy/legacy-ui.sh --rollback

--check validates the immutable image, plugin and asset locks and proves the
production boundary without mutation. --apply creates a separate candidate,
bootstraps its sole administrator and three read-only libraries, installs each
locked plugin incrementally, and scans only the candidate database. --verify is
read-only. --rollback stops and removes only the candidate container and
network; it preserves candidate data and every protected production backup.

--promote performs the protected blue/green cutover after browser validation.
It preserves the complete prior Jellyfin directory and environment for an
immediate rollback. Caddy and every non-Jellyfin service remain unchanged.
EOF
}

env_value(){ awk -F= -v key="$1" '$1==key{n++;v=substr($0,index($0,"=")+1)}END{if(n!=1)exit 1;print v}' "$REPO_ROOT/.env"; }
file_mode(){ stat -c '%a' "$1"; }
candidate_id(){ docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" --filter 'label=com.docker.compose.service=jellyfin-legacy-candidate'; }
production_id(){ docker ps -aq --filter "label=com.docker.compose.project=$(env_value COMPOSE_PROJECT_NAME)" --filter "label=com.docker.compose.service=$1"; }

validate_ssh(){
  [ -n "${SSH_CONNECTION:-}" ] || die "SSH_CONNECTION is required"
  ss -H -tn state established | "$SCRIPT_DIR/download_lifecycle.py" validate-ssh >/dev/null || die "SSH connection context is invalid"
  SSH_PEER=$SSH_CONNECTION
}

elevate(){
  validate_ssh
  if [ "$(id -u)" -ne 0 ]; then exec sudo --preserve-env=SSH_CONNECTION "$SCRIPT_DIR/legacy-ui.sh" "$@"; fi
}

require_commands(){
  local command
  for command in awk curl docker find install mktemp python3 sha256sum ss stat tar; do command -v "$command" >/dev/null || die "required command missing: $command"; done
  docker info >/dev/null || die "Docker is unavailable"
  docker compose version >/dev/null || die "Docker Compose is unavailable"
}

compose(){
  LEGACY_CANDIDATE_ROOT=$CANDIDATE_ROOT LEGACY_CANDIDATE_PORT=$PORT \
    docker compose --project-name "$PROJECT" --env-file "$REPO_ROOT/.env" -f "$COMPOSE" "$@"
}

production_compose(){
  docker compose --project-directory "$REPO_ROOT" --env-file "$REPO_ROOT/.env" \
    -f "$REPO_ROOT/compose.yaml" -f "$REPO_ROOT/compose/jellyfin-loopback.yaml" \
    -f "$REPO_ROOT/compose/qbittorrent-loopback.yaml" -f "$REPO_ROOT/compose/arr-loopback.yaml" "$@"
}

production_fingerprints(){
  local service id
  for service in reverse-proxy jellyfin qbittorrent sonarr radarr prowlarr bazarr seerr flaresolverr veinfin-panel veinfin-agent; do
    id=$(production_id "$service"); [ -n "$id" ] || die "$service is absent"
    printf '%s|%s|%s|%s\n' "$service" "$id" "$(docker inspect --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$id")" "$(docker inspect --format '{{.RestartCount}}' "$id")"
  done
}

record_production_baseline(){
  local out
  out=$RUNTIME_ROOT/backups/legacy-ui/$(date -u +%Y%m%dT%H%M%SZ)-production-baseline
  install -d -o root -g root -m 0700 "$RUNTIME_ROOT/backups/legacy-ui" "$out"
  production_fingerprints | vf_atomic_write "$out/container-fingerprints" 0600
  ss -H -lntup | vf_atomic_write "$out/listeners" 0600
  iptables-save | vf_atomic_write "$out/iptables.save" 0600
  "$PLUGIN_HELPER" snapshot --lock "$REPO_ROOT/config/plugins.lock" --username "$(env_value MANAGEMENT_USERNAME)" \
    --password-file "$RUNTIME_ROOT/secrets/management-password" --output "$out/jellyfin-state.json"
  printf '%s\n' "$out" | vf_atomic_write "$BASELINE_POINTER" 0600
  chown -R root:root "$out" "$BASELINE_POINTER"
}

verify_production(){
  local service id state
  for service in reverse-proxy jellyfin qbittorrent sonarr radarr prowlarr bazarr seerr flaresolverr veinfin-panel veinfin-agent; do
    id=$(production_id "$service"); [ -n "$id" ] || die "$service is absent"
    state=$(docker inspect --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{.RestartCount}}' "$id")
    [ "$state" = 'running|healthy|0' ] || die "$service is not healthy with zero restarts"
  done
  [ "$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 20 "https://$(env_value PUBLIC_HOSTNAME)/System/Info/Public")" = 200 ] || die "production HTTPS failed"
  SSH_CONNECTION=$SSH_PEER /usr/local/sbin/veinfin-firewall --verify >/dev/null || die "firewall verification failed"
  ! ss -H -lnt 'sport = :80 or sport = :2375 or sport = :2376' | grep -q . || die "a prohibited listener is present"
  local expected=12.3.0
  [ ! -f "$PROMOTED_MARKER" ] || expected=10.11.11
  [ "$(python3 -c 'import json,urllib.request;print(json.load(urllib.request.urlopen("http://127.0.0.1:8096/System/Info/Public"))["Version"])')" = "$expected" ] || die "production Jellyfin version changed"
}

wait_production(){
  local attempt=0 id state
  while [ "$attempt" -lt 120 ]; do
    id=$(production_id jellyfin)
    state=$([ -n "$id" ] && docker inspect --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$id" 2>/dev/null || true)
    if [ "$state" = 'running|healthy' ] && curl -fsS --max-time 5 http://127.0.0.1:8096/System/Info/Public >/dev/null; then return 0; fi
    sleep 2; attempt=$((attempt+1))
  done
  return 1
}

validate_contracts(){
  "$PLUGIN_HELPER" validate-lock --lock "$LOCK"
  python3 -m py_compile "$HELPER" "$PLUGIN_HELPER"
  grep -Fq 'jellyfin/jellyfin:10.11.11@sha256:aefb67e6a7ff1debdd154a78a7bbb780fd0c873d8639210a7f6a2016ad2b35db' "$COMPOSE" || die "candidate image pin changed"
  grep -Eq '^KEFIN_TWEAKS\|KefinTweaks\|0\.5\.3\|7ff0812d88fb923e5dc7fdb3262a84b283fd627a\|MIT\|https://github\.com/ranaldsgift/KefinTweaks\|https://github\.com/ranaldsgift/KefinTweaks/archive/refs/tags/v0\.5\.3\.tar\.gz\|[0-9a-f]{64}$' "$ASSET_LOCK" || die "KefinTweaks asset lock is invalid"
  [ "$(awk -F'|' '!/^#/ && NF{n++}END{print n+0}' "$LOCK")" -eq 12 ] || die "legacy server-plugin lock must contain twelve plugins"
  LEGACY_CANDIDATE_ROOT=$CANDIDATE_ROOT LEGACY_CANDIDATE_PORT=$PORT docker compose --project-name "$PROJECT" --env-file "$REPO_ROOT/.env" -f "$COMPOSE" config >/dev/null
}

preflight(){
  require_commands
  [ -f "$REPO_ROOT/.env" ] && [ "$(file_mode "$REPO_ROOT/.env")" = 600 ] || die ".env is missing or unsafe"
  [ -f "$RUNTIME_ROOT/secrets/management-password" ] && [ "$(file_mode "$RUNTIME_ROOT/secrets/management-password")" = 600 ] || die "management credential is missing or unsafe"
  [[ $PORT =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] || die "candidate port is invalid"
  if ss -H -lnt "sport = :$PORT" | grep -q . && [ -z "$(candidate_id)" ]; then die "candidate loopback port is occupied"; fi
  validate_contracts
  verify_production
}

wait_candidate(){
  local attempt=0 id state
  id=$(candidate_id); [ -n "$id" ] || return 1
  while [ "$attempt" -lt 120 ]; do
    state=$(docker inspect --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$id" 2>/dev/null || true)
    if [ "$state" = 'running|healthy' ] && curl -fsS --max-time 5 "$BASE_URL/System/Info/Public" >/dev/null; then return 0; fi
    sleep 2; attempt=$((attempt+1))
  done
  return 1
}

stage_plugins(){
  install -d -o root -g root -m 0700 "$STAGING"
  "$PLUGIN_HELPER" stage --lock "$LOCK" --output "$STAGING"
  find "$STAGING" -type d -exec chmod 0700 {} +
  find "$STAGING" -type f -exec chmod 0600 {} +
}

stage_kefin(){
  local url digest archive top uid gid
  IFS='|' read -r _ _ _ _ _ _ url digest < <(awk -F'|' '!/^#/ && NF{print;exit}' "$ASSET_LOCK")
  WORK=${WORK:-$(mktemp -d /tmp/veinfin-legacy-ui.XXXXXX)}; chmod 0700 "$WORK"
  archive=$WORK/kefin.tar.gz
  curl -fL --retry 3 --connect-timeout 20 "$url" -o "$archive"
  [ "$(sha256sum "$archive" | awk '{print $1}')" = "$digest" ] || die "KefinTweaks artifact hash mismatch"
  ! tar -tzf "$archive" | grep -Eq '(^/|(^|/)\.\.(/|$))' || die "KefinTweaks archive contains an unsafe path"
  top=$(tar -tzf "$archive" | sed -n '1{s,/.*,,;p;}'); [ "$top" = KefinTweaks-0.5.3 ] || die "KefinTweaks archive root changed"
  rm -rf -- "$CANDIDATE_ROOT/KefinTweaks.new"
  install -d -m 0700 "$CANDIDATE_ROOT/KefinTweaks.new"
  tar -xzf "$archive" --strip-components=1 -C "$CANDIDATE_ROOT/KefinTweaks.new"
  install -m 0640 "$REPO_ROOT/templates/jellyfin/legacy-cinematic.css" "$CANDIDATE_ROOT/KefinTweaks.new/veinfin-cinematic.css"
  uid=$(env_value PUID); gid=$(env_value PGID)
  find "$CANDIDATE_ROOT/KefinTweaks.new" -type d -exec chmod 0750 {} +
  find "$CANDIDATE_ROOT/KefinTweaks.new" -type f -exec chmod 0640 {} +
  chown -R "$uid:$gid" "$CANDIDATE_ROOT/KefinTweaks.new"
  mv "$CANDIDATE_ROOT/KefinTweaks.new" "$CANDIDATE_ROOT/KefinTweaks"
}

candidate_snapshot(){
  "$HELPER" snapshot --base-url "$BASE_URL" --username "$(env_value MANAGEMENT_USERNAME)" \
    --password-file "$RUNTIME_ROOT/secrets/management-password" --output "$1"
}

verify_candidate(){
  local id state report expected actual
  id=$(candidate_id); [ -n "$id" ] || die "candidate container is absent"
  state=$(docker inspect --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$id")
  [ "$state" = 'running|healthy' ] || die "candidate is not healthy"
  [ "$(docker inspect --format '{{.Config.Image}}' "$id")" = 'jellyfin/jellyfin:10.11.11@sha256:aefb67e6a7ff1debdd154a78a7bbb780fd0c873d8639210a7f6a2016ad2b35db' ] || die "candidate image differs from lock"
  docker inspect --format '{{json .HostConfig.PortBindings}}' "$id" | grep -Fq '"HostIp":"127.0.0.1"' || die "candidate is not loopback-only"
  ! docker inspect --format '{{range .Mounts}}{{println .Source "|" .Destination "|" .RW}}{{end}}' "$id" | grep -Eq '(docker\.sock|downloads|torrents)' || die "candidate has a prohibited mount"
  docker inspect --format '{{range .Mounts}}{{println .Destination "|" .RW}}{{end}}' "$id" | grep -Eq '^/data/library[[:space:]]*\|[[:space:]]*false$' || die "candidate media is not read-only"
  report=$STATE/legacy-ui-candidate-state.json; candidate_snapshot "$report"
  python3 - "$LOCK" "$report" <<'PY'
import json,sys
lock=[]
for line in open(sys.argv[1]):
    if line.strip() and not line.startswith('#'):
        p=line.rstrip('\n').split('|'); lock.append((p[2].replace('-','').lower(),p[3],p[1]))
s=json.load(open(sys.argv[2]))
if s['version']!='10.11.11': raise SystemExit('candidate version mismatch')
if s['users']!=1: raise SystemExit('candidate user count mismatch')
if len(s['libraries'])!=3: raise SystemExit('candidate library count mismatch')
installed={(p.get('id') or '').replace('-','').lower():(p.get('version'),p.get('status')) for p in s['plugins']}
for guid,version,name in lock:
    if installed.get(guid)!=(version,'Active'): raise SystemExit(name+' is not active at the locked version')
if s['counts'].get('Episode')!=170 or s['counts'].get('Series')!=1 or s['counts'].get('Season')!=1:
    raise SystemExit('candidate media count mismatch')
if not s['episode_paths_inside_anime']: raise SystemExit('candidate episode path escaped Anime')
PY
  verify_production
  pass "candidate and production boundaries verified"
}

verify_live_legacy(){
  local report id state
  id=$(production_id jellyfin); [ -n "$id" ] || die "promoted Jellyfin container is absent"
  state=$(docker inspect --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{.RestartCount}}' "$id")
  [ "$state" = 'running|healthy|0' ] || die "promoted Jellyfin is not healthy with zero restarts"
  [ "$(docker inspect --format '{{.Config.Image}}' "$id")" = 'jellyfin/jellyfin:10.11.11@sha256:aefb67e6a7ff1debdd154a78a7bbb780fd0c873d8639210a7f6a2016ad2b35db' ] || die "promoted Jellyfin image differs from lock"
  report=$STATE/legacy-ui-live-state.json
  "$HELPER" snapshot --base-url http://127.0.0.1:8096 --username "$(env_value MANAGEMENT_USERNAME)" \
    --password-file "$RUNTIME_ROOT/secrets/management-password" --output "$report"
  python3 - "$LOCK" "$report" <<'PY'
import json,sys
locked=[]
for line in open(sys.argv[1]):
    if line.strip() and not line.startswith('#'):
        p=line.rstrip('\n').split('|'); locked.append((p[2].replace('-','').lower(),p[3],p[1]))
s=json.load(open(sys.argv[2]))
if s['version']!='10.11.11' or s['users']!=1 or len(s['libraries'])!=3: raise SystemExit('promoted server contract mismatch')
if s['counts'].get('Episode')!=170 or s['counts'].get('Series')!=1 or s['counts'].get('Season')!=1: raise SystemExit('promoted media count mismatch')
installed={(p.get('id') or '').replace('-','').lower():(p.get('version'),p.get('status')) for p in s['plugins']}
for guid,version,name in locked:
    if installed.get(guid)!=(version,'Active'): raise SystemExit(name+' is not active after promotion')
PY
  [ "$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 20 "https://$(env_value PUBLIC_HOSTNAME)/System/Info/Public")" = 200 ] || die "promoted public HTTPS failed"
  [ "$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 20 "https://$(env_value PUBLIC_HOSTNAME)/web/KefinTweaks/injector.js")" = 200 ] || die "promoted pinned UI asset is unavailable"
  SSH_CONNECTION=$SSH_PEER /usr/local/sbin/veinfin-firewall --verify >/dev/null || die "firewall verification failed after promotion"
  ! ss -H -lnt 'sport = :80 or sport = :2375 or sport = :2376' | grep -q . || die "a prohibited listener appeared after promotion"
  pass "promoted Jellyfin, plugins, libraries, HTTPS, UI assets, and firewall verified"
}

restore_promotion(){
  local backup=$1 config_root failed
  [ -d "$backup/original-jellyfin" ] && [ -f "$backup/environment" ] || die "promotion rollback backup is incomplete"
  config_root=$(env_value CONFIG_ROOT)
  production_compose stop jellyfin >/dev/null 2>&1 || true
  failed=$backup/failed-legacy-jellyfin
  [ ! -e "$failed" ] || die "promotion rollback quarantine already exists"
  [ ! -e "$config_root/jellyfin" ] || mv "$config_root/jellyfin" "$failed"
  mv "$backup/original-jellyfin" "$config_root/jellyfin"
  install -o root -g root -m 0600 "$backup/environment" "$REPO_ROOT/.env"
  [ ! -f "$backup/compose.yaml" ] || install -o root -g root -m 0644 "$backup/compose.yaml" "$REPO_ROOT/compose.yaml"
  production_compose up -d --no-deps --force-recreate jellyfin >/dev/null
  wait_production || die "Jellyfin 12.3 did not recover after promotion rollback"
  [ "$(python3 -c 'import json,urllib.request;print(json.load(urllib.request.urlopen("http://127.0.0.1:8096/System/Info/Public"))["Version"])')" = 12.3.0 ] || die "promotion rollback restored the wrong Jellyfin version"
  rm -f -- "$PROMOTED_MARKER"
  pass "Jellyfin 12.3 and its original configuration were restored"
}

do_promote(){
  elevate --promote
  if [ -f "$PROMOTED_MARKER" ]; then
    validate_contracts; verify_live_legacy; return
  fi
  preflight
  [ -f "$MARKER" ] && [ -f "$UI_MARKER" ] || die "verified candidate completion markers are absent"
  verify_candidate
  [ -f "$STATE/legacy-ui-intro-segments.json" ] || die "intro segment validation evidence is absent"
  [ -f "$STATE/legacy-ui-user-state-sync.json" ] || die "user-state preservation evidence is absent"
  local config_root stamp backup production_jellyfin
  config_root=$(env_value CONFIG_ROOT); stamp=$(date -u +%Y%m%dT%H%M%SZ)
  backup=$RUNTIME_ROOT/backups/legacy-ui/$stamp-pre-promotion
  install -d -o root -g root -m 0700 "$backup"
  install -o root -g root -m 0600 "$REPO_ROOT/.env" "$backup/environment"
  install -o root -g root -m 0600 "$REPO_ROOT/compose.yaml" "$backup/compose.yaml"
  production_fingerprints | vf_atomic_write "$backup/container-fingerprints" 0600
  ss -H -lntup | vf_atomic_write "$backup/listeners-before" 0600
  printf '%s\n' "$backup" | vf_atomic_write "$PROMOTION_POINTER" 0600
  chown -R root:root "$backup" "$PROMOTION_POINTER"
  compose stop jellyfin-legacy-candidate >/dev/null
  production_jellyfin=$(production_id jellyfin)
  docker stop --time 30 "$production_jellyfin" >/dev/null
  mv "$config_root/jellyfin" "$backup/original-jellyfin"
  install -d -o root -g root -m 0750 "$config_root/jellyfin"
  cp -a "$CANDIDATE_ROOT/config" "$config_root/jellyfin/config"
  cp -a "$CANDIDATE_ROOT/cache" "$config_root/jellyfin/cache"
  cp -a "$CANDIDATE_ROOT/KefinTweaks" "$config_root/jellyfin/KefinTweaks"
  awk -F= 'BEGIN{OFS="="} $1=="JELLYFIN_IMAGE_TAG"{$0="JELLYFIN_IMAGE_TAG=10.11.11@sha256:aefb67e6a7ff1debdd154a78a7bbb780fd0c873d8639210a7f6a2016ad2b35db"} {print}' "$backup/environment" | vf_atomic_write "$REPO_ROOT/.env" 0600
  chown root:root "$REPO_ROOT/.env"
  if ! production_compose config --quiet || ! production_compose pull jellyfin || ! production_compose up -d --no-deps --force-recreate jellyfin >/dev/null || ! wait_production || ! verify_live_legacy; then
    restore_promotion "$backup"
    die "legacy UI promotion failed and Jellyfin 12.3 was restored"
  fi
  printf 'promoted\n' | vf_atomic_write "$PROMOTED_MARKER" 0600; chown root:root "$PROMOTED_MARKER"
  verify_production
  pass "isolated Jellyfin 10.11 legacy UI candidate promoted with protected rollback"
}

configure_ui(){
  local uid gid
  uid=$(env_value PUID); gid=$(env_value PGID)
  install -o "$uid" -g "$gid" -m 0640 "$REPO_ROOT/templates/jellyfin/legacy-cinematic.css" "$CANDIDATE_ROOT/KefinTweaks/veinfin-cinematic.css"
  "$HELPER" configure --base-url "$BASE_URL" --username "$(env_value MANAGEMENT_USERNAME)" \
    --password-file "$RUNTIME_ROOT/secrets/management-password" --output "$STATE/legacy-ui-desired-configuration.json"
  compose restart jellyfin-legacy-candidate >/dev/null
  wait_candidate || die "candidate failed after reviewed UI configuration"
  printf 'configured\n' | vf_atomic_write "$UI_MARKER" 0600; chown root:root "$UI_MARKER"
  pass "reviewed legacy UI configuration persisted"
}

install_one(){
  local key name version uid gid source destination id
  key=$1
  IFS='|' read -r _ name _ version _ < <(awk -F'|' -v k="$key" '$1==k{print;exit}' "$LOCK")
  [ -n "$name" ] || die "locked plugin key is missing: $key"
  source=$STAGING/$key-$version; destination=$CANDIDATE_ROOT/config/plugins/${name}_$version
  uid=$(env_value PUID); gid=$(env_value PGID)
  compose stop jellyfin-legacy-candidate >/dev/null
  install -d -o "$uid" -g "$gid" -m 0750 "$destination"
  find "$source" -maxdepth 1 -type f -exec install -o "$uid" -g "$gid" -m 0640 {} "$destination/" \;
  compose start jellyfin-legacy-candidate >/dev/null
  wait_candidate || die "$name made the candidate unhealthy"
  candidate_snapshot "$STATE/legacy-ui-after-$key.json"
  python3 - "$STATE/legacy-ui-after-$key.json" "$name" "$version" <<'PY'
import json,sys
p=[x for x in json.load(open(sys.argv[1]))['plugins'] if x.get('name')==sys.argv[2]]
if len(p)!=1 or p[0].get('version')!=sys.argv[3] or p[0].get('status')!='Active': raise SystemExit(sys.argv[2]+' failed incremental activation')
PY
  pass "$name $version active"
}

do_check(){ elevate --check; preflight; [ ! -e "$STARTED" ] || die "an interrupted candidate apply requires review"; pass "legacy candidate readiness checks passed without changes"; }

do_apply(){
  elevate --apply
  if [ -f "$PROMOTED_MARKER" ]; then
    info "legacy UI is already promoted; running verification only"
    preflight; verify_live_legacy; return
  fi
  if [ -f "$MARKER" ]; then
    preflight
    if [ ! -f "$UI_MARKER" ]; then configure_ui; else info "legacy candidate is complete; running verification only"; fi
    verify_candidate
    return
  fi
  preflight
  if [ -f "$STARTED" ] && [ -n "$(candidate_id)" ]; then
    info "resuming the interrupted candidate at library scan and verification"
    if ! python3 - "$STATE/legacy-ui-candidate-state.json" <<'PY'
import json,sys
try: x=json.load(open(sys.argv[1]))
except (OSError,ValueError): raise SystemExit(1)
raise SystemExit(0 if x.get('counts')=={'Episode':170,'Season':1,'Series':1} and x.get('episode_paths_inside_anime') is True else 1)
PY
    then
      "$HELPER" libraries --base-url "$BASE_URL" --username "$(env_value MANAGEMENT_USERNAME)" \
        --password-file "$RUNTIME_ROOT/secrets/management-password" --scan --output "$STATE/legacy-ui-candidate-state.json"
    else
      info "completed candidate scan evidence is present; not scanning again"
    fi
    verify_candidate
    printf 'complete\n' | vf_atomic_write "$MARKER" 0600; chown root:root "$MARKER"; rm -f -- "$STARTED"
    pass "isolated legacy UI candidate resumed and verified"
    return
  fi
  [ ! -e "$STARTED" ] || die "an interrupted candidate apply requires rollback or review"
  record_production_baseline
  printf 'started\n' | vf_atomic_write "$STARTED" 0600; chown root:root "$STARTED"
  local uid gid
  uid=$(env_value PUID); gid=$(env_value PGID)
  install -d -o root -g root -m 0700 "$CANDIDATE_ROOT"
  install -d -o "$uid" -g "$gid" -m 0750 "$CANDIDATE_ROOT/config" "$CANDIDATE_ROOT/cache"
  stage_plugins; stage_kefin
  compose pull jellyfin-legacy-candidate
  compose up -d --no-deps jellyfin-legacy-candidate
  wait_candidate || die "clean candidate did not become healthy"
  "$HELPER" bootstrap --base-url "$BASE_URL" --username "$(env_value MANAGEMENT_USERNAME)" --password-file "$RUNTIME_ROOT/secrets/management-password"
  local key
  for key in FILE_TRANSFORMATION JAVASCRIPT_INJECTOR JELLYFIN_ENHANCED MEDIA_BAR_ENHANCED HOME_SCREEN_SECTIONS CUSTOM_TABS HOVER_TRAILER INPLAYER_EPISODE_PREVIEW INTRO_SKIPPER LOCAL_POSTERS ANILIST ANISEARCH; do install_one "$key"; done
  "$HELPER" libraries --base-url "$BASE_URL" --username "$(env_value MANAGEMENT_USERNAME)" \
    --password-file "$RUNTIME_ROOT/secrets/management-password" --scan --output "$STATE/legacy-ui-candidate-state.json"
  verify_candidate
  configure_ui
  verify_candidate
  printf 'complete\n' | vf_atomic_write "$MARKER" 0600; chown root:root "$MARKER"; rm -f -- "$STARTED"
  pass "isolated legacy UI candidate is ready for configuration and browser validation"
}

do_verify(){
  elevate --verify
  preflight
  if [ -f "$PROMOTED_MARKER" ]; then verify_live_legacy; return; fi
  [ -f "$MARKER" ] || die "candidate completion marker is absent"
  verify_candidate
}

do_rollback(){
  elevate --rollback
  if [ -f "$PROMOTED_MARKER" ]; then
    [ -f "$PROMOTION_POINTER" ] || die "promotion backup pointer is absent"
    restore_promotion "$(tr -d '\r\n' <"$PROMOTION_POINTER")"
    verify_production
    return
  fi
  compose down --remove-orphans
  rm -f -- "$STARTED" "$MARKER" "$UI_MARKER"
  verify_production
  pass "candidate container and network removed; candidate data and protected backups preserved"
}

[ "$#" -eq 1 ] || { usage >&2; exit 2; }
case "$1" in
  --help) usage;;
  --check) do_check;;
  --apply) do_apply;;
  --verify) do_verify;;
  --promote) do_promote;;
  --rollback) do_rollback;;
  *) usage >&2; exit 2;;
esac
