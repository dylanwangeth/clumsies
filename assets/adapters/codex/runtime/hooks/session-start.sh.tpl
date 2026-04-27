#!/usr/bin/env bash
# SessionStart hook: bootstrap clumsies protocol.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/resolve-binary.sh"

cd "$PROJECT_ROOT"

"$CLUMSIES" _agent setup
