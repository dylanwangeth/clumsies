#!/usr/bin/env bash
# Resolve the clumsies binary path for Gemini CLI hooks.
# Sets CLUMSIES variable used by all hook scripts.
set -euo pipefail

if [ -n "${CLUMSIES:-}" ]; then
    return 0
fi

# Check GEMINI_PROJECT_DIR for workspace-scoped installs
project_dir="${GEMINI_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-}}"
if [ -n "$project_dir" ]; then
    candidate="$project_dir/.gemini/hooks/.clumsies-bin"
    if [ -x "$candidate" ]; then
        CLUMSIES="$candidate"
        export CLUMSIES
        return 0
    fi
fi

# Fall back to PATH lookup
if command -v clumsies >/dev/null 2>&1; then
    CLUMSIES="$(command -v clumsies)"
    export CLUMSIES
    return 0
fi

echo "clumsies: could not resolve clumsies binary" >&2
if (return 0 2>/dev/null); then
    return 1
fi