#!/usr/bin/env bash
# UserPromptSubmit hook: append the submitted prompt as a user_prompt attestation.
# Best effort only. Parsing failures must never block Codex.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/resolve-binary.sh"

INPUT="$(cat)"
if [ -z "$INPUT" ]; then
  exit 0
fi

PROMPT_TEXT=""
if command -v python3 >/dev/null 2>&1; then
  PROMPT_TEXT="$(printf '%s' "$INPUT" | python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)

prompt = data.get("prompt", "")
if isinstance(prompt, str):
    sys.stdout.write(prompt)
' 2>/dev/null || true)"
elif command -v jq >/dev/null 2>&1; then
  PROMPT_TEXT="$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null || true)"
else
  exit 0
fi

if [ -z "$PROMPT_TEXT" ]; then
  exit 0
fi

cd "$PROJECT_ROOT"

"$CLUMSIES" _agent attestation-append --type user_prompt --content "$PROMPT_TEXT" >/dev/null 2>&1 || true
