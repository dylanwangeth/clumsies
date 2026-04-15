#!/usr/bin/env bash
# Stop hook: remind the agent to declare clumsies references before finishing.
# On the second invocation (`stop_hook_active: true`), allow stop to continue.

set -euo pipefail

INPUT="$(cat)"

if printf '%s' "$INPUT" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
  exit 0
fi

cat <<'EOF'
{
  "decision": "block",
  "reason": "Before finishing, check whether you applied any clumsies constraint in this response. If you did, declare it with the clumsies refer MCP tool in this turn. If you applied none, say so explicitly."
}
EOF
