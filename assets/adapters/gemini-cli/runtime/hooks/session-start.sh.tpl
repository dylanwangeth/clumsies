#!/usr/bin/env bash
# clumsies SessionStart hook for Gemini CLI.
# Injects META_PROMPT context via hookSpecificOutput.additionalContext.
# Communicates via JSON stdin/stdout protocol.
set -euo pipefail

input=$(cat)

source "$(dirname "$0")/resolve-binary.sh"

meta_prompt=$($CLUMSIES _agent setup 2>/dev/null) || meta_prompt=""

if [ -n "$meta_prompt" ]; then
    escaped=$(printf '%s' "$meta_prompt" | jq -Rs .)
    echo "{\"decision\":\"allow\",\"hookSpecificOutput\":{\"additionalContext\":$escaped}}"
else
    echo '{"decision":"allow"}'
fi