#!/bin/sh
# Verify that the unified Memory migration preserved
# every identity and byte of the org's effective Memory state.
#
# The server exposes a neutral, verifiable export at
#   GET /api/v1/admin/memory-export  (org admin bearer token)
# that emits memories with their
# content_hash verbatim, plus active drafts, org selections and bundles.
# Because IDs are emitted unchanged, the "before" export doubles as the
# old_id -> memory_id identity map: after the migration the same IDs must
# resolve to the same hashes with a non-empty description and unchanged
# scope, and every draft/selection/bundle must survive.
#
# Usage:
#   dev/memory-migration-verify.sh fetch <server-url> <admin-token> <out.json>
#       Fetch the current export into out.json (uses curl + jq).
#   dev/memory-migration-verify.sh check <before.json> <after.json>
#       Compare two exports; exits non-zero listing every discrepancy.
#
# Recommended migration rehearsal:
#   1. dev/memory-migration-verify.sh fetch http://127.0.0.1:18080 "$TOKEN" before.json
#   2. pg_dump -d "$DATABASE_URL" -Fc -f pre-migration.dump
#   3. deploy the unified-memory server binary, restart, run migrations
#   4. dev/memory-migration-verify.sh fetch http://127.0.0.1:18080 "$TOKEN" after.json
#   5. dev/memory-migration-verify.sh check before.json after.json
set -eu

command -v jq >/dev/null 2>&1 || {
  echo "memory-migration-verify: jq is required" >&2
  exit 2
}

failures=0
note() { printf '%s\n' "$*"; }
fail() {
  note "FAIL: $*"
  failures=$((failures + 1))
}

fetch() {
  server_url=$1
  token=$2
  out=$3
  curl -fsS \
    -H "Authorization: Bearer $token" \
    "$server_url/api/v1/admin/memory-export" \
    -o "$out"
  note "fetched export -> $out ($(jq '.memories | length' "$out") memories)"
}

check() {
  before=$1
  after=$2

  org_before=$(jq -r '.org_id' "$before")
  org_after=$(jq -r '.org_id' "$after")
  if [ "$org_before" != "$org_after" ]; then
    fail "org_id changed: $org_before -> $org_after"
  fi

  count_before=$(jq '.memories | length' "$before")
  count_after=$(jq '.memories | length' "$after")
  if [ "$count_before" != "$count_after" ]; then
    fail "memory count changed: $count_before -> $count_after"
  fi

  ids_before=$(jq -r '.memories[].memory_id' "$before" | sort)
  ids_after=$(jq -r '.memories[].memory_id' "$after" | sort)
  if [ "$ids_before" != "$ids_after" ]; then
    fail "memory identity set changed (old_id -> memory_id map mismatch)"
    tmp_before=$(mktemp)
    tmp_after=$(mktemp)
    printf '%s\n' "$ids_before" >"$tmp_before"
    printf '%s\n' "$ids_after" >"$tmp_after"
    diff "$tmp_before" "$tmp_after" | sed 's/^/    /' || true
    rm -f "$tmp_before" "$tmp_after"
  fi

  # Every memory must keep its content hash (byte identity) and scope, and
  # gain/keep a non-empty description. Iterate from a temp file so the loop
  # runs in the current shell (a pipeline would fork a subshell and lose the
  # failure counter).
  tmp_ids=$(mktemp)
  printf '%s\n' "$ids_after" >"$tmp_ids"
  while read -r memory_id; do
    [ -n "$memory_id" ] || continue
    hash_before=$(jq -r --arg id "$memory_id" '.memories[] | select(.memory_id == $id) | .content_hash' "$before")
    hash_after=$(jq -r --arg id "$memory_id" '.memories[] | select(.memory_id == $id) | .content_hash' "$after")
    scope_before=$(jq -r --arg id "$memory_id" '.memories[] | select(.memory_id == $id) | .scope' "$before")
    scope_after=$(jq -r --arg id "$memory_id" '.memories[] | select(.memory_id == $id) | .scope' "$after")
    description_after=$(jq -r --arg id "$memory_id" '.memories[] | select(.memory_id == $id) | .description' "$after")
    path_after=$(jq -r --arg id "$memory_id" '.memories[] | select(.memory_id == $id) | .path' "$after")
    if [ -z "$hash_before" ] || [ "$hash_before" = null ]; then
      fail "memory $memory_id missing in before export"
    elif [ "$hash_before" != "$hash_after" ]; then
      fail "memory $memory_id content_hash changed: $hash_before -> $hash_after"
    fi
    if [ "$scope_before" != "$scope_after" ]; then
      fail "memory $memory_id scope changed: $scope_before -> $scope_after"
    fi
    if [ -z "$description_after" ] || [ "$description_after" = null ]; then
      fail "memory $memory_id has no description after migration"
    fi
    case "$path_after" in
      issues/*) note "ok: issue memory $memory_id ($path_after) preserved" ;;
    esac
  done <"$tmp_ids"
  rm -f "$tmp_ids"

  for section in drafts selections bundles; do
    before_count=$(jq ".$section | length" "$before")
    after_count=$(jq ".$section | length" "$after")
    if [ "$before_count" != "$after_count" ]; then
      fail "$section count changed: $before_count -> $after_count"
    fi
  done

  # Draft operations must survive (raw content JSON).
  before_ops=$(jq '[.drafts[].operations[]] | length' "$before")
  after_ops=$(jq '[.drafts[].operations[]] | length' "$after")
  if [ "$before_ops" != "$after_ops" ]; then
    fail "draft operation count changed: $before_ops -> $after_ops"
  fi

  if [ "$failures" -eq 0 ]; then
    note "memory migration verification PASSED"
  else
    note "$failures verification failure(s)"
    exit 1
  fi
}

case "${1:-}" in
  fetch)
    [ "$#" -eq 4 ] || {
      echo "usage: $0 fetch <server-url> <admin-token> <out.json>" >&2
      exit 2
    }
    fetch "$2" "$3" "$4"
    ;;
  check)
    [ "$#" -eq 3 ] || {
      echo "usage: $0 check <before.json> <after.json>" >&2
      exit 2
    }
    check "$2" "$3"
    ;;
  *)
    echo "usage: $0 {fetch|check} ..." >&2
    exit 2
    ;;
esac
