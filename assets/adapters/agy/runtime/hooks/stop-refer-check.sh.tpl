#!/usr/bin/env bash
# clumsies Stop hook for Antigravity CLI.
# Continues the agent loop if agentreport was not called.
set -euo pipefail

input=$(cat)

source "$(dirname "$0")/resolve-binary.sh"

conversation_id=''
transcript_path=''
if command -v python3 >/dev/null 2>&1; then
    parsed=$(printf '%s' "$input" | python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)

conversation_id = data.get("conversationId", "")
if isinstance(conversation_id, str):
    sys.stdout.write(conversation_id)
sys.stdout.write("\n")

transcript_path = data.get("transcriptPath", "")
if isinstance(transcript_path, str):
    sys.stdout.write(transcript_path)
' 2>/dev/null || true)
    conversation_id="${parsed%%$'\n'*}"
    transcript_path="${parsed#*$'\n'}"
elif command -v jq >/dev/null 2>&1; then
    conversation_id=$(printf '%s' "$input" | jq -r '.conversationId // empty' 2>/dev/null || printf '')
    transcript_path=$(printf '%s' "$input" | jq -r '.transcriptPath // empty' 2>/dev/null || printf '')
fi
if [ -n "$conversation_id" ]; then
    export CLUMSIES_HOST_SESSION_ID="$conversation_id"
fi

workspace_info=$("$CLUMSIES" _agent workspace-info 2>/dev/null || true)
cache_dir=$(printf '%s\n' "$workspace_info" | sed -n 's/^CACHE_DIR=//p' | head -n 1)
protocol_status=''
if [ -n "$conversation_id" ] && [ -n "$cache_dir" ] && command -v python3 >/dev/null 2>&1; then
    protocol_status=$(python3 - "$conversation_id" "$cache_dir" "$transcript_path" <<'PY' 2>/dev/null || true
import datetime
import json
import os
import sys

session_id, cache_dir, transcript_path = sys.argv[1:4]
workspace_dir = os.path.dirname(cache_dir)
attestation_path = os.path.join(workspace_dir, "attestation", f"{session_id}.jsonl")

prompt_ts = None
answer_after_prompt = False
if transcript_path and os.path.exists(transcript_path):
    try:
        with open(transcript_path, "r", encoding="utf-8") as f:
            for line in f:
                try:
                    item = json.loads(line)
                except Exception:
                    continue
                if item.get("source") != "USER_EXPLICIT" or item.get("type") != "USER_INPUT":
                    continue
                created_at = item.get("created_at")
                if not isinstance(created_at, str):
                    continue
                try:
                    dt = datetime.datetime.fromisoformat(created_at.replace("Z", "+00:00"))
                except Exception:
                    continue
                prompt_ts = int(dt.timestamp() * 1000)
    except Exception:
        prompt_ts = None

if prompt_ts is not None and transcript_path and os.path.exists(transcript_path):
    try:
        with open(transcript_path, "r", encoding="utf-8") as f:
            for line in f:
                try:
                    item = json.loads(line)
                except Exception:
                    continue
                if item.get("source") != "MODEL" or item.get("type") != "PLANNER_RESPONSE":
                    continue
                content = item.get("content")
                if not isinstance(content, str) or not content.strip():
                    continue
                created_at = item.get("created_at")
                if not isinstance(created_at, str):
                    continue
                try:
                    dt = datetime.datetime.fromisoformat(created_at.replace("Z", "+00:00"))
                except Exception:
                    continue
                if int(dt.timestamp() * 1000) >= prompt_ts:
                    answer_after_prompt = True
    except Exception:
        answer_after_prompt = False

report_found = False
setup_found = False
if os.path.exists(attestation_path):
    try:
        with open(attestation_path, "r", encoding="utf-8") as f:
            for line in f:
                try:
                    event = json.loads(line)
                except Exception:
                    continue
                if event.get("session_id") != session_id:
                    continue
                if event.get("type") == "setup":
                    setup_found = True
                    continue
                if event.get("type") != "agent_report":
                    continue
                timestamp = event.get("timestamp")
                if prompt_ts is None or (isinstance(timestamp, int) and timestamp >= prompt_ts):
                    report_found = True
    except Exception:
        report_found = False

if report_found:
    sys.stdout.write("report_found")
elif setup_found and answer_after_prompt:
    sys.stdout.write("answered_without_report")
else:
    sys.stdout.write("incomplete")
PY
)
fi

if [ "$protocol_status" = "report_found" ]; then
    echo '{"decision":"allow"}'
    exit 0
fi

if [ "$protocol_status" = "answered_without_report" ]; then
    "$CLUMSIES" _agent attestation-append --type agent_report --content "Antigravity produced the user-facing response before calling agentreport; the Stop hook recorded completion without re-running the answer." >/dev/null 2>&1 || true
    echo '{"decision":"allow"}'
    exit 0
fi

if [ -n "$conversation_id" ] && command -v python3 >/dev/null 2>&1; then
    python3 - "$conversation_id" <<'PY'
import json
import sys

session_id = sys.argv[1]
reason = (
    "Clumsies protocol is incomplete for this turn. If you have not already "
    "done so in this Antigravity conversation, first call "
    f'memsetup({{"session_id":"{session_id}",'
    '"knownHashes":{"META_PROMPT.md":""}}) using this exact session_id. '
    "Then complete any needed clumsies discover/load/refer steps, and before "
    "finishing call agentreport with a short summary of your work. Do not "
    "answer the user until those clumsies calls are complete."
)
print(json.dumps({"decision": "continue", "reason": reason}))
PY
else
    echo '{"decision":"continue","reason":"Clumsies protocol is incomplete for this turn. Call memsetup if needed, then call agentreport with a summary before finishing."}'
fi
