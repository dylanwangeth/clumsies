#!/usr/bin/env bash
# Stop hook: remind agent to submit turn summary via agentreport.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/resolve-binary.sh"

INPUT="$(cat)"

SESSION_ID=""
if command -v python3 >/dev/null 2>&1; then
  SESSION_ID="$(printf '%s' "$INPUT" | python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)

session_id = data.get("session_id", "")
if isinstance(session_id, str):
    sys.stdout.write(session_id)
' 2>/dev/null || true)"
elif command -v jq >/dev/null 2>&1; then
  SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
fi

if [ -n "$SESSION_ID" ]; then
  export CLUMSIES_HOST_SESSION_ID="$SESSION_ID"
fi

if printf '%s' "$INPUT" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
  exit 0
fi

if "$CLUMSIES" _agent submit-check 2>/dev/null; then
  exit 0
fi

cat <<'EOF'
{
  "decision": "block",
  "reason": "Before finishing, call agentreport with a summary of your work this turn."
}
EOF
