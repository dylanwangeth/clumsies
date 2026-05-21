#!/usr/bin/env bash
# clumsies PreInvocation hook for Antigravity CLI.
# Captures the user prompt and injects the clumsies setup instruction on the
# first model invocation.
set -euo pipefail

input=$(cat)

source "$(dirname "$0")/resolve-binary.sh"

conversation_id=''
invocation_num=''
transcript_path=''
prompt_text=''
if command -v python3 >/dev/null 2>&1; then
    parsed=$(printf '%s' "$input" | python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    data = {}

conversation_id = data.get("conversationId", "")
if isinstance(conversation_id, str):
    sys.stdout.write(conversation_id)
sys.stdout.write("\n")

invocation_num = data.get("invocationNum", "")
if isinstance(invocation_num, int):
    sys.stdout.write(str(invocation_num))
sys.stdout.write("\n")

transcript_path = data.get("transcriptPath", "")
if isinstance(transcript_path, str):
    sys.stdout.write(transcript_path)
' 2>/dev/null || true)
    conversation_id="${parsed%%$'\n'*}"
    rest="${parsed#*$'\n'}"
    invocation_num="${rest%%$'\n'*}"
    transcript_path="${rest#*$'\n'}"
elif command -v jq >/dev/null 2>&1; then
    conversation_id=$(printf '%s' "$input" | jq -r '.conversationId // empty' 2>/dev/null || printf '')
    invocation_num=$(printf '%s' "$input" | jq -r '.invocationNum // empty' 2>/dev/null || printf '')
    transcript_path=$(printf '%s' "$input" | jq -r '.transcriptPath // empty' 2>/dev/null || printf '')
fi
if [ -n "$conversation_id" ]; then
    export CLUMSIES_HOST_SESSION_ID="$conversation_id"
fi

if [ "$invocation_num" != "0" ]; then
    echo '{}'
    exit 0
fi

if [ -n "$transcript_path" ] && [ -f "$transcript_path" ] && command -v python3 >/dev/null 2>&1; then
    prompt_text=$(python3 - "$transcript_path" <<'PY' 2>/dev/null || true
import json
import re
import sys

path = sys.argv[1]
last = ""
try:
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            try:
                item = json.loads(line)
            except Exception:
                continue
            if item.get("source") != "USER_EXPLICIT":
                continue
            if item.get("type") != "USER_INPUT":
                continue
            content = item.get("content", "")
            if isinstance(content, str):
                last = content
except Exception:
    last = ""

match = re.search(r"<USER_REQUEST>\n?(.*?)\n?</USER_REQUEST>", last, re.S)
sys.stdout.write(match.group(1).strip() if match else last.strip())
PY
)
elif [ -n "$transcript_path" ] && [ -f "$transcript_path" ] && command -v jq >/dev/null 2>&1; then
    prompt_text=$(jq -r 'select(.source=="USER_EXPLICIT" and .type=="USER_INPUT") | .content // empty' "$transcript_path" 2>/dev/null | tail -n 1 || true)
fi

if [ -n "$prompt_text" ]; then
    "$CLUMSIES" _agent attestation-append --type user_prompt --content "$prompt_text" >/dev/null 2>&1 || true
fi

if [ -n "$conversation_id" ] && command -v python3 >/dev/null 2>&1; then
    python3 - "$conversation_id" "$transcript_path" <<'PY'
import json
import sys

session_id = sys.argv[1]
transcript_path = sys.argv[2] if len(sys.argv) > 2 else ""

has_setup = False
if transcript_path:
    try:
        with open(transcript_path, "r", encoding="utf-8") as f:
            for line in f:
                if "memsetup" not in line:
                    continue
                try:
                    item = json.loads(line)
                except Exception:
                    continue
                if item.get("source") == "MODEL":
                    tool_calls = item.get("tool_calls", [])
                    if isinstance(tool_calls, list):
                        for tc in tool_calls:
                            name = tc.get("name", "")
                            if "memsetup" in name:
                                has_setup = True
                                break
                            if name == "call_mcp_tool":
                                args = tc.get("args", {})
                                if isinstance(args, dict):
                                    tool_name = args.get("ToolName", "")
                                    if "memsetup" in tool_name:
                                        has_setup = True
                                        break
                if has_setup:
                    break
    except Exception:
        pass

if has_setup:
    print(json.dumps({}))
else:
    message = (
        "Clumsies setup required for this Antigravity CLI session. "
        f"Use exactly this session_id value: {session_id}. "
        "Antigravity hook input provides this value as conversationId, the unique UUID "
        "of the active agent conversation. Before calling any other clumsies MCP tool, "
        f'memsetup({{"session_id":"{session_id}",'
        '"knownHashes":{"META_PROMPT.md":""}}). '
        "Call memsetup only once for this host session. Do not call it again later "
        "unless the user explicitly invokes the setup skill. Pass that exact value "
        "as the memsetup session_id argument. Do not invent, shorten, replace, or "
        "default the session_id. If this value is unavailable, do not call memsetup; "
        "report that the required session_id is missing. After setup succeeds, reuse "
        "the bound session and continue with memdisc/memload/memref/agentreport."
    )
    print(json.dumps({"injectSteps": [{"ephemeralMessage": message}]}))
PY
else:
    echo '{}'
fi
