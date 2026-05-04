#!/usr/bin/env bash
# Stop hook: remind agent to submit turn summary via agentreport.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/resolve-binary.sh"

INPUT=$(cat)

if command -v jq &>/dev/null; then
  SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
  if [ -n "$SESSION_ID" ]; then
    export CLUMSIES_HOST_SESSION_ID="$SESSION_ID"
  fi
fi

if echo "$INPUT" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
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
