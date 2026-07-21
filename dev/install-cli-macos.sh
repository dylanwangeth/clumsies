#!/bin/sh
set -eu

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
install_root="${CLUMSIES_INSTALL_ROOT:-$HOME/.clumsies}"
install_dir="$install_root/bin"
destination="$install_dir/clumsies"
staging="$install_dir/.clumsies.install.$$"

cleanup() {
  rm -f "$staging"
}

trap cleanup 0 1 2 15

if [ "$(uname -s)" != "Darwin" ]; then
  echo "install-cli-macos.sh requires macOS." >&2
  exit 1
fi

cd "$repo_root"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy
zig build -Doptimize=ReleaseSafe

mkdir -p "$install_dir"
cp "$repo_root/zig-out/bin/clumsies" "$staging"
chmod 755 "$staging"

# A stable ad-hoc signature refreshes macOS's vnode code-signing state. The
# final rename keeps running MCP processes on the old inode while new hosts
# start the replacement binary.
codesign --force --sign - --identifier ai.clumsies.cli "$staging"
codesign --verify --strict "$staging"
mv -f "$staging" "$destination"

trap - 0 1 2 15
"$destination" --version
