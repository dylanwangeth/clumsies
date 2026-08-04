#!/bin/sh
set -eu

if [ "${CLUMSIES_SKIP_DAEMON_BUILD:-0}" = "1" ]; then
  exit 0
fi

repo_root="$(cd "$SRCROOT/../.." && pwd)"
destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/clumsies"
client_identifier="ai.clumsies.cli"
mkdir -p "$(dirname "$destination")"
cd "$repo_root"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy

if [ "$CONFIGURATION" = "Release" ] && [ "${CLUMSIES_UNIVERSAL_BUILD:-0}" = "1" ]; then
  scratch="$TARGET_TEMP_DIR/clumsies-client-universal"
  rm -rf "$scratch"
  mkdir -p "$scratch/arm64" "$scratch/x86_64"
  zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSafe --prefix "$scratch/arm64"
  zig build -Dtarget=x86_64-macos -Doptimize=ReleaseSafe --prefix "$scratch/x86_64"
  lipo -create \
    "$scratch/arm64/bin/clumsies" \
    "$scratch/x86_64/bin/clumsies" \
    -output "$destination"
elif [ "$CONFIGURATION" = "Release" ]; then
  zig build -Doptimize=ReleaseSafe
  cp "$repo_root/zig-out/bin/clumsies" "$destination"
else
  zig build
  cp "$repo_root/zig-out/bin/clumsies" "$destination"
fi

chmod 755 "$destination"

if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && [ "$EXPANDED_CODE_SIGN_IDENTITY" != "-" ]; then
  codesign \
    --force \
    --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
    --identifier "$client_identifier" \
    --options runtime \
    "$destination"
else
  codesign \
    --force \
    --sign - \
    --identifier "$client_identifier" \
    "$destination"
fi
