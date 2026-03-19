#!/usr/bin/env bash
set -euo pipefail

CLUMSIES_RAW="${CLUMSIES:-./zig-out/bin/clumsies}"
CLUMSIES="$(cd "$(dirname "$CLUMSIES_RAW")" && pwd)/$(basename "$CLUMSIES_RAW")"
TMPBASE=$(mktemp -d)
trap 'rm -rf "$TMPBASE"' EXIT

REGISTRY="$TMPBASE/mock-registry"
WORKSPACE="$TMPBASE/workspace"
HOME_DIR="$TMPBASE/home"
export HOME="$HOME_DIR"
mkdir -p "$HOME_DIR"

PASS=0
FAIL=0

step() { printf "\n=== %s ===\n" "$1"; }

assert() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf "  OK: %s\n" "$desc"
        PASS=$((PASS + 1))
    else
        printf "  FAIL: %s\n" "$desc"
        FAIL=$((FAIL + 1))
        printf "  Command: %s\n" "$*"
        exit 1
    fi
}

assert_output() {
    local desc="$1" expected="$2" actual="$3"
    if echo "$actual" | grep -q "$expected"; then
        printf "  OK: %s\n" "$desc"
        PASS=$((PASS + 1))
    else
        printf "  FAIL: %s\n" "$desc"
        printf "  Expected to contain: %s\n" "$expected"
        printf "  Actual: %s\n" "$actual"
        FAIL=$((FAIL + 1))
        exit 1
    fi
}

assert_file_contains() {
    local desc="$1" file="$2" pattern="$3"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        printf "  OK: %s\n" "$desc"
        PASS=$((PASS + 1))
    else
        printf "  FAIL: %s\n" "$desc"
        printf "  File: %s\n" "$file"
        printf "  Expected pattern: %s\n" "$pattern"
        FAIL=$((FAIL + 1))
        exit 1
    fi
}

assert_file_not_contains() {
    local desc="$1" file="$2" pattern="$3"
    if ! grep -q "$pattern" "$file" 2>/dev/null; then
        printf "  OK: %s\n" "$desc"
        PASS=$((PASS + 1))
    else
        printf "  FAIL: %s\n" "$desc"
        printf "  File: %s\n" "$file"
        printf "  Should NOT contain: %s\n" "$pattern"
        FAIL=$((FAIL + 1))
        exit 1
    fi
}

# Git identity for the test HOME
git config --global user.email "test@test.com"
git config --global user.name "Test"

# Setup mock registry
step "Setup mock registry"
mkdir -p "$REGISTRY"
git -C "$REGISTRY" init -b main
git -C "$REGISTRY" commit --allow-empty -m "init"
mkdir -p "$REGISTRY/prompts" "$REGISTRY/bundles"
echo '{"prompts":[]}' > "$REGISTRY/prompts/index.json"
echo '{"bundles":[]}' > "$REGISTRY/bundles/index.json"
git -C "$REGISTRY" add -A
git -C "$REGISTRY" commit -m "scaffold"
printf "  Registry at: %s\n" "$REGISTRY"

# Setup workspace
step "Setup workspace"
mkdir -p "$WORKSPACE/.prompts/rule/coding"
printf "# Test Coding Rule\n\nAlways use snake_case.\n" > "$WORKSPACE/.prompts/rule/coding/00_SNAKE_CASE.md"
mkdir -p "$WORKSPACE/.prompts/rule/testing"
printf "# Test Testing Rule\n\nWrite tests first.\n" > "$WORKSPACE/.prompts/rule/testing/00_TDD.md"
cd "$WORKSPACE"

# 1. config set registry
step "1. config set registry"
"$CLUMSIES" config set registry "$REGISTRY"
assert "config.json exists" test -f "$HOME_DIR/.clumsies/config.json"
assert_file_contains "config.json contains registry" "$HOME_DIR/.clumsies/config.json" "mock-registry"

# 2. add with explicit -c
step "2. add with -c flag"
"$CLUMSIES" add .prompts/rule/coding/00_SNAKE_CASE.md -c rule/coding -Q
PROMPTS_INDEX="$HOME_DIR/.clumsies/registry/prompts/index.json"
assert "prompts/index.json exists" test -f "$PROMPTS_INDEX"
assert_file_contains "index has SNAKE_CASE entry" "$PROMPTS_INDEX" "SNAKE_CASE"
assert_file_contains "category uses forward slash" "$PROMPTS_INDEX" "rule/coding"

# 3. add directory (derive category from path)
step "3. add directory (derive category)"
"$CLUMSIES" add .prompts/rule/testing/ -Q
assert_file_contains "index has TDD entry" "$PROMPTS_INDEX" "TDD"
assert_file_contains "derived category uses forward slash" "$PROMPTS_INDEX" "rule/testing"
assert_file_not_contains "no backslash in categories" "$PROMPTS_INDEX" 'rule\\testing'

# Extract a hash for later use
HASH=$(grep -o '"hash": "[a-f0-9]*"' "$PROMPTS_INDEX" | head -1 | cut -d'"' -f4)
SHORT_HASH="${HASH:0:8}"
printf "  Using hash: %s\n" "$SHORT_HASH"

# 4. ls -p
step "4. ls -p"
LS_OUTPUT=$("$CLUMSIES" ls -p -Q 2>&1 || true)
assert_output "output contains SNAKE_CASE" "SNAKE_CASE" "$LS_OUTPUT"

# 5. ls -ps (combined short flags)
step "5. ls -ps (combined flags)"
LS_COMBINED=$("$CLUMSIES" ls -ps -Q 2>&1 || true)
assert_output "combined flags work" "SNAKE_CASE" "$LS_COMBINED"

# 6. show <hash>
step "6. show <hash>"
SHOW_OUTPUT=$("$CLUMSIES" show "$SHORT_HASH" -Q 2>&1 || true)
assert_output "show contains prompt content" "snake_case" "$SHOW_OUTPUT"

# 7. get <hash> (import prompt)
step "7. get <hash>"
rm -rf "$WORKSPACE/.prompts/rule/coding"
"$CLUMSIES" get "$SHORT_HASH" -Q
assert "imported file exists in .prompts/" test -d "$WORKSPACE/.prompts"
FOUND=$(find "$WORKSPACE/.prompts" -name "*SNAKE_CASE*" -type f 2>/dev/null | head -1)
assert "SNAKE_CASE file was imported" test -n "$FOUND"

# 8. pub (bundle)
step "8. pub bundle"
mkdir -p "$WORKSPACE/bundle-test/conduct"
printf "# Conduct Rule\n\nBe nice.\n" > "$WORKSPACE/bundle-test/conduct/00_BE_NICE.md"
cat > "$WORKSPACE/bundle-test/META.md" << 'METAEOF'
---
name: test-bundle
description: A test bundle
task: testing
---
# Test Meta Prompt

This is a test meta-prompt file.
METAEOF
"$CLUMSIES" pub bundle-test/META.md bundle-test/conduct -Q
BUNDLES_INDEX="$HOME_DIR/.clumsies/registry/bundles/index.json"
assert "bundles/index.json exists" test -f "$BUNDLES_INDEX"
assert_file_contains "bundle name in index" "$BUNDLES_INDEX" "test-bundle"
# Verify meta_prompt hash points to a file in prompts/, not meta-prompts/
META_HASH=$(grep -o '"meta_prompt": "[a-f0-9]*"' "$BUNDLES_INDEX" | head -1 | cut -d'"' -f4)
assert "meta-prompt file in prompts/" test -f "$HOME_DIR/.clumsies/registry/prompts/$META_HASH"

# 9. get <bundle>
step "9. get bundle"
rm -rf "$WORKSPACE/.prompts"
"$CLUMSIES" get test-bundle -Q
assert ".prompts/ created" test -d "$WORKSPACE/.prompts"
CONDUCT_FILE=$(find "$WORKSPACE/.prompts" -name "*BE_NICE*" -type f 2>/dev/null | head -1)
assert "bundle prompt imported" test -n "$CONDUCT_FILE"
assert "meta-prompt created at project root" test -f "$WORKSPACE/META.md"

# 10. set <hash> -d "new description"
step "10. set metadata"
CONDUCT_HASH=$(grep -o '"hash": "[a-f0-9]*"' "$PROMPTS_INDEX" | tail -1 | cut -d'"' -f4)
CONDUCT_SHORT="${CONDUCT_HASH:0:8}"
"$CLUMSIES" set "$CONDUCT_SHORT" -d "Updated description" -Q
assert_file_contains "description updated" "$PROMPTS_INDEX" "Updated description"

# 11. rm <hash>
step "11. rm prompt"
"$CLUMSIES" rm "$CONDUCT_SHORT" -Q
assert_file_not_contains "prompt removed from index" "$PROMPTS_INDEX" "$CONDUCT_HASH"
assert "prompt file deleted" test ! -f "$HOME_DIR/.clumsies/registry/prompts/$CONDUCT_HASH"

# Summary
printf "\n=== Results: %d passed, %d failed ===\n" "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
