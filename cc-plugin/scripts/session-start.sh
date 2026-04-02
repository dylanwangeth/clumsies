#!/usr/bin/env bash
# SessionStart hook: bootstrap protocol + generate workflow skills.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/resolve-binary.sh"

cd "$PROJECT_DIR"

# 1. Persist PROJECT_DIR into Bash tool environment
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export CLAUDE_PROJECT_DIR=\"$PROJECT_DIR\"" >> "$CLAUDE_ENV_FILE"
fi

# 2. Setup: load META_PROMPT.md
MPF_CONTENT=$("$CLUMSIES" setup 2>/dev/null || true)

# 3. Auto-generate workflow skills
SKILLS_DIR="$PROJECT_DIR/.claude/skills"
WORKFLOW_DIR="$PROMPTS_DIR/workflow"

if [ -d "$WORKFLOW_DIR" ]; then
  SKILL_LIST=""
  find "$WORKFLOW_DIR" -name '*.md' -type f | while read -r filepath; do
    filename="$(basename "$filepath")"
    # Strip sequence prefix (NN_) and extension, lowercase, underscores to hyphens
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
allowed-tools: Bash
---
!\`cd "\${CLAUDE_PROJECT_DIR:-$PROJECT_DIR}" && clumsies load workflow:$rel_path\`

\$ARGUMENTS
SKILL
    fi

    SKILL_LIST="${SKILL_LIST:+$SKILL_LIST, }/$slug"
  done
fi

# 4. Output: inject into conversation
if [ -n "$MPF_CONTENT" ]; then
  echo "$MPF_CONTENT"
  echo ""
fi

# List available workflow skills
if [ -d "$SKILLS_DIR" ] && [ "$(ls -A "$SKILLS_DIR" 2>/dev/null)" ]; then
  echo ""
  echo "Available workflow skills:"
  for d in "$SKILLS_DIR"/*/; do
    [ -f "$d/SKILL.md" ] && echo "  /$(basename "$d")"
  done
fi
