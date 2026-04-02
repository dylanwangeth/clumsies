#!/usr/bin/env bash
# UserPromptSubmit hook: begin task with user's prompt as goal.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/resolve-binary.sh"

cd "$PROJECT_DIR"

# Read stdin JSON
INPUT=$(cat)

# Extract user prompt as goal summary (first 200 chars, single line)
GOAL=$(echo "$INPUT" | grep -o '"prompt"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/"prompt"[[:space:]]*:[[:space:]]*"//; s/"$//' | cut -c1-200)

# Begin task with goal (idempotent: returns existing task if active)
TASK_ID=$("$CLUMSIES" begin ${GOAL:+"$GOAL"} 2>/dev/null || true)

if [ -n "$TASK_ID" ]; then
  echo "Active task: $TASK_ID"
fi
