#!/usr/bin/env bash
# SessionStart hook: sync workflow skill proxies from the local generation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/resolve-binary.sh"

cd "$PROJECT_DIR"

if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export CLAUDE_PROJECT_DIR=\"$PROJECT_DIR\"" >> "$CLAUDE_ENV_FILE"
fi

WS_INFO=$("$CLUMSIES" _agent workspace-info 2>/dev/null || true)
CACHE_DIR=""
if [ -n "$WS_INFO" ]; then
  while IFS='=' read -r key value; do
    case "$key" in
      CACHE_DIR) CACHE_DIR="$value" ;;
    esac
  done <<< "$WS_INFO"
fi

WORKFLOW_SKILLS_DIR="__CLUMSIES_WORKFLOW_SKILLS_DIR__"
# Workflow rules are synced under cache/rule/workflow (the rule namespace);
# scanning that directory keeps the session-start sync consistent with
# `clumsies sync` and with workflow_skills.zig at install time.
if [ -n "$WORKFLOW_SKILLS_DIR" ] && [ -d "$CACHE_DIR/rule/workflow" ]; then
  WORKFLOW_DIR="$CACHE_DIR/rule/workflow"
  find "$WORKFLOW_DIR" -name '*.md' -type f | while read -r filepath; do
    filename="$(basename "$filepath")"
    slug="$(echo "$filename" | sed 's/^[0-9]*_//; s/\.md$//; s/_/-/g' | tr '[:upper:]' '[:lower:]')"
    [ -n "$slug" ] || slug="workflow"
    skill_dir="$WORKFLOW_SKILLS_DIR/$slug"
    skill_file="$skill_dir/SKILL.md"

    if [ ! -f "$skill_file" ]; then
      mkdir -p "$skill_dir"
      cat > "$skill_file" << SKILL
---
name: $slug
description: Run $filename workflow
argument-hint: "[task description]"
user-invocable: true
---
Call the \`load\` MCP tool with ids: ["workflow/$filename"].
If you already know its current content hash, pass it in knownHashes so unchanged
content can be omitted. Then follow the loaded workflow carefully.

\$ARGUMENTS
SKILL
    fi
  done
fi
