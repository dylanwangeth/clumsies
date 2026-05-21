#!/usr/bin/env bash
# Resolve the clumsies binary path for Antigravity CLI hooks.
# Sets CLUMSIES variable used by all hook scripts.
set -euo pipefail

if [ -n "${CLUMSIES:-}" ]; then
    return 0
fi

if command -v clumsies >/dev/null 2>&1; then
    CLUMSIES="$(command -v clumsies)"
    export CLUMSIES
    return 0
fi

echo "clumsies: could not resolve clumsies binary" >&2
if (return 0 2>/dev/null); then
    return 1
fi
