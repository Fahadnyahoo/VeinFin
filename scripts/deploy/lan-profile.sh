#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=${VEINFIN_REPO_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd -P)}
ENV_FILE=$REPO_ROOT/.env
BASE=$REPO_ROOT/compose.yaml
LAN=$REPO_ROOT/compose/lan-only.yaml

die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
pass(){ printf 'PASS: %s\n' "$*"; }
env_value(){ awk -F= -v key="$1" '$1==key{n++;v=substr($0,index($0,"=")+1)}END{if(n!=1)exit 1;print v}' "$ENV_FILE"; }
compose(){ docker compose --project-directory "$REPO_ROOT" --env-file "$ENV_FILE" -f "$BASE" -f "$LAN" "$@"; }
service_id(){ docker ps -aq --filter "label=com.docker.compose.project=$(env_value COMPOSE_PROJECT_NAME)" --filter "label=com.docker.compose.service=$1"; }

refresh_media_preservation(){
  local preserved=$REPO_ROOT/runtime/state/media_services-preserved-containers.txt listeners=$REPO_ROOT/runtime/state/media_services-listeners-before.txt id current temporary
  [ -f "$preserved" ] || return 0
  id=$(service_id jellyfin); current=$(docker inspect --format '{{.Id}}|{{.State.StartedAt}}|{{.RestartCount}}' "$id")
  temporary=$(mktemp "${preserved}.XXXXXX")
  awk -v value="jellyfin=$current" 'BEGIN{done=0} /^jellyfin=/{print value;done=1;next} {print} END{if(!done)print value}' "$preserved" >"$temporary"
  chown root:root "$temporary"; chmod 0600 "$temporary"; mv -f "$temporary" "$preserved"
  if [ -f "$listeners" ]; then
    temporary=$(mktemp "${listeners}.XXXXXX")
    ss -H -lntu | awk '{print $1,$5}' | sort -u | awk '$0!="tcp 127.0.0.1:6767"&&$0!="tcp 127.0.0.1:5055"' >"$temporary"
    chown root:root "$temporary"; chmod 0600 "$temporary"; mv -f "$temporary" "$listeners"
  fi
}

verify(){
  [ "$(env_value INSTALLATION_PROFILE)" = lan-only ] || die "LAN access requires INSTALLATION_PROFILE=lan-only"
  local id bind port
  id=$(service_id jellyfin); [ -n "$id" ] || die "Jellyfin is absent"
  [ -z "$(service_id reverse-proxy)" ] || die "Caddy must be absent in lan-only"
  bind=$(env_value MANAGEMENT_BIND_IP); port=$(env_value JELLYFIN_MANAGEMENT_PORT)
  docker inspect --format '{{range $p,$e:=.NetworkSettings.Ports}}{{range $e}}{{println $p "|" .HostIp "|" .HostPort}}{{end}}{{end}}' "$id" | grep -Fxq "8096/tcp | $bind | $port" || die "Jellyfin LAN binding is not exact"
  ! ss -H -lnt '( sport = :443 or sport = :80 or sport = :2375 or sport = :2376 or sport = :8191 )' | grep -q . || die "a prohibited LAN-profile listener exists"
  SSH_CONNECTION=${SSH_CONNECTION:-} /usr/local/sbin/veinfin-firewall --verify >/dev/null || die "firewall verification failed"
  pass "LAN-only Jellyfin access and public-port closure verified"
}

case "${1:-}" in
  --apply) compose config --quiet; compose up -d --no-deps jellyfin; verify; refresh_media_preservation ;;
  --verify) verify ;;
  --rollback) compose stop jellyfin >/dev/null 2>&1 || true; pass "LAN-only Jellyfin publication stopped" ;;
  *) printf 'Usage: %s --apply|--verify|--rollback\n' "$0" >&2; exit 2 ;;
esac
