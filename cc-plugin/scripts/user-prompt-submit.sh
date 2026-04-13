#!/usr/bin/env bash
# UserPromptSubmit hook: capture developer prompt text as a session_input
# trace event. Best-effort — silent failures must never block CC.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/resolve-binary.sh"

if ! command -v jq &>/dev/null; then
  exit 0
fi

PROMPT_TEXT=$(jq -r '.prompt // empty' 2>/dev/null || echo "")
if [ -z "$PROMPT_TEXT" ]; then
  exit 0
fi

"$CLUMSIES" trace append --type session_input --content "$PROMPT_TEXT" >/dev/null 2>&1 || true
