#!/usr/bin/env bash
set -u
set -o pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT=$ROOT/scripts/deploy/control-panel.sh
APP=$ROOT/panel/app.py
COMPOSE=$ROOT/compose/control-panel.yml
INSTALLER=$ROOT/scripts/installer.sh
FIREWALL=$ROOT/scripts/host/configure-firewall.sh
UNIT=$ROOT/tests/test_control_panel.py
README=$ROOT/README.md
CONTAINERS_DOC=$ROOT/docs/CONTAINERS.md
ROADMAP=$ROOT/docs/ROADMAP.md
PASSED=0 FAILED=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/veinfin-control_panel-test.XXXXXX")
trap 'find "$TMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM
ok(){ printf 'PASS: %s\n' "$1"; PASSED=$((PASSED+1)); }
bad(){ printf 'FAIL: %s\n' "$1"; FAILED=$((FAILED+1)); }
has(){ grep -Fq -- "$2" <<<"$1" && ok "$3" || bad "$3"; }
lacks(){ if grep -Fq -- "$2" <<<"$1"; then bad "$3"; else ok "$3"; fi; }

bash -n "$SCRIPT" "$INSTALLER" "$FIREWALL" && ok 'shell syntax' || bad 'shell syntax'
PYTHONPYCACHEPREFIX=$TMP python3 -m py_compile "$APP" "$UNIT" "$ROOT/scripts/deploy/control_panel_smoke.py" && ok 'Python syntax' || bad 'Python syntax'
PYTHONPYCACHEPREFIX=$TMP python3 "$UNIT" >/dev/null && ok 'offline panel security tests' || bad 'offline panel security tests'

help=$($SCRIPT --help 2>&1)
for mode in --check --apply --verify; do has "$help" "$mode" "help documents $mode"; done
compose=$(<"$COMPOSE"); app=$(<"$APP"); script=$(<"$SCRIPT"); installer=$(<"$INSTALLER"); firewall=$(<"$FIREWALL")
has "$compose" '/var/run/docker.sock:/var/run/docker.sock' 'restricted agent mounts Docker socket'
lacks "$(awk '/veinfin-panel:/{p=1}/veinfin-agent:/{p=0}p' "$COMPOSE")" 'docker.sock' 'panel never mounts Docker socket'
has "$compose" 'internal: true' 'panel-agent network is internal'
lacks "$(awk '/veinfin-agent:/{p=1}p' "$COMPOSE")" 'ports:' 'agent has no published host port'
has "$compose" 'read_only: true' 'custom containers use read-only root filesystems'
has "$compose" 'cap_drop: [ALL]' 'custom containers drop all capabilities'
has "$compose" 'no-new-privileges:true' 'custom containers set no-new-privileges'
has "$app" 'SERVICES = {' 'agent uses a compiled service allowlist'
has "$app" 'container identity failed allowlist validation' 'runtime Compose labels are validated'
for prohibited in '/exec/' '/images/' '/volumes/' '/networks/'; do lacks "$app" "$prohibited" "agent omits unrestricted Docker endpoint $prohibited"; done
has "$app" '__Host-veinfin=' 'session cookie uses host-only prefix'
has "$app" 'HttpOnly; Secure; SameSite=Strict' 'session cookie security attributes are exact'
has "$app" 'server.session_secret = read_secret("SESSION_SECRET_FILE")' 'session cookies use a separate mounted signing secret'
has "$app" 'CSRF validation failed' 'CSRF enforcement exists'
has "$app" 'too many login attempts' 'login rate limiting exists'
has "$app" 'origin rejected' 'login origin validation exists'
lacks "$app" 'innerHTML' 'frontend avoids innerHTML injection sinks'
lacks "$compose" 'Who' 'experimental plugin is absent from Control panel setup Compose'
has "$script" 'two independent panel builds produced one identical immutable image' 'reproducible double build is mandatory'
has "$script" 'VEINFIN_PANEL_IMAGE=%s' 'runtime uses the immutable built image ID'
has "$script" 'control_panel-password-hash' 'only a generated password hash is mounted'
has "$compose" 'SESSION_SECRET_FILE: /run/secrets/session-secret' 'panel receives its session secret through a file mount'
lacks "$script" 'run_helper synthetic' 'Control panel setup never invokes synthetic torrents'
has "$firewall" '--update-management' 'firewall has a guarded management-only transition'
has "$firewall" 'management update may not change any other firewall value' 'firewall transition rejects unrelated drift'
for mode in --install --verify --dry-run --generate-config --check; do has "$($ROOT/install.sh --help)" "$mode" "installer documents $mode"; done
has "$installer" 'configuration host storage firewall core jellyfin qbittorrent arr media_services https libraries indexers quality lifecycle panel final' 'installer declares the complete stage order'
lacks "$installer" 'whos-watching.sh' 'installer excludes experimental plugins'
has "$installer" 'media root must already be mounted and writable' 'installer never initializes missing storage'
has "$script" 'Control panel setup is already complete; running verification only' 'second apply is verification-only'
lacks "$script" 'docker compose down' 'deployment never tears down the stack'
lacks "$script" 'docker system prune' 'deployment never prunes Docker data'
has "$(<"$README")" './install.sh --install' 'README documents the explicit supported installation mode'
lacks "$(<"$README")" 'does not yet install Docker or deploy containers' 'README does not retain the foundation-only deployment claim'
has "$(<"$CONTAINERS_DOC")" 'Only the restricted, unexposed lifecycle agent mounts the Docker socket' 'container contract documents the socket exception'
has "$(<"$ROADMAP")" 'private control panel' 'roadmap records the control panel'

if grep -Eqi '(password|api.?key|token)[[:space:]]*=[[:space:]]*[A-Za-z0-9+/_=-]{24,}' "$SCRIPT" "$APP" "$COMPOSE"; then bad 'no embedded secret values'; else ok 'no embedded secret values'; fi
printf '\nTests: %d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
