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

SESSION_ID=""
MODEL=""
PROMPT_TEXT=""
if command -v python3 >/dev/null 2>&1; then
  PARSED="$(printf '%s' "$INPUT" | python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)

session_id = data.get("session_id", "")
model = data.get("model", "")
prompt = data.get("prompt", "")
if isinstance(session_id, str):
    sys.stdout.write(session_id)
sys.stdout.write("\n")
if isinstance(model, str):
    sys.stdout.write(model)
sys.stdout.write("\n")
if isinstance(prompt, str):
    sys.stdout.write(prompt)
' 2>/dev/null || true)"
  SESSION_ID="${PARSED%%$'\n'*}"
  REST="${PARSED#*$'\n'}"
  MODEL="${REST%%$'\n'*}"
  PROMPT_TEXT="${REST#*$'\n'}"
elif command -v jq >/dev/null 2>&1; then
  SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
  MODEL="$(printf '%s' "$INPUT" | jq -r '.model // empty' 2>/dev/null || true)"
  PROMPT_TEXT="$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null || true)"
else
  exit 0
fi

if [ -n "$SESSION_ID" ]; then
  export CLUMSIES_HOST_SESSION_ID="$SESSION_ID"
fi

if [ -z "$PROMPT_TEXT" ]; then
  exit 0
fi

cd "$PROJECT_ROOT"

if [ -n "$MODEL" ]; then
  "$CLUMSIES" _agent attestation-append --type user_prompt --content "$PROMPT_TEXT" --model "$MODEL" >/dev/null 2>&1 || true
else
  "$CLUMSIES" _agent attestation-append --type user_prompt --content "$PROMPT_TEXT" >/dev/null 2>&1 || true
fi
