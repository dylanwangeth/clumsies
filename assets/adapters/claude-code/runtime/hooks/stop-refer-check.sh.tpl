#!/usr/bin/env bash
# Stop hook: remind agent to submit turn summary via memory.submit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/resolve-binary.sh"

INPUT=$(cat)

if echo "$INPUT" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
  exit 0
fi

if "$CLUMSIES" _agent submit-check 2>/dev/null; then
  exit 0
fi

cat <<'EOF'
{
  "decision": "block",
  "reason": "Before finishing, call memory.submit with a summary of your work this turn."
}
EOF
