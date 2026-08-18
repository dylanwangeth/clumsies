#!/bin/sh
set -eu

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

for retired_entry in build.zig build.zig.zon src install.sh dev/install-cli-macos.sh; do
  if [ -e "$retired_entry" ]; then
    echo "Archived Zig entry returned to the active repository: $retired_entry" >&2
    exit 1
  fi
done

test -f archive/zig-cli/README.md
test -f archive/zig-cli/build.zig
test -f archive/zig-cli/install.sh
test -d archive/zig-cli/src/client

for archived_asset in \
  assets/adapters/codex/runtime/config.toml.tpl \
  assets/adapters/codex/runtime/hooks.json.tpl \
  assets/adapters/codex/runtime/hooks/resolve-binary.sh.tpl \
  assets/adapters/codex/runtime/hooks/issue-run-event.sh.tpl \
  assets/adapters/claude-code/runtime/settings.json.tpl \
  assets/adapters/claude-code/runtime/mcp.json.tpl \
  assets/adapters/claude-code/runtime/hooks/resolve-binary.sh.tpl \
  assets/adapters/claude-code/runtime/hooks/session-start.sh.tpl \
  assets/adapters/claude-code/runtime/hooks/issue-run-event.sh.tpl
do
  test -f "archive/zig-cli/$archived_asset"
done

if rg -n \
  'zig build|zig-out/bin/clumsies|Application Support/ai\.clumsies/bin/clumsies|~/.clumsies/bin/clumsies|clumsies-darwin|install:cli:macos' \
  .github/workflows \
  apps/macos/Scripts \
  apps/macos/project.yml \
  assets/adapters \
  package.json
then
  echo "An active build, package, or Adapter surface still references the retired Zig CLI." >&2
  exit 1
fi
