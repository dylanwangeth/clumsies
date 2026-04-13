#!/usr/bin/env bash
# Shared preamble for clumsies CC plugin hooks.
# Source this file, don't execute it directly.
# Exports: $CLUMSIES (binary path), $PROJECT_DIR
# Exits 0 silently if the clumsies binary is not installed.

set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"

if command -v clumsies &>/dev/null; then
  CLUMSIES="clumsies"
elif [ -x "$HOME/.clumsies/bin/clumsies" ]; then
  CLUMSIES="$HOME/.clumsies/bin/clumsies"
else
  exit 0
fi

export CLUMSIES PROJECT_DIR
