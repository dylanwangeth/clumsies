#!/usr/bin/env bash
# Forward a Codex lifecycle event to the signed App-bundled Clumsies runtime.
# Best effort only: lifecycle observation must never block Codex.

set -euo pipefail
__CLUMSIES_DEV_INSTANCE_ENV_REQUIRED__

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CLUMSIES=__CLUMSIESD_SHELL_LITERAL_REQUIRED__
[ -x "$CLUMSIES" ] || exit 0

cd "$PROJECT_ROOT" 2>/dev/null || exit 0
"$CLUMSIES" _agent agent-run-event --host codex --delivery host-plugin 2>/dev/null || true
exit 0
