#!/usr/bin/env bash
set -euo pipefail

# Hub Server e2e tests. Requires PostgreSQL running (docker-compose up -d).
# Usage: ./test/hub-e2e.sh [hub-binary-path]

HUB="${1:-./zig-out/bin/clumsies-hub}"
HUB_PORT="${HUB_E2E_PORT:-8400}"
BASE="http://127.0.0.1:${HUB_PORT}"
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

# Seed database with test org and maintainer user. Uses a local psql
# if available, otherwise falls back to the docker-compose postgres container.
run_psql() {
    if command -v psql >/dev/null 2>&1; then
        PGPASSWORD=clumsies psql -h 127.0.0.1 -U clumsies -d clumsies -q
    elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^clumsies-postgres-1$'; then
        docker exec -i -e PGPASSWORD=clumsies clumsies-postgres-1 psql -U clumsies -d clumsies -q
    else
        echo "FATAL: neither psql nor clumsies-postgres-1 container is available" >&2
        return 1
    fi
}

seed_db() {
    run_psql <<'SQL'
INSERT INTO orgs (org_id, name) VALUES ('a0000000-0000-0000-0000-000000000001', 'acme')
  ON CONFLICT DO NOTHING;
INSERT INTO users (user_id, org_id, username, password_hash, role, status) VALUES
  ('usr-maintainer-001', 'a0000000-0000-0000-0000-000000000001', 'alice', 'testpass', 'maintainer', 'active')
  ON CONFLICT DO NOTHING;
INSERT INTO users (user_id, org_id, username, password_hash, role, status) VALUES
  ('usr-member-001', 'a0000000-0000-0000-0000-000000000001', 'bob', 'testpass', 'member', 'active')
  ON CONFLICT DO NOTHING;
INSERT INTO artifact_manifest (org_id, revision) VALUES ('a0000000-0000-0000-0000-000000000001', 0)
  ON CONFLICT DO NOTHING;
INSERT INTO rules (rule_id, org_id, path, content, content_hash) VALUES
  ('p-test-001', 'a0000000-0000-0000-0000-000000000001', 'rule/coding/STYLE.md', '# STYLE', 'sha256:abc123')
  ON CONFLICT (rule_id) DO UPDATE SET
    path = EXCLUDED.path,
    content = EXCLUDED.content,
    content_hash = EXCLUDED.content_hash;
INSERT INTO rules (rule_id, org_id, path, content, content_hash) VALUES
  ('p-test-002', 'a0000000-0000-0000-0000-000000000001', 'workflow/cmd/COMMIT.md', '# COMMIT', 'sha256:def456')
  ON CONFLICT (rule_id) DO UPDATE SET
    path = EXCLUDED.path,
    content = EXCLUDED.content,
    content_hash = EXCLUDED.content_hash;
INSERT INTO rules (rule_id, org_id, path, content, content_hash) VALUES
  ('p-test-mpf', 'a0000000-0000-0000-0000-000000000001', 'META_PROMPT.md', '# clumsies Protocol Bootstrap', 'sha256:mpf001')
  ON CONFLICT (rule_id) DO UPDATE SET
    path = EXCLUDED.path,
    content = EXCLUDED.content,
    content_hash = EXCLUDED.content_hash;
SQL
}

# Start hub server in background
start_hub() {
    export HUB_PORT
    export HUB_DB_HOST=127.0.0.1
    export HUB_DB_PORT=5432
    export HUB_DB_NAME=clumsies
    export HUB_DB_USER=clumsies
    export HUB_DB_PASSWORD=clumsies

    "$HUB" &
    HUB_PID=$!

    local attempts=150
    local delay_s=0.2
    local i
    local http_status
    for ((i = 1; i <= attempts; i++)); do
        if ! kill -0 "$HUB_PID" 2>/dev/null; then
            echo "FATAL: Hub server failed to start"
            exit 1
        fi
        http_status="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 1 --max-time 1 "$BASE/api/auth/me" || true)"
        case "$http_status" in
            200|401|403)
                echo "Hub server running (PID $HUB_PID)"
                return
                ;;
        esac
        sleep "$delay_s"
    done

    echo "FATAL: Hub server did not become ready at $BASE after $attempts attempts"
    exit 1
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
assert_json "returns invite_token" "invite_token" "$BODY"
assert_json "status is invited" "invited" "$BODY"
CAROL_ID=$(echo "$BODY" | grep -o '"user_id":"[^"]*"' | cut -d'"' -f4)
INVITE_TOKEN=$(echo "$BODY" | grep -o '"invite_token":"[^"]*"' | cut -d'"' -f4)

step "Invite: login as invited user fails"
RAW=$(call POST "/api/auth/login" '{"username":"carol","credential":"anypass"}')
parse_response "$RAW"
assert_status "invited user cannot login" "401" "$STATUS"

step "Invite: activate with token"
RAW=$(call POST "/api/auth/activate" "{\"username\":\"carol\",\"invite_token\":\"$INVITE_TOKEN\",\"credential\":\"carolpass\"}")
parse_response "$RAW"
assert_status "activate succeeds" "200" "$STATUS"
assert_json "returns access_token" "access_token" "$BODY"

step "Invite: login after activation"
RAW=$(call POST "/api/auth/login" '{"username":"carol","credential":"carolpass"}')
parse_response "$RAW"
assert_status "activated user can login" "200" "$STATUS"

step "Invite: reissue fails for active user"
RAW=$(call POST "/api/org/members/$CAROL_ID/reissue-invite" '{}')
parse_response "$RAW"
assert_status "reissue fails for active" "400" "$STATUS"

step "Org Members: list shows status"
RAW=$(call GET "/api/org/members")
parse_response "$RAW"
assert_status "list members with status" "200" "$STATUS"
assert_json "contains status field" "status" "$BODY"

step "Org Members: change role"
RAW=$(call PATCH "/api/org/members/$CAROL_ID" '{"role":"maintainer"}')
parse_response "$RAW"
assert_status "change role" "200" "$STATUS"
assert_json "role is maintainer" "maintainer" "$BODY"

step "Org Members: remove"
RAW=$(call DELETE "/api/org/members/$CAROL_ID")
parse_response "$RAW"
assert_status "remove member" "204" "$STATUS"

# Artifact
step "Artifact: list rules"
RAW=$(call GET "/api/org/artifact/rules")
parse_response "$RAW"
assert_status "list rules" "200" "$STATUS"
assert_json "contains STYLE path" "rule/coding/STYLE.md" "$BODY"
assert_json "returns path field" '"path":' "$BODY"

step "Artifact: get rule by rule_id"
RAW=$(call GET "/api/org/artifact/rule?rule_id=p-test-001")
parse_response "$RAW"
assert_status "get by rule_id" "200" "$STATUS"
assert_json "contains path" "rule/coding/STYLE.md" "$BODY"

step "Artifact: get rule by path"
RAW=$(call GET "/api/org/artifact/rule?path=rule/coding/STYLE.md")
parse_response "$RAW"
assert_status "get by path" "200" "$STATUS"
assert_json "contains rule_id" "p-test-001" "$BODY"

step "Artifact: get rule content by rule_id"
RAW=$(call GET "/api/org/artifact/rule/content?rule_id=p-test-001")
parse_response "$RAW"
assert_status "get content" "200" "$STATUS"
assert_json "contains body" "STYLE" "$BODY"

step "Artifact: manifest"
RAW=$(call GET "/api/org/artifact/manifest")
parse_response "$RAW"
assert_status "get manifest" "200" "$STATUS"
assert_json "contains revision" "revision" "$BODY"
assert_json "rule entries carry path" '"path":"rule/coding/STYLE.md"' "$BODY"
assert_json "rule entries carry hash" '"hash":"sha256:abc123"' "$BODY"
assert_json "includes reserved MPF path" '"path":"META_PROMPT.md"' "$BODY"

# Rule PRs (multi-operation model)
step "Rule PR: create with modify operation"
RAW=$(call POST "/api/org/rule-prs" '{"title":"Tighten STYLE rules","body":"Tighten STYLE rules","operations":[{"type":"modify","rule_id":"p-test-001","base_hash":"sha256:abc123","content":"# STYLE\n\nTightened.\n\n## Rules\n\n- Rule one"}]}')
parse_response "$RAW"
assert_status "create rule PR" "201" "$STATUS"
assert_json "returns pr_id" "pr_id" "$BODY"
assert_json "status open" "open" "$BODY"
PPR_ID=$(echo "$BODY" | grep -o '"pr_id":"[^"]*"' | cut -d'"' -f4)

step "Rule PR: reject empty operations"
RAW=$(call POST "/api/org/rule-prs" '{"title":"empty","body":"empty","operations":[]}')
parse_response "$RAW"
assert_status "empty ops rejected" "400" "$STATUS"

step "Rule PR: reject stale base_hash"
RAW=$(call POST "/api/org/rule-prs" '{"title":"stale","body":"stale","operations":[{"type":"modify","rule_id":"p-test-001","base_hash":"sha256:wrong","content":"# X\n\nD\n\n## S\n\n- R"}]}')
parse_response "$RAW"
assert_status "stale base_hash 409" "409" "$STATUS"

step "Rule PR: list"
RAW=$(call GET "/api/org/rule-prs")
parse_response "$RAW"
assert_status "list rule PRs" "200" "$STATUS"
assert_json "contains PR" "$PPR_ID" "$BODY"

step "Rule PR: get detail"
RAW=$(call GET "/api/org/rule-prs/$PPR_ID")
parse_response "$RAW"
assert_status "get rule PR" "200" "$STATUS"
assert_json "has operations" "operations" "$BODY"
assert_json "operation type modify" '"type":"modify"' "$BODY"

step "Rule PR: accept as maintainer"
RAW=$(call PUT "/api/org/rule-prs/$PPR_ID" '{"action":"accept"}')
parse_response "$RAW"
assert_status "accept rule PR" "200" "$STATUS"
assert_json "status accepted" "accepted" "$BODY"

step "Rule PR: artifact now reflects accepted content"
RAW=$(call GET "/api/org/artifact/rule/content?rule_id=p-test-001")
parse_response "$RAW"
assert_status "get updated content" "200" "$STATUS"
assert_json "contains Tightened" "Tightened" "$BODY"

step "Rule PR: create with rename operation"
# First get current hash of p-test-002
RAW=$(call GET "/api/org/artifact/rule?rule_id=p-test-002")
parse_response "$RAW"
P002_HASH=$(echo "$BODY" | grep -o '"content_hash":"[^"]*"' | cut -d'"' -f4)
RAW=$(call POST "/api/org/rule-prs" "{\"title\":\"Relocate COMMIT\",\"body\":\"Relocate COMMIT\",\"operations\":[{\"type\":\"rename\",\"rule_id\":\"p-test-002\",\"base_hash\":\"$P002_HASH\",\"new_path\":\"workflow/git/COMMIT.md\"}]}")
parse_response "$RAW"
assert_status "create rename PR" "201" "$STATUS"
RENAME_PR_ID=$(echo "$BODY" | grep -o '"pr_id":"[^"]*"' | cut -d'"' -f4)

step "Rule PR: accept rename"
RAW=$(call PUT "/api/org/rule-prs/$RENAME_PR_ID" '{"action":"accept"}')
parse_response "$RAW"
assert_status "accept rename" "200" "$STATUS"

step "Rule PR: path updated, rule_id preserved"
RAW=$(call GET "/api/org/artifact/rule?rule_id=p-test-002")
parse_response "$RAW"
assert_status "get by id after rename" "200" "$STATUS"
assert_json "path is new" "workflow/git/COMMIT.md" "$BODY"

# Bundles
step "Bundle: create"
RAW=$(call POST "/api/org/bundles" '{"name":"test-bundle","description":"test","rule_ids":["p-test-001","p-test-002"]}')
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
assert_json "contains rule_ids" "p-test-001" "$BODY"

step "Bundle: update"
RAW=$(call PUT "/api/org/bundles/test-bundle" '{"description":"updated desc","rule_ids":["p-test-001"]}')
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

# Trace upload: POST batch of events and verify stats reflect them.
# The CLI upload_worker is unit-tested separately; this section exercises
# the hub ingest endpoint that the worker posts to.
step "Trace: upload setup + refer batch"
TRACE_BATCH='{"events":[{"ws_id":"'"$WS_ID"'","session_id":"sess-e2e-1","event_id":0,"type":"setup","timestamp":1000},{"ws_id":"'"$WS_ID"'","session_id":"sess-e2e-1","event_id":1,"type":"refer","timestamp":1001,"rule_id":"p-test-001","constraint_id":"c-1"},{"ws_id":"'"$WS_ID"'","session_id":"sess-e2e-1","event_id":2,"type":"refer","timestamp":1002,"rule_id":"p-test-001","constraint_id":"c-2"}]}'
RAW=$(call POST "/api/attestations" "$TRACE_BATCH")
parse_response "$RAW"
assert_status "upload batch" "200" "$STATUS"
assert_json "reports accepted" '"accepted":3' "$BODY"

step "Trace: workspace stats reflect refers"
RAW=$(call GET "/api/stats/workspace/$WS_ID")
parse_response "$RAW"
assert_status "get workspace stats" "200" "$STATUS"
assert_json "total_refer_count is 2" '"total_refer_count":2' "$BODY"

step "Trace: replay batch is deduplicated"
RAW=$(call POST "/api/attestations" "$TRACE_BATCH")
parse_response "$RAW"
assert_status "replay batch" "200" "$STATUS"
assert_json "all three deduplicated" '"deduplicated":3' "$BODY"

RAW=$(call GET "/api/stats/workspace/$WS_ID")
parse_response "$RAW"
assert_json "replay did not double count" '"total_refer_count":2' "$BODY"

step "Trace: append new event advances stats"
APPEND_BATCH='{"events":[{"ws_id":"'"$WS_ID"'","session_id":"sess-e2e-1","event_id":3,"type":"refer","timestamp":1003,"rule_id":"p-test-001","constraint_id":"c-3"}]}'
RAW=$(call POST "/api/attestations" "$APPEND_BATCH")
parse_response "$RAW"
assert_status "append batch" "200" "$STATUS"
assert_json "new event accepted" '"accepted":1' "$BODY"

RAW=$(call GET "/api/stats/workspace/$WS_ID")
parse_response "$RAW"
assert_json "refer count advanced to 3" '"total_refer_count":3' "$BODY"

step "Trace: missing body rejected"
RAW=$(curl -s -w "\n%{http_code}" -X POST "$BASE/api/attestations" -H "Authorization: Bearer $TOKEN")
parse_response "$RAW"
assert_status "missing body 400" "400" "$STATUS"

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
RAW=$(call POST "/api/auth/login" '{"username":"alice","credential":"testpass","scopes":"artifact:read,stats:read"}')
parse_response "$RAW"
assert_status "limited scope login" "200" "$STATUS"
LIMITED_TOKEN=$(echo "$BODY" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

step "Scope: me shows scopes"
TOKEN="$LIMITED_TOKEN"
RAW=$(call GET "/api/auth/me")
parse_response "$RAW"
assert_status "me with scopes" "200" "$STATUS"
assert_json "scopes field present" "artifact:read" "$BODY"

step "Scope: limited token cannot create bundle"
RAW=$(call POST "/api/org/bundles" '{"name":"scope-test","description":"test","rule_ids":[]}')
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

step "Context: list files on main (empty)"
RAW=$(call GET "/api/workspaces/$CTX_WS/context/files")
parse_response "$RAW"
assert_status "list files on main" "200" "$STATUS"
assert_json "returns files array" "files" "$BODY"

step "Context: create PR with create operation"
RAW=$(call POST "/api/workspaces/$CTX_WS/context/prs" '{"title":"Add API spec","body":"Add API spec","operations":[{"type":"create","path":"spec/API.md","content":"# API Design\n\nREST API specification.\n\n## Endpoints\n\n- GET /api"}]}')
parse_response "$RAW"
assert_status "create context PR" "201" "$STATUS"
assert_json "returns pr_id" "pr_id" "$BODY"
assert_json "status is open" "open" "$BODY"
assert_json "operation_count is 1" "\"operation_count\":1" "$BODY"
PR_ID=$(echo "$BODY" | grep -o '"pr_id":"[^"]*"' | cut -d'"' -f4)

step "Context: reject PR missing operations"
RAW=$(call POST "/api/workspaces/$CTX_WS/context/prs" '{"title":"empty","body":"empty","operations":[]}')
parse_response "$RAW"
assert_status "empty operations rejected" "400" "$STATUS"

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
assert_json "has title" "Add API spec" "$BODY"
assert_json "has operations" "operations" "$BODY"
assert_json "operation type create" '"type":"create"' "$BODY"
assert_json "operation path" "spec/API.md" "$BODY"

step "Context: add PR comment"
RAW=$(call POST "/api/workspaces/$CTX_WS/context/prs/$PR_ID/comments" '{"body":"LGTM"}')
parse_response "$RAW"
assert_status "add PR comment" "201" "$STATUS"
assert_json "returns comment_id" "comment_id" "$BODY"

step "Context: merge PR (maintainer)"
RAW=$(call PUT "/api/workspaces/$CTX_WS/context/prs/$PR_ID" '{"action":"merge"}')
parse_response "$RAW"
assert_status "merge PR" "200" "$STATUS"
assert_json "status merged" "merged" "$BODY"

step "Context: file now on main after merge"
RAW=$(call GET "/api/workspaces/$CTX_WS/context/files")
parse_response "$RAW"
assert_status "list main after merge" "200" "$STATUS"
assert_json "main has spec/API.md" "spec/API.md" "$BODY"
assert_json "file has context_id" "context_id" "$BODY"
CTX_ID=$(echo "$BODY" | grep -o '"context_id":"[^"]*"' | head -1 | cut -d'"' -f4)

step "Context: read file content by path"
RAW=$(curl -s -w "\n%{http_code}" -X GET "$BASE/api/workspaces/$CTX_WS/context/file/content?path=spec/API.md" \
    -H "Authorization: Bearer $TOKEN")
parse_response "$RAW"
assert_status "read file content by path" "200" "$STATUS"
assert_json "content matches" "API Design" "$BODY"

step "Context: read file content by context_id"
RAW=$(curl -s -w "\n%{http_code}" -X GET "$BASE/api/workspaces/$CTX_WS/context/file/content?context_id=$CTX_ID" \
    -H "Authorization: Bearer $TOKEN")
parse_response "$RAW"
assert_status "read by context_id" "200" "$STATUS"
assert_json "content matches" "API Design" "$BODY"

step "Context: read nonexistent file"
RAW=$(curl -s -w "\n%{http_code}" -X GET "$BASE/api/workspaces/$CTX_WS/context/file/content?path=nope.md" \
    -H "Authorization: Bearer $TOKEN")
parse_response "$RAW"
assert_status "nonexistent file returns 404" "404" "$STATUS"

step "Context: manifest reflects context"
RAW=$(call GET "/api/workspaces/$CTX_WS/manifest")
parse_response "$RAW"
assert_status "get manifest" "200" "$STATUS"
assert_json "context entries keyed by context_id" "$CTX_ID" "$BODY"
assert_json "context entries carry path" '"path":"spec/API.md"' "$BODY"

step "Context: branch endpoint is gone"
RAW=$(call GET "/api/workspaces/$CTX_WS/context/branches")
parse_response "$RAW"
assert_status "branches endpoint 404" "404" "$STATUS"

step "Context: PUT /context/file endpoint is gone"
RAW=$(curl -s -w "\n%{http_code}" -X PUT "$BASE/api/workspaces/$CTX_WS/context/file?path=x.md" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/octet-stream" \
    -d "junk")
parse_response "$RAW"
assert_status "PUT file endpoint 404" "404" "$STATUS"

step "Context: member cannot merge"
TOKEN="$BOB_TOKEN"
RAW=$(call POST "/api/workspaces/$CTX_WS/context/prs" '{"title":"Add research","body":"Add research","operations":[{"type":"create","path":"research/notes.md","content":"# Research Notes\n\nFindings from literature review.\n\n## Sources\n\n- Paper A"}]}')
parse_response "$RAW"
BOB_PR_ID=$(echo "$BODY" | grep -o '"pr_id":"[^"]*"' | cut -d'"' -f4)
RAW=$(call PUT "/api/workspaces/$CTX_WS/context/prs/$BOB_PR_ID" '{"action":"merge"}')
parse_response "$RAW"
assert_status "member cannot merge" "403" "$STATUS"

step "Context: member can reject own PR"
RAW=$(call PUT "/api/workspaces/$CTX_WS/context/prs/$BOB_PR_ID" '{"action":"reject"}')
parse_response "$RAW"
assert_status "member can reject" "200" "$STATUS"
assert_json "status rejected" "rejected" "$BODY"

# Cleanup: delete context test workspace (as maintainer)
TOKEN=$(call POST "/api/auth/login" '{"username":"alice","credential":"testpass"}' | sed '$d' | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
RAW=$(call DELETE "/api/workspaces/$CTX_WS")
parse_response "$RAW"
assert_status "cleanup: delete context ws" "204" "$STATUS"

# Summary
printf "\n=== Results: %d passed, %d failed ===\n" "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
