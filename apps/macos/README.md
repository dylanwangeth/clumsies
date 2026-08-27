# Clumsies for macOS

This is the Clumsies desktop client. It uses AppKit and SwiftUI for the interface and communicates with the independent Rust daemon through its Mach XPC service. The app initiates daemon installation and upgrades; the embedded daemon owns the canonical LaunchAgent definition and reconciliation logic.

## Run

```sh
just dev-macos
```

The command starts a complete Dev Instance owned by the current worktree: a
uniquely named App and daemon, private data and Keychain identity, local Server,
PostgreSQL, fake OIDC, and isolated `CODEX_HOME`. It does not replace the
resident Debug App or global Codex Plugin. Fresh local Server data is initialized
through the normal Setup API and fake OIDC before the App opens; product login is
not bypassed.

```sh
just dev-macos-status
just dev-macos-logs
just dev-macos-down   # preserve instance data
just dev-macos-reset  # delete instance data and credentials
just dev-macos-preview path/to/preview.json
```

To deliberately replace the resident Debug App and daemon, run the promotion
entry point. The App then reconciles the global Codex Plugin; restart Codex and
create a new task before testing the promoted build.

```sh
just promote-debug-macos
```

The build embeds `clumsiesd` in the app bundle. Set `CLUMSIES_SKIP_DAEMON_BUILD=1` only when iterating on UI code with an already installed daemon.
Debug builds use Xcode's local ad-hoc signature so the test host can load Swift debug libraries under macOS system policy. The embedded daemon receives an explicit, stable designated requirement so rebuilding it does not invalidate its file-keychain access control entry.

## Test

```sh
just test-macos
just test-macos-live
```

The live suite requires a running, authenticated `just dev-macos` instance and
uses only that instance's daemon and Server. The regular suite has no Server
dependency.

## Build

```sh
just build-macos
```

The local build is unsigned, targets the current Mac's architecture, and is written to `/private/tmp/clumsies-macos-build`. Distribution signing and notarization are separate release operations.

Tagged releases build a universal Developer ID-signed app, notarize and staple it,
verify the App and bundled Agent runtime share the expected signing team and
hardened-runtime identity, then publish a Sparkle-signed update archive and
`appcast.xml` through GitHub Actions. The same workflow can be dispatched manually
from the current default-branch tip to produce a signed candidate. Manual candidates
do not publish a GitHub Release or appcast.

Keep the Apple certificate, certificate passphrase, notarization account,
app-specific password, team ID, temporary keychain password, and Sparkle private key
in the protected `macos-signing` GitHub environment, using the secret names referenced
by `release.yml`. Restrict that environment to the default branch and release tags and
require a reviewer before its secrets are exposed. The Sparkle private key is
required only for a tagged release; only its public key is committed in
`project.yml`. The Debug App installed by `just promote-debug-macos` uses the
supported ad-hoc development path and can exercise managed Coding Agent
integrations. A Debug ad-hoc runtime is accepted at the installation boundary;
Release packages must carry an accepted team identity and the hardened-runtime
flag.

## Generate the Xcode project

```sh
xcodegen generate --spec apps/macos/project.yml
```
