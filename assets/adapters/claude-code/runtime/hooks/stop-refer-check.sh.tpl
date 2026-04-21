#!/usr/bin/env bash
# Stop hook: remind agent to declare constraint references.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/resolve-binary.sh"

INPUT=$(cat)

if echo "$INPUT" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
  exit 0
fi

cat <<'EOF'
{
  "decision": "block",
  "reason": "Before finishing, check: did you apply any constraint from a prompt loaded via `memory.load` in THIS response? Each response is tracked independently — call `memory.refer` for every constraint you applied in this turn, even if you referred the same constraint in a previous turn. If you applied no constraints this turn, say so explicitly."
}
EOF
