#!/usr/bin/env bash
# SessionStart hook: bootstrap clumsies protocol.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/resolve-binary.sh"

INPUT="$(cat || true)"
SESSION_ID=""
if command -v python3 >/dev/null 2>&1; then
  SESSION_ID="$(printf '%s' "$INPUT" | python3 -c '
import json
import os
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    data = {}

session_id = data.get("session_id", "")
if not isinstance(session_id, str) or not session_id:
    session_id = os.environ.get("CODEX_THREAD_ID", "")
sys.stdout.write(session_id)
' 2>/dev/null || true)"
elif command -v jq >/dev/null 2>&1; then
  SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
fi

cd "$PROJECT_ROOT"

python3 - "$SESSION_ID" <<'PY'
import json
import sys

session_id = sys.argv[1]
parts = []
if session_id:
    parts.append(
        "Clumsies setup required for this Codex session. "
        f"Use exactly this session_id value: {session_id}. "
        "During host agent startup, before calling any other clumsies MCP "
        "tool, call "
        f'memory.setup({{"session_id":"{session_id}"}}). '
        "Call memory.setup only once for this host session. Do not call it "
        "again later unless the user explicitly invokes the setup skill. "
        "Pass that exact value as the memory.setup session_id argument. "
        "Do not invent, shorten, replace, or default the session_id. "
        "If this value is unavailable, do not call memory.setup; report that "
        "the required session_id is missing. After setup succeeds, reuse the "
        "bound session and continue with memory.discover/load/refer/submit."
    )
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": "\n\n".join(parts),
    },
}))
PY
