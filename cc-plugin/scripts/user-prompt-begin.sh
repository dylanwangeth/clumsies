#!/usr/bin/env bash
# UserPromptSubmit hook: instruct agent to begin/resume task via MCP.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/resolve-binary.sh"

# Read stdin JSON
INPUT=$(cat)

# Extract user prompt as goal summary (first 200 chars, single line)
GOAL=$(echo "$INPUT" | grep -o '"prompt"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/"prompt"[[:space:]]*:[[:space:]]*"//; s/"$//' | cut -c1-200)

cat <<INST
MANDATORY — HIGHEST PRIORITY — EXECUTE BEFORE ANY OTHER ACTION:
You MUST call the \`memory.begin\` MCP tool immediately as your FIRST action before responding to this prompt. Do NOT read files, do NOT respond to the user, do NOT call any other tool until memory.begin has been called. If memory.begin is a deferred tool, call ToolSearch first to fetch its schema, then call it immediately.${GOAL:+
Goal: $GOAL}
INST
