#!/bin/sh
# Forward a dsh lifecycle event (JSON on stdin) to the local Clumsies daemon.
# Best effort only: lifecycle observation must never block the dsh session.
#
# Usage:  printf '%s' "$PAYLOAD" | issue-run-event.sh
# Payload: {"hook_event_name":"UserPromptSubmit|Stop|StopFailure|SubagentStart|SubagentStop|SessionEnd",
#           "session_id":"...","turn_id":"...","agent_id":"...","agent_type":"...","cwd":"/path"}
#
# Requires CLUMSIES_BIN (defaults to the installed Clumsies.app runtime).

set -eu

CLUMSIES_BIN="${CLUMSIES_BIN:-/Users/weiwang/Applications/Clumsies.app/Contents/Resources/clumsiesd}"
if [ ! -x "$CLUMSIES_BIN" ]; then
  exit 0
fi

INPUT="$(cat 2>/dev/null || true)"
if [ -z "$INPUT" ]; then
  exit 0
fi

printf '%s' "$INPUT" | "$CLUMSIES_BIN" _agent issue-run-event --host dsh 2>/dev/null || true
exit 0
