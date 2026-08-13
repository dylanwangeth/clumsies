#!/bin/sh

set -eu

result_root=$(mktemp -d "${TMPDIR:-/private/tmp}/clumsies-macos-test-results.XXXXXX")
result_bundle="$result_root/Clumsies.xcresult"

trap 'rm -rf -- "$result_root"' EXIT

xcodegen generate --spec apps/macos/project.yml

set +e
CLUMSIES_SKIP_DAEMON_BUILD=1 xcodebuild -quiet \
    -project apps/macos/Clumsies.xcodeproj \
    -scheme Clumsies \
    -configuration Debug \
    -derivedDataPath /private/tmp/clumsies-macos-tests \
    -resultBundlePath "$result_bundle" \
    test
status=$?
set -e

if [ "$status" -ne 0 ]; then
    xcrun xcresulttool get test-results summary --path "$result_bundle" || true
fi

exit "$status"
