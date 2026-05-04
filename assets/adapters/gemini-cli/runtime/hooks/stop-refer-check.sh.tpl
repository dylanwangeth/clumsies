#!/usr/bin/env bash
# clumsies AfterAgent hook for Gemini CLI.
# Denies the response if agentreport was not called, triggering automatic retry.
# Communicates via JSON stdin/stdout protocol.
set -euo pipefail

input=$(cat)

source "$(dirname "$0")/resolve-binary.sh"

session_id=''
if command -v jq >/dev/null 2>&1; then
    session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || printf '')
fi
if [ -n "$session_id" ]; then
    export CLUMSIES_HOST_SESSION_ID="$session_id"
fi

if ! "$CLUMSIES" _agent submit-check 2>/dev/null; then
    echo '{"decision":"deny","reason":"You must call agentreport with a summary of your work before finishing."}'
else
    echo '{"decision":"allow"}'
fi
