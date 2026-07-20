#!/bin/sh
set -eu

repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
derived_data="${CLUMSIES_MACOS_DERIVED_DATA:-/private/tmp/clumsies-macos-build}"
host_arch="$(uname -m)"

case "$host_arch" in
  arm64|x86_64) ;;
  *)
    echo "Unsupported macOS architecture: $host_arch" >&2
    exit 1
    ;;
esac

cd "$repo_root"
xcodegen generate --spec apps/macos/project.yml
xcodebuild \
  -project apps/macos/Clumsies.xcodeproj \
  -scheme Clumsies \
  -configuration Release \
  -destination "platform=macOS,arch=$host_arch" \
  -derivedDataPath "$derived_data" \
  ARCHS="$host_arch" \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  build

printf '%s\n' "$derived_data/Build/Products/Release/Clumsies.app"
