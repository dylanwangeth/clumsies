#!/usr/bin/env bash
# SessionStart hook: generate workflow skills + instruct agent to bootstrap protocol.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/resolve-binary.sh"

cd "$PROJECT_DIR"

# 1. Persist PROJECT_DIR into Bash tool environment
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export CLAUDE_PROJECT_DIR=\"$PROJECT_DIR\"" >> "$CLAUDE_ENV_FILE"
fi

# 2. Auto-generate workflow skills
SKILLS_DIR="$PROJECT_DIR/.claude/skills"
WORKFLOW_DIR="$PROMPTS_DIR/workflow"

if [ -d "$WORKFLOW_DIR" ]; then
  find "$WORKFLOW_DIR" -name '*.md' -type f | while read -r filepath; do
    filename="$(basename "$filepath")"
    slug="$(echo "$filename" | sed 's/^[0-9]*_//; s/\.md$//; s/_/-/g' | tr '[:upper:]' '[:lower:]')"
    rel_path="${filepath#"$WORKFLOW_DIR/"}"

    skill_dir="$SKILLS_DIR/$slug"
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
Call the \`memory.load\` MCP tool with ids: ["workflow:$rel_path"]

\$ARGUMENTS
SKILL
    fi
  done
fi

# 3. Output: instruct agent to bootstrap protocol via MCP
echo "Call memory.setup to bootstrap the clumsies protocol and load META_PROMPT.md."
echo ""

# List available workflow skills
if [ -d "$SKILLS_DIR" ] && [ "$(ls -A "$SKILLS_DIR" 2>/dev/null)" ]; then
  echo ""
  echo "Available workflow skills:"
  for d in "$SKILLS_DIR"/*/; do
    [ -f "$d/SKILL.md" ] && echo "  /$(basename "$d")"
  done
fi
