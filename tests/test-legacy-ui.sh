#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
LOCK=$ROOT/config/plugins.lock
ASSETS=$ROOT/config/legacy-ui-assets.lock

bash -n "$ROOT/scripts/deploy/legacy-ui.sh" "$ROOT/scripts/deploy/plugins.sh"
PYTHONPYCACHEPREFIX=${TMPDIR:-/tmp}/veinfin-legacy-ui-pycache python3 -m py_compile "$ROOT/scripts/deploy/legacy_ui.py" "$ROOT/tests/browser-plugin-smoke.py"
! grep -Fq 'candidate Anime library identifier is unavailable' "$ROOT/scripts/deploy/legacy_ui.py"
grep -Fq 'DefaultTVShowsLibraryId": anime_id' "$ROOT/scripts/deploy/legacy_ui.py"
grep -Fq '"UseFileTransformationPlugin": False' "$ROOT/scripts/deploy/legacy_ui.py"
! grep -Fq '"AutoSkipIntro"' "$ROOT/scripts/deploy/legacy_ui.py"
"$ROOT/scripts/deploy/plugins.py" validate-lock --lock "$LOCK"

[ "$(awk -F'|' '!/^#/ && NF{n++}END{print n+0}' "$LOCK")" -eq 12 ]
grep -Fq '10.11.11@sha256:aefb67e6a7ff1debdd154a78a7bbb780fd0c873d8639210a7f6a2016ad2b35db' "$ROOT/compose/legacy-ui-candidate.yaml"
grep -Eq '^KEFIN_TWEAKS\|KefinTweaks\|0\.5\.3\|7ff0812d88fb923e5dc7fdb3262a84b283fd627a\|MIT\|' "$ASSETS"
grep -Fq '${CONFIG_ROOT:?Set CONFIG_ROOT}/jellyfin/KefinTweaks:/jellyfin/jellyfin-web/KefinTweaks:ro' "$ROOT/compose.yaml"
grep -Fq '${MEDIA_ROOT:?Set MEDIA_ROOT}/library:/data/library:ro' "$ROOT/compose/legacy-ui-candidate.yaml"
grep -Fq '127.0.0.1:${LEGACY_CANDIDATE_PORT:-18096}:8096/tcp' "$ROOT/compose/legacy-ui-candidate.yaml"
! grep -Eq '/var/run/docker.sock|network_mode:[[:space:]]*host|privileged:[[:space:]]*true' "$ROOT/compose/legacy-ui-candidate.yaml"
! grep -Eiq 'Who.?s Watching|WhoIsWatching|whos_watching' "$LOCK"
help=$($ROOT/scripts/deploy/legacy-ui.sh --help)
grep -q -- '--promote' <<<"$help"
grep -q -- '--rollback' <<<"$help"

printf 'Legacy UI static tests passed.\n'
