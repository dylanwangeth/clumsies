#!/usr/bin/env bash
# SessionStart hook: bootstrap clumsies protocol and import workflow skills.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/resolve-binary.sh"

cd "$PROJECT_ROOT"

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
if [ -n "$WORKFLOW_SKILLS_DIR" ] && [ -n "$CACHE_DIR" ] && [ -d "$CACHE_DIR/workflow" ]; then
  WORKFLOW_DIR="$CACHE_DIR/workflow"
  find "$WORKFLOW_DIR" -name '*.md' -type f | while read -r filepath; do
    filename="$(basename "$filepath")"
    slug="$(echo "$filename" | sed 's/^[0-9]*[_ -]*//; s/\.md$//; s/[^[:alnum:]]\+/-/g' | tr '[:upper:]' '[:lower:]' | sed 's/^-*//; s/-*$//')"
    [ -n "$slug" ] || slug="workflow"
    rel_path="${filepath#"$WORKFLOW_DIR/"}"

    skill_dir="$WORKFLOW_SKILLS_DIR/$slug"
    skill_file="$skill_dir/SKILL.md"

    if [ ! -f "$skill_file" ]; then
      mkdir -p "$skill_dir"
      cat > "$skill_file" << SKILL
---
name: $slug
description: Load and follow the clumsies workflow $filename when the task matches it.
metadata:
  short-description: Follow $filename
---

Call the \`memory.load\` MCP tool with ids: ["workflow:$rel_path"].
Then follow the loaded workflow carefully.
If the user already provided task details, use them as the workflow input.
SKILL
    fi
  done
fi

"$CLUMSIES" _agent setup
