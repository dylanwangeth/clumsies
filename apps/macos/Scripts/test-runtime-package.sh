#!/bin/sh
set -eu

repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
derived_data="${CLUMSIES_MACOS_PACKAGE_TEST_DERIVED_DATA:-/private/tmp/clumsies-macos-package-test}"
app="$derived_data/Build/Products/Release/Clumsies.app"
runtime="$app/Contents/Resources/clumsiesd"

cd "$repo_root"
CLUMSIES_MACOS_DERIVED_DATA="$derived_data" sh apps/macos/Scripts/build.sh

test -d "$app"
test -x "$runtime"
test ! -e "$app/Contents/Resources/clumsies"

# The local Release build deliberately disables an outer signing identity and
# leaves Swift-package frameworks unsigned. Ad-hoc seal the complete test copy,
# then verify the same nested/deep boundary used by release packaging. The
# runtime identifier check below ensures this does not obscure its contract.
codesign --force --deep --sign - "$app"
codesign --verify --strict "$runtime"
codesign --verify --deep --strict "$app"

runtime_identifier="$(codesign -dvv "$runtime" 2>&1 | sed -n 's/^Identifier=//p')"
test "$runtime_identifier" = "ai.clumsies.daemon"
