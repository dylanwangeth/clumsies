#!/usr/bin/env bash
# Shared preamble for clumsies Codex runtime hook wrappers.
# Source this file, don't execute it directly.
# Exports: $CLUMSIES, $PROJECT_ROOT

set -euo pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

if [ -n "${CLUMSIES_ADAPTER_BINARY:-}" ] && [ -x "$CLUMSIES_ADAPTER_BINARY" ]; then
  CLUMSIES="$CLUMSIES_ADAPTER_BINARY"
elif [ -x "$PROJECT_ROOT/zig-out/bin/clumsies" ]; then
  CLUMSIES="$PROJECT_ROOT/zig-out/bin/clumsies"
elif command -v clumsies >/dev/null 2>&1; then
  CLUMSIES="$(command -v clumsies)"
elif [ -x "$HOME/.clumsies/bin/clumsies" ]; then
  CLUMSIES="$HOME/.clumsies/bin/clumsies"
else
  exit 0
fi

export CLUMSIES PROJECT_ROOT
