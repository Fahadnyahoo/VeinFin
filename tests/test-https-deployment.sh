#!/usr/bin/env bash
set -u
set -o pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT=$ROOT/scripts/deploy/https.sh
FIREWALL=$ROOT/scripts/host/configure-firewall.sh
COMPOSE=$ROOT/compose.yaml
TEMPLATE=$ROOT/templates/caddy/Caddyfile.tmpl
PASSED=0
FAILED=0

ok() { printf 'PASS: %s\n' "$1"; PASSED=$((PASSED+1)); }
bad() { printf 'FAIL: %s\n' "$1"; FAILED=$((FAILED+1)); }
has() { grep -Fq -- "$2" <<<"$1" && ok "$3" || bad "$3"; }
lacks() { if grep -Fq -- "$2" <<<"$1"; then bad "$3"; else ok "$3"; fi; }

bash -n "$SCRIPT" && ok 'deployment shell syntax' || bad 'deployment shell syntax'
bash -n "$FIREWALL" && ok 'firewall shell syntax' || bad 'firewall shell syntax'
help=$($SCRIPT --help 2>&1)
has "$help" 'scripts/deploy/https.sh --check' 'help documents check'
has "$help" 'scripts/deploy/https.sh --apply' 'help documents apply'
has "$help" 'scripts/deploy/https.sh --verify' 'help documents verify'
has "$help" 'TLS-ALPN-01 only' 'help documents challenge restriction'
has "$help" 'separate SSH session' 'help documents rollback verification'

VEINFIN_HTTPS_LIBRARY_ONLY=1 source "$SCRIPT"
set +e
valid_hostname media.example.org && ok 'valid public hostname accepted' || bad 'valid public hostname accepted'
if valid_hostname local.invalid; then bad 'placeholder hostname rejected'; else ok 'placeholder hostname rejected'; fi
if valid_hostname bad_host.example; then bad 'invalid hostname rejected'; else ok 'invalid hostname rejected'; fi

script_text=$(<"$SCRIPT")
compose_text=$(<"$COMPOSE")
template_text=$(<"$TEMPLATE")
firewall_text=$(<"$FIREWALL")

check_function=$(declare -f run_checks)
lacks "$check_function" 'record_baseline' 'check mode does not record state'
lacks "$check_function" 'prepare_caddy' 'check mode does not create Caddy state'
lacks "$check_function" 'pull reverse-proxy' 'check mode does not pull images'
lacks "$check_function" 'update-public-https' 'check mode does not alter firewall'
has "$script_text" 'compose_cmd pull reverse-proxy' 'apply pulls only Caddy'
has "$script_text" 'compose_cmd up -d --no-deps reverse-proxy' 'apply starts only Caddy'
lacks "$script_text" 'compose_cmd up -d --no-deps jellyfin' 'apply does not start Jellyfin'
has "$script_text" 'https-preserved-containers.txt' 'eight-container fingerprints are guarded'
has "$script_text" 'https-rsync-before.txt' 'rsync identity is guarded'
has "$script_text" 'https-listeners-before.txt' 'listener baseline is guarded'
has "$script_text" 'vf_atomic_write' 'protected baseline writes are atomic'

has "$compose_text" 'user: "1000:1000"' 'Caddy runs unprivileged'
has "$compose_text" 'cap_drop:' 'Caddy drops capabilities'
has "$compose_text" '- ALL' 'Caddy drops all capabilities'
has "$compose_text" '- NET_BIND_SERVICE' 'Caddy adds only bind capability'
has "$compose_text" 'read_only: true' 'Caddy root filesystem is read-only'
lacks "$compose_text" '80:80' 'TCP 80 is not published'
lacks "$compose_text" '443:443/udp' 'UDP 443 is not published'
has "$template_text" 'reverse_proxy jellyfin:8096' 'Caddy targets only Jellyfin Docker DNS'
has "$template_text" 'disable_http_challenge' 'HTTP-01 is disabled'
has "$template_text" 'auto_https disable_redirects' 'automatic HTTP redirect listener is disabled'
has "$template_text" 'protocols h1 h2' 'HTTP/3 and UDP 443 are disabled'
lacks "$template_text" 'tls internal' 'self-signed/internal PKI is absent'
lacks "$template_text" 'acme_dns' 'DNS challenge is absent'
has "$template_text" 'Strict-Transport-Security' 'HSTS is configured'
has "$template_text" 'X-Content-Type-Options' 'nosniff is configured'

has "$firewall_text" '--update-public-https' 'guarded live firewall transition exists'
has "$firewall_text" 'public HTTPS update may not change any other firewall value' 'firewall transition rejects unrelated changes'
has "$firewall_text" 'schedule_rollback' 'firewall transition retains automatic rollback'
has "$script_text" 'openssl s_client' 'certificate chain is verified'
has "$script_text" '-verify_hostname' 'certificate hostname is verified'
has "$script_text" '-checkend 86400' 'certificate validity is verified'
has "$script_text" 'invalid.example' 'arbitrary Host rejection is tested'
has "$script_text" "sport = :80 or sport = :2375 or sport = :2376" 'prohibited TCP listeners are verified closed'
has "$script_text" "ss -H -lnu 'sport = :443'" 'UDP 443 is verified closed'
has "$script_text" 'media_services_api.py' 'empty application state is reverified'
lacks "$compose_text" '/var/run/docker.sock' 'raw Docker socket is absent from Compose'

printf '\nTests: %d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
