#!/usr/bin/env bash
# Forward a Codex lifecycle event to the local Clumsies daemon.
# Best effort only: lifecycle observation must never block Codex.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
if ! source "$SCRIPT_DIR/resolve-binary.sh"; then
  exit 0
fi

INPUT="$(cat 2>/dev/null || true)"
if [ -z "$INPUT" ]; then
  exit 0
fi

cd "$PROJECT_ROOT" 2>/dev/null || exit 0
printf '%s' "$INPUT" | "$CLUMSIES" _agent agent-run-event --host codex 2>/dev/null || true
exit 0
