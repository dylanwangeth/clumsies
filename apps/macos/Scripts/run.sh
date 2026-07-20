#!/bin/sh
set -eu

repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
derived_data="${CLUMSIES_MACOS_DERIVED_DATA:-/private/tmp/clumsies-macos-derived}"
install_dir="${CLUMSIES_MACOS_INSTALL_DIR:-$HOME/Applications}"
built_app="$derived_data/Build/Products/Debug/Clumsies.app"
installed_app="$install_dir/Clumsies.app"
staging_app="$install_dir/.Clumsies.$$.app"
previous_app="$install_dir/.Clumsies.previous.$$.app"

cleanup() {
  rm -rf "$staging_app" "$previous_app"
}

trap cleanup 0 1 2 15

cd "$repo_root"
xcodegen generate --spec apps/macos/project.yml
xcodebuild \
  -quiet \
  -project apps/macos/Clumsies.xcodeproj \
  -scheme Clumsies \
  -configuration Debug \
  -derivedDataPath "$derived_data" \
  build

test -d "$built_app"
mkdir -p "$install_dir"
ditto "$built_app" "$staging_app"

if pgrep -x Clumsies >/dev/null 2>&1; then
  osascript -e 'tell application id "ai.clumsies.desktop" to quit'

  attempts=0
  while pgrep -x Clumsies >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 100 ]; then
      echo "Clumsies did not quit within 10 seconds." >&2
      exit 1
    fi
    sleep 0.1
  done
fi

if [ -e "$installed_app" ]; then
  mv "$installed_app" "$previous_app"
fi

if ! mv "$staging_app" "$installed_app"; then
  if [ -e "$previous_app" ]; then
    mv "$previous_app" "$installed_app"
  fi
  exit 1
fi

rm -rf "$previous_app"
trap - 0 1 2 15
open -n "$installed_app"
