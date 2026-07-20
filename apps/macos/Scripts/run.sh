#!/bin/sh
set -eu

repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
derived_data="/private/tmp/clumsies-macos-derived"

cd "$repo_root"
xcodegen generate --spec apps/macos/project.yml
xcodebuild \
  -quiet \
  -project apps/macos/Clumsies.xcodeproj \
  -scheme Clumsies \
  -configuration Debug \
  -derivedDataPath "$derived_data" \
  build
open "$derived_data/Build/Products/Debug/Clumsies.app"
