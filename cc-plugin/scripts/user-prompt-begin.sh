#!/usr/bin/env bash
# UserPromptSubmit hook: instruct agent to begin/resume task via MCP.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/resolve-binary.sh"

# Read stdin JSON
INPUT=$(cat)

# Extract user prompt as goal summary (first 200 chars, single line)
GOAL=$(echo "$INPUT" | grep -o '"prompt"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/"prompt"[[:space:]]*:[[:space:]]*"//; s/"$//' | cut -c1-200)

echo "Call memory.begin to start or resume a task${GOAL:+ with goal: $GOAL}."
