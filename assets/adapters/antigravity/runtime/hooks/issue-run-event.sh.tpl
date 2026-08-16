#!/usr/bin/env bash
# Forward an Antigravity lifecycle event to the local Clumsies daemon.
# Best effort only: lifecycle observation must never block Antigravity.

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

cd "$PROJECT_DIR" 2>/dev/null || exit 0
printf '%s' "$INPUT" | "$CLUMSIES" _agent issue-run-event --host antigravity 2>/dev/null || true
exit 0
