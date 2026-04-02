#!/usr/bin/env bash
# Stop hook: remind agent to declare constraint references.
# Uses "decision: block" to inject reminder before agent stops.
# On second invocation (stop_hook_active: true), allows stop.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/resolve-binary.sh"

# Read stdin JSON
INPUT=$(cat)

# Prevent infinite loop: if stop_hook_active is true, allow stop
if echo "$INPUT" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
  exit 0
fi

# Block stop and inject refer reminder
cat <<'EOF'
{
  "decision": "block",
  "reason": "Before finishing, check: did you apply any constraint from .prompts/ in THIS response? Each response is tracked independently — you must call memory.refer for every constraint you applied in this turn, even if you referred the same constraint in a previous turn. If you applied no constraints this turn, say so explicitly."
}
EOF
