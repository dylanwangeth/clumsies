#!/bin/sh
# Forward a dsh lifecycle event (JSON on stdin) to the local Clumsies daemon.
# Best effort only: lifecycle observation must never block the dsh session.
#
# Usage:  printf '%s' "$PAYLOAD" | issue-run-event.sh
# Payload: {"hook_event_name":"UserPromptSubmit|Stop|StopFailure|SubagentStart|SubagentStop|SessionEnd",
#           "session_id":"...","turn_id":"...","agent_id":"...","agent_type":"...","cwd":"/path"}
#
# Resolves the App-bundled clumsiesd from the nearest .dsh/clumsies.json
# marker (installed by the Clumsies dsh Coding Agent adapter), falling back
# to CLUMSIES_BIN and then the default installed path.

set -eu

DEFAULT_BIN="/Users/weiwang/Applications/Clumsies.app/Contents/Resources/clumsiesd"

resolve_runtime() {
  CLUMSIES_BIN="${CLUMSIES_BIN:-}"
  if [ -n "$CLUMSIES_BIN" ] && [ -x "$CLUMSIES_BIN" ]; then
    printf '%s' "$CLUMSIES_BIN"
    return 0
  fi
  dir="$(pwd 2>/dev/null || printf '.')"
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -f "$dir/.dsh/clumsies.json" ]; then
      marker_runtime="$(sed -n 's/.*"runtime"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$dir/.dsh/clumsies.json" 2>/dev/null | head -n 1)"
      if [ -n "$marker_runtime" ] && [ -x "$marker_runtime" ]; then
        printf '%s' "$marker_runtime"
        return 0
      fi
    fi
    dir="$(dirname "$dir" 2>/dev/null || printf '')"
  done
  printf '%s' "$DEFAULT_BIN"
}

CLUMSIES_BIN="$(resolve_runtime)"
if [ ! -x "$CLUMSIES_BIN" ]; then
  exit 0
fi

INPUT="$(cat 2>/dev/null || true)"
if [ -z "$INPUT" ]; then
  exit 0
fi

printf '%s' "$INPUT" | "$CLUMSIES_BIN" _agent issue-run-event --host dsh 2>/dev/null || true
exit 0
