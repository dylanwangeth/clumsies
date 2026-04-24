#!/usr/bin/env bash
# clumsies BeforeAgent hook for Gemini CLI.
# Captures user prompt for attestation, then allows the turn.
# Communicates via JSON stdin/stdout protocol.
set -euo pipefail

input=$(cat)

source "$(dirname "$0")/resolve-binary.sh"

prompt=$(printf '%s' "$input" | jq -r '.prompt // empty')
if [ -n "$prompt" ]; then
    $CLUMSIES _agent attestation-append --type user_prompt --content "$prompt" 2>/dev/null || true
fi

echo '{"decision":"allow"}'