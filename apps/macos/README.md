# Clumsies for macOS

This is the native macOS client. It uses AppKit and SwiftUI for the interface and communicates with the independent Rust daemon through the existing Mach XPC service.

The Tauri client in `apps/desktop` remains available while the native client reaches feature parity, but it is only a daemon client. The native macOS client owns LaunchAgent installation and daemon upgrades.

## Run

```sh
bun run dev:macos
```

The build embeds `clumsiesd` in the app bundle. Set `CLUMSIES_SKIP_DAEMON_BUILD=1` only when iterating on UI code with an already installed daemon.
Debug builds use Xcode's local ad-hoc signature so the test host can load Swift debug libraries under macOS system policy. The embedded daemon receives an explicit, stable designated requirement so rebuilding it does not invalidate its file-keychain access control entry.

## Test

```sh
bun run test:macos
bun run test:macos:live
```

The live suite loads the authenticated workspace through the installed daemon and the configured Server. The regular suite has no Server dependency.

## Build

```sh
bun run build:macos
```

The local build is unsigned, targets the current Mac's architecture, and is written to `/private/tmp/clumsies-macos-build`. Distribution signing and notarization are separate release operations.

Tagged releases build a universal Developer ID-signed app, notarize it, and publish a Sparkle-signed update archive and `appcast.xml` through GitHub Actions. The Sparkle private key is stored as the `SPARKLE_PRIVATE_KEY` repository secret; only its public key is committed in `project.yml`.

## Generate the Xcode project

```sh
xcodegen generate --spec apps/macos/project.yml
```
