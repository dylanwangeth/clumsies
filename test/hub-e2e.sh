#!/usr/bin/env bash
set -euo pipefail

# Hub Server e2e tests. Requires PostgreSQL running (docker-compose up -d).
# Usage: ./test/hub-e2e.sh [hub-binary-path]

HUB="${1:-./zig-out/bin/clumsies-hub}"
BASE="http://127.0.0.1:8400"
PASS=0
FAIL=0

step() { printf "\n=== %s ===\n" "$1"; }

assert_status() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        printf "  OK: %s (HTTP %s)\n" "$desc" "$actual"
        PASS=$((PASS + 1))
    else
        printf "  FAIL: %s (expected %s, got %s)\n" "$desc" "$expected" "$actual"
        FAIL=$((FAIL + 1))
        exit 1
    fi
}

assert_json() {
    local desc="$1" pattern="$2" body="$3"
    if echo "$body" | grep -q "$pattern"; then
        printf "  OK: %s\n" "$desc"
        PASS=$((PASS + 1))
    else
        printf "  FAIL: %s\n" "$desc"
        printf "  Expected pattern: %s\n" "$pattern"
        printf "  Body: %s\n" "$body"
        FAIL=$((FAIL + 1))
        exit 1
    fi
}

# Seed database with test org and maintainer user
seed_db() {
    PGPASSWORD=clumsies psql -h 127.0.0.1 -U clumsies -d clumsies -q <<'SQL'
INSERT INTO orgs (org_id, name) VALUES ('a0000000-0000-0000-0000-000000000001', 'acme')
  ON CONFLICT DO NOTHING;
INSERT INTO users (user_id, org_id, username, password_hash, role) VALUES
  ('usr-maintainer-001', 'a0000000-0000-0000-0000-000000000001', 'alice', 'testpass', 'maintainer')
  ON CONFLICT DO NOTHING;
INSERT INTO users (user_id, org_id, username, password_hash, role) VALUES
  ('usr-member-001', 'a0000000-0000-0000-0000-000000000001', 'bob', 'testpass', 'member')
  ON CONFLICT DO NOTHING;
INSERT INTO library_manifest (org_id, revision) VALUES ('a0000000-0000-0000-0000-000000000001', 0)
  ON CONFLICT DO NOTHING;
INSERT INTO prompts (prompt_id, org_id, canonical_name, kind, content, content_hash) VALUES
  ('p-test-001', 'a0000000-0000-0000-0000-000000000001', 'coding/STYLE', 'rule', '# STYLE', 'sha256:abc123')
  ON CONFLICT DO NOTHING;
INSERT INTO prompts (prompt_id, org_id, canonical_name, kind, content, content_hash) VALUES
  ('p-test-002', 'a0000000-0000-0000-0000-000000000001', 'cmd/COMMIT', 'workflow', '# COMMIT', 'sha256:def456')
  ON CONFLICT DO NOTHING;
SQL
}

# Start hub server in background
start_hub() {
    export HUB_PORT=8400
    export HUB_DB_HOST=127.0.0.1
    export HUB_DB_PORT=5432
    export HUB_DB_NAME=clumsies
    export HUB_DB_USER=clumsies
    export HUB_DB_PASSWORD=clumsies

    "$HUB" &
    HUB_PID=$!
    sleep 2

    if ! kill -0 "$HUB_PID" 2>/dev/null; then
        echo "FATAL: Hub server failed to start"
        exit 1
    fi
    echo "Hub server running (PID $HUB_PID)"
}

cleanup() {
    if [ -n "${HUB_PID:-}" ]; then
        kill "$HUB_PID" 2>/dev/null || true
        wait "$HUB_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Helper: do a curl and capture status + body
call() {
    local method="$1" path="$2" body="${3:-}"
    local auth="${TOKEN:+Authorization: Bearer $TOKEN}"
    local args=(-s -w "\n%{http_code}" -X "$method" "$BASE$path")
    if [ -n "$auth" ]; then args+=(-H "$auth"); fi
    if [ -n "$body" ]; then args+=(-H "Content-Type: application/json" -d "$body"); fi
    curl "${args[@]}"
}

parse_response() {
    local raw="$1"
    BODY=$(echo "$raw" | sed '$d')
    STATUS=$(echo "$raw" | tail -1)
}

# Setup: start hub first (runs migrations), then seed
start_hub
seed_db

# Auth: login as maintainer
step "Auth: login"
RAW=$(call POST "/api/auth/login" '{"username":"alice","credential":"testpass"}')
parse_response "$RAW"
assert_status "login succeeds" "200" "$STATUS"
assert_json "returns access_token" "access_token" "$BODY"
TOKEN=$(echo "$BODY" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

step "Auth: me"
RAW=$(call GET "/api/auth/me")
parse_response "$RAW"
assert_status "me returns 200" "200" "$STATUS"
assert_json "returns username alice" "alice" "$BODY"
assert_json "returns role maintainer" "maintainer" "$BODY"

# Org Members
step "Org Members: list"
RAW=$(call GET "/api/org/members")
parse_response "$RAW"
assert_status "list members" "200" "$STATUS"
assert_json "contains alice" "alice" "$BODY"

step "Org Members: invite"
RAW=$(call POST "/api/org/members" '{"username":"carol","role":"member"}')
parse_response "$RAW"
assert_status "invite member" "201" "$STATUS"
assert_json "returns carol" "carol" "$BODY"
CAROL_ID=$(echo "$BODY" | grep -o '"user_id":"[^"]*"' | cut -d'"' -f4)

step "Org Members: change role"
RAW=$(call PATCH "/api/org/members/$CAROL_ID" '{"role":"maintainer"}')
parse_response "$RAW"
assert_status "change role" "200" "$STATUS"
assert_json "role is maintainer" "maintainer" "$BODY"

step "Org Members: remove"
RAW=$(call DELETE "/api/org/members/$CAROL_ID")
parse_response "$RAW"
assert_status "remove member" "204" "$STATUS"

# Library
step "Library: list prompts"
RAW=$(call GET "/api/org/library/prompts")
parse_response "$RAW"
assert_status "list prompts" "200" "$STATUS"
assert_json "contains STYLE" "STYLE" "$BODY"

step "Library: manifest"
RAW=$(call GET "/api/org/library/manifest")
parse_response "$RAW"
assert_status "get manifest" "200" "$STATUS"
assert_json "contains revision" "revision" "$BODY"

# Bundles
step "Bundle: create"
RAW=$(call POST "/api/org/bundles" '{"name":"test-bundle","description":"test","prompt_ids":["p-test-001","p-test-002"]}')
parse_response "$RAW"
assert_status "create bundle" "201" "$STATUS"
assert_json "returns name" "test-bundle" "$BODY"

step "Bundle: list"
RAW=$(call GET "/api/org/bundles")
parse_response "$RAW"
assert_status "list bundles" "200" "$STATUS"
assert_json "contains test-bundle" "test-bundle" "$BODY"

step "Bundle: get"
RAW=$(call GET "/api/org/bundles/test-bundle")
parse_response "$RAW"
assert_status "get bundle" "200" "$STATUS"
assert_json "contains prompt_ids" "p-test-001" "$BODY"

step "Bundle: update"
RAW=$(call PUT "/api/org/bundles/test-bundle" '{"description":"updated desc","prompt_ids":["p-test-001"]}')
parse_response "$RAW"
assert_status "update bundle" "200" "$STATUS"

step "Bundle: delete"
RAW=$(call DELETE "/api/org/bundles/test-bundle")
parse_response "$RAW"
assert_status "delete bundle" "204" "$STATUS"

# Workspaces
step "Workspace: create"
RAW=$(call POST "/api/workspaces" '{"name":"test-ws"}')
parse_response "$RAW"
assert_status "create workspace" "201" "$STATUS"
assert_json "returns ws_id" "ws_id" "$BODY"
WS_ID=$(echo "$BODY" | grep -o '"ws_id":"[^"]*"' | cut -d'"' -f4)

step "Workspace: get"
RAW=$(call GET "/api/workspaces/$WS_ID")
parse_response "$RAW"
assert_status "get workspace" "200" "$STATUS"
assert_json "returns name" "test-ws" "$BODY"

step "Workspace: list members"
RAW=$(call GET "/api/workspaces/$WS_ID/members")
parse_response "$RAW"
assert_status "list members" "200" "$STATUS"
assert_json "contains alice" "alice" "$BODY"

step "Workspace: invite member"
RAW=$(call POST "/api/workspaces/$WS_ID/members" '{"user_id":"usr-member-001","role":"member"}')
parse_response "$RAW"
assert_status "invite member" "201" "$STATUS"

step "Workspace: member can access"
BOB_TOKEN_TMP=$(call POST "/api/auth/login" '{"username":"bob","credential":"testpass"}' | sed '$d' | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
SAVED_TOKEN="$TOKEN"
TOKEN="$BOB_TOKEN_TMP"
RAW=$(call GET "/api/workspaces/$WS_ID")
parse_response "$RAW"
assert_status "bob accesses ws as member" "200" "$STATUS"
TOKEN="$SAVED_TOKEN"

step "Workspace: change member role"
RAW=$(call PATCH "/api/workspaces/$WS_ID/members/usr-member-001" '{"role":"admin"}')
parse_response "$RAW"
assert_status "change role" "200" "$STATUS"

step "Workspace: remove member"
RAW=$(call DELETE "/api/workspaces/$WS_ID/members/usr-member-001")
parse_response "$RAW"
assert_status "remove member" "204" "$STATUS"

step "Workspace: delete"
RAW=$(call DELETE "/api/workspaces/$WS_ID")
parse_response "$RAW"
assert_status "delete workspace" "204" "$STATUS"

# Permission checks
step "Permission: member cannot invite"
RAW=$(call POST "/api/auth/login" '{"username":"bob","credential":"testpass"}')
parse_response "$RAW"
BOB_TOKEN=$(echo "$BODY" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
TOKEN="$BOB_TOKEN"

RAW=$(call POST "/api/org/members" '{"username":"dave","role":"member"}')
parse_response "$RAW"
assert_status "member cannot invite" "403" "$STATUS"

step "Permission: member cannot delete bundle"
RAW=$(call DELETE "/api/org/bundles/nonexistent")
parse_response "$RAW"
assert_status "member cannot delete bundle" "403" "$STATUS"

# Scope enforcement tests
step "Scope: login with limited scopes"
RAW=$(call POST "/api/auth/login" '{"username":"alice","credential":"testpass","scopes":"library:read,stats:read"}')
parse_response "$RAW"
assert_status "limited scope login" "200" "$STATUS"
LIMITED_TOKEN=$(echo "$BODY" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

step "Scope: me shows scopes"
TOKEN="$LIMITED_TOKEN"
RAW=$(call GET "/api/auth/me")
parse_response "$RAW"
assert_status "me with scopes" "200" "$STATUS"
assert_json "scopes field present" "library:read" "$BODY"

step "Scope: limited token cannot create bundle"
RAW=$(call POST "/api/org/bundles" '{"name":"scope-test","description":"test","prompt_ids":[]}')
parse_response "$RAW"
assert_status "limited scope blocked" "403" "$STATUS"

# Restore full token
TOKEN=$(call POST "/api/auth/login" '{"username":"alice","credential":"testpass"}' | sed '$d' | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

# Context: create workspace for context tests (as maintainer alice)
TOKEN=$(call POST "/api/auth/login" '{"username":"alice","credential":"testpass"}' | sed '$d' | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

step "Context setup: create workspace"
RAW=$(call POST "/api/workspaces" '{"name":"ctx-test-ws"}')
parse_response "$RAW"
assert_status "create workspace for context" "201" "$STATUS"
CTX_WS=$(echo "$BODY" | grep -o '"ws_id":"[^"]*"' | cut -d'"' -f4)

# Add bob as member for later permission tests
RAW=$(call POST "/api/workspaces/$CTX_WS/members" '{"user_id":"usr-member-001","role":"member"}')
parse_response "$RAW"
assert_status "add bob to context ws" "201" "$STATUS"

step "Context: list branches (empty)"
RAW=$(call GET "/api/workspaces/$CTX_WS/context/branches")
parse_response "$RAW"
assert_status "list branches" "200" "$STATUS"
assert_json "returns branches array" "branches" "$BODY"

step "Context: write file (creates member branch)"
RAW=$(curl -s -w "\n%{http_code}" -X PUT "$BASE/api/workspaces/$CTX_WS/context/file?path=spec/API.md" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/octet-stream" \
    -d "# API Design")
parse_response "$RAW"
assert_status "write context file" "200" "$STATUS"
assert_json "returns branch name" "alice" "$BODY"
assert_json "returns path" "spec/API.md" "$BODY"
assert_json "returns hash" "hash" "$BODY"

step "Context: list files on member branch"
RAW=$(call GET "/api/workspaces/$CTX_WS/context/files?branch=alice")
parse_response "$RAW"
assert_status "list files on branch" "200" "$STATUS"
assert_json "contains spec/API.md" "spec/API.md" "$BODY"

step "Context: list files on main (empty)"
RAW=$(call GET "/api/workspaces/$CTX_WS/context/files")
parse_response "$RAW"
assert_status "list files on main" "200" "$STATUS"

step "Context: read file content"
RAW=$(curl -s -w "\n%{http_code}" -X GET "$BASE/api/workspaces/$CTX_WS/context/file/content?path=spec/API.md&branch=alice" \
    -H "Authorization: Bearer $TOKEN")
parse_response "$RAW"
assert_status "read file content" "200" "$STATUS"
assert_json "content matches" "API Design" "$BODY"

step "Context: read nonexistent file"
RAW=$(curl -s -w "\n%{http_code}" -X GET "$BASE/api/workspaces/$CTX_WS/context/file/content?path=nope.md&branch=alice" \
    -H "Authorization: Bearer $TOKEN")
parse_response "$RAW"
assert_status "nonexistent file returns 404" "404" "$STATUS"

step "Context: create PR"
RAW=$(call POST "/api/workspaces/$CTX_WS/context/prs" '{"description":"Add API spec"}')
parse_response "$RAW"
assert_status "create context PR" "201" "$STATUS"
assert_json "returns pr_id" "pr_id" "$BODY"
assert_json "status is open" "open" "$BODY"
PR_ID=$(echo "$BODY" | grep -o '"pr_id":"[^"]*"' | cut -d'"' -f4)

step "Context: list PRs"
RAW=$(call GET "/api/workspaces/$CTX_WS/context/prs")
parse_response "$RAW"
assert_status "list PRs" "200" "$STATUS"
assert_json "contains PR" "$PR_ID" "$BODY"

step "Context: list PRs with status filter"
RAW=$(call GET "/api/workspaces/$CTX_WS/context/prs?status=open")
parse_response "$RAW"
assert_status "list open PRs" "200" "$STATUS"
assert_json "contains open PR" "$PR_ID" "$BODY"

step "Context: get PR detail"
RAW=$(call GET "/api/workspaces/$CTX_WS/context/prs/$PR_ID")
parse_response "$RAW"
assert_status "get PR detail" "200" "$STATUS"
assert_json "has description" "Add API spec" "$BODY"
assert_json "has files" "spec/API.md" "$BODY"

step "Context: add PR comment"
RAW=$(call POST "/api/workspaces/$CTX_WS/context/prs/$PR_ID/comments" '{"body":"LGTM"}')
parse_response "$RAW"
assert_status "add PR comment" "201" "$STATUS"
assert_json "returns comment_id" "comment_id" "$BODY"

step "Context: merge PR (maintainer)"
RAW=$(call PUT "/api/workspaces/$CTX_WS/context/prs/$PR_ID" '{"action":"merge"}')
parse_response "$RAW"
assert_status "merge PR" "200" "$STATUS"
assert_json "merged is true" "true" "$BODY"

step "Context: file now on main after merge"
RAW=$(call GET "/api/workspaces/$CTX_WS/context/files")
parse_response "$RAW"
assert_status "list main after merge" "200" "$STATUS"
assert_json "main has spec/API.md" "spec/API.md" "$BODY"

step "Context: manifest reflects context"
RAW=$(call GET "/api/workspaces/$CTX_WS/manifest")
parse_response "$RAW"
assert_status "get manifest" "200" "$STATUS"
assert_json "manifest has context" "spec/API.md" "$BODY"

step "Context: member cannot merge"
TOKEN="$BOB_TOKEN"
# Bob writes a file first
curl -s -X PUT "$BASE/api/workspaces/$CTX_WS/context/file?path=research/notes.md" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/octet-stream" \
    -d "# Research Notes" > /dev/null
RAW=$(call POST "/api/workspaces/$CTX_WS/context/prs" '{"description":"Add research"}')
parse_response "$RAW"
BOB_PR_ID=$(echo "$BODY" | grep -o '"pr_id":"[^"]*"' | cut -d'"' -f4)
RAW=$(call PUT "/api/workspaces/$CTX_WS/context/prs/$BOB_PR_ID" '{"action":"merge"}')
parse_response "$RAW"
assert_status "member cannot merge" "403" "$STATUS"

step "Context: rebase branch"
RAW=$(call POST "/api/workspaces/$CTX_WS/context/branches/bob/rebase")
parse_response "$RAW"
assert_status "rebase succeeds" "200" "$STATUS"
assert_json "status is rebased" "rebased" "$BODY"

step "Context: cannot rebase main"
RAW=$(call POST "/api/workspaces/$CTX_WS/context/branches/main/rebase")
parse_response "$RAW"
assert_status "cannot rebase main" "400" "$STATUS"

step "Context: delete file on branch"
RAW=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE/api/workspaces/$CTX_WS/context/file?path=research/notes.md" \
    -H "Authorization: Bearer $TOKEN")
parse_response "$RAW"
assert_status "delete file" "200" "$STATUS"

# Cleanup: delete context test workspace (as maintainer)
TOKEN=$(call POST "/api/auth/login" '{"username":"alice","credential":"testpass"}' | sed '$d' | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
RAW=$(call DELETE "/api/workspaces/$CTX_WS")
parse_response "$RAW"
assert_status "cleanup: delete context ws" "204" "$STATUS"

# Summary
printf "\n=== Results: %d passed, %d failed ===\n" "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
