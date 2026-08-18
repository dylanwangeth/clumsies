#!/usr/bin/env bash
set -Eeuo pipefail

# Retired terminology gate (ISSUE-063).
#
# The unified Memory model has exactly two scopes: org (Organization) and
# project (Project). "Hub" and "Local" are retired concepts and must not
# appear as Memory scope labels in user-visible strings of the macOS app.
# The allowlist below covers legitimate non-Memory uses:
#   - Local Runtime      : installation-level runtime setting
#   - Local edits...     : device-local (offline) edits, not Memory scope
# Add to this list only for genuinely unrelated uses; Memory scope labels
# must use Organization / Project.

root="$(cd "$(dirname "$0")/.." && pwd)"
status=0

matches="$(grep -rnE '"[^"]*\b(Hub|Local)\b[^"]*"' \
  "$root/apps/macos/Sources" --include='*.swift' \
  | grep -vE 'Local (Runtime|edits remain saved)' || true)"

if [[ -n "$matches" ]]; then
  printf 'Retired Hub/Local terminology found in user-visible strings:\n%s\n' \
    "$matches" >&2
  status=1
fi

exit "$status"
