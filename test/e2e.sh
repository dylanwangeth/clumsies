#!/usr/bin/env bash
set -euo pipefail

CLUMSIES_RAW="${CLUMSIES:-./zig-out/bin/clumsies}"
CLUMSIES="$(cd "$(dirname "$CLUMSIES_RAW")" && pwd)/$(basename "$CLUMSIES_RAW")"

TMPBASE=$(mktemp -d)
trap 'rm -rf "$TMPBASE"' EXIT
HOME_DIR="$TMPBASE/home"
export HOME="$HOME_DIR"
mkdir -p "$HOME_DIR"

PASS=0
FAIL=0

step() { printf "\n=== %s ===\n" "$1"; }

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

assert_exit() {
    local desc="$1" expected_exit="$2"; shift 2
    local actual_exit=0
    "$@" >/dev/null 2>&1 || actual_exit=$?
    if [ "$actual_exit" = "$expected_exit" ]; then
        printf "  OK: %s (exit %s)\n" "$desc" "$actual_exit"
        PASS=$((PASS + 1))
    else
        printf "  FAIL: %s (expected exit %s, got %s)\n" "$desc" "$expected_exit" "$actual_exit"
        FAIL=$((FAIL + 1))
        exit 1
    fi
}

# 1. Bare invocation shows TUI placeholder
step "1. bare invocation"
OUTPUT=$("$CLUMSIES" 2>&1 || true)
assert_output "shows TUI placeholder" "TUI Dashboard" "$OUTPUT"
assert_output "shows help" "clumsies login" "$OUTPUT"

# 2. Help
step "2. help"
OUTPUT=$("$CLUMSIES" help 2>&1)
assert_output "help lists login" "login" "$OUTPUT"
assert_output "help lists init" "init" "$OUTPUT"
assert_output "help lists sync" "sync" "$OUTPUT"
assert_output "help lists mcp" "mcp" "$OUTPUT"

# 3. Version
step "3. version"
OUTPUT=$("$CLUMSIES" --version 2>&1)
assert_output "version shown" "clumsies" "$OUTPUT"

# 4. Unknown command
step "4. unknown command"
OUTPUT=$("$CLUMSIES" add 2>&1 || true)
assert_output "unknown command error" "unknown command" "$OUTPUT"

OUTPUT=$("$CLUMSIES" push 2>&1 || true)
assert_output "old command rejected" "unknown command" "$OUTPUT"

# 5. Old commands all rejected
step "5. old commands rejected"
for cmd in remote pull clone status log ls rm show set get pub stats config upgrade; do
    OUTPUT=$("$CLUMSIES" "$cmd" 2>&1 || true)
    assert_output "old command '$cmd' rejected" "unknown command" "$OUTPUT"
done

# 6. Login help
step "6. login help"
OUTPUT=$("$CLUMSIES" login -h 2>&1 || true)
assert_output "login help shown" "hub-url" "$OUTPUT"

# 7. Init help
step "7. init help"
OUTPUT=$("$CLUMSIES" init -h 2>&1 || true)
assert_output "init help shown" "create" "$OUTPUT"

# 8. Sync without workspace binding
step "8. sync without workspace"
OUTPUT=$("$CLUMSIES" sync 2>&1 || true)
assert_output "sync requires init" "clumsies init" "$OUTPUT"

# 9. MCP serve help
step "9. mcp help"
OUTPUT=$("$CLUMSIES" mcp 2>&1 || true)
assert_output "mcp help shown" "serve" "$OUTPUT"

# Summary
printf "\n=== Results: %d passed, %d failed ===\n" "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
