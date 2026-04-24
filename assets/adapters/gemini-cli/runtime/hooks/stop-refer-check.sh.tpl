#!/usr/bin/env bash
# clumsies AfterAgent hook for Gemini CLI.
# Denies the response if memory.submit was not called, triggering automatic retry.
# Communicates via JSON stdin/stdout protocol.
set -euo pipefail

input=$(cat)

source "$(dirname "$0")/resolve-binary.sh"

if ! "$CLUMSIES" _agent submit-check 2>/dev/null; then
    echo '{"decision":"deny","reason":"You must call memory.submit with a summary of your work before finishing."}'
else
    echo '{"decision":"allow"}'
fi