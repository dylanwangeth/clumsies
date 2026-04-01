#!/usr/bin/env bash
# Shared preamble for clumsies CC plugin hooks.
# Source this file, don't execute it directly.
# Exports: $CLUMSIES (binary path), $PROMPTS_DIR (.prompts/ path)
# Exits 0 silently if clumsies or .prompts/ not found.

set -euo pipefail

# Resolve project directory
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"

# Check .prompts/ exists
PROMPTS_DIR="$PROJECT_DIR/.prompts"
if [ ! -d "$PROMPTS_DIR" ]; then
  exit 0
fi

# Resolve clumsies binary
if command -v clumsies &>/dev/null; then
  CLUMSIES="clumsies"
elif [ -x "$HOME/.clumsies/bin/clumsies" ]; then
  CLUMSIES="$HOME/.clumsies/bin/clumsies"
else
  exit 0
fi

export CLUMSIES PROMPTS_DIR PROJECT_DIR
