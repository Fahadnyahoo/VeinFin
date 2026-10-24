#!/usr/bin/env bash
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
export VEINFIN_REPO_DIR="$REPO_DIR"

exec "$REPO_DIR/scripts/installer.sh" "$@"
