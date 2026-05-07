# Auth and session reference

This page defines the current authentication contract for clumsies clients,
Hub sessions, and local credential storage.

## Product contract

`clumsies` is the primary interactive entry point. If a user launches the TUI
without usable credentials, the client must present an in-product login flow
rather than requiring the user to exit and run a separate command first.

`clumsies login` remains available as a CLI wrapper around the same auth
capability. It is a management and scripting entry point, not the only way to
authenticate.

Automation should use environment-provided credentials or a non-interactive
token source. Automation must not enter an interactive TUI login flow.

## Session lifecycle

Hub issues two token classes:

| Token | Default lifetime | Purpose |
| --- | ---: | --- |
| access token | 1 hour | Short-lived bearer token for API requests |
| refresh token | 90 days | Long-lived device session used to rotate tokens |

The access lifetime is controlled by `HUB_TOKEN_TTL`. The refresh lifetime is
controlled independently by `HUB_REFRESH_TOKEN_TTL`. Refresh token lifetime
must not be derived from access token lifetime.

When a client receives `401 Unauthorized` for an authenticated request, it may
try exactly one refresh attempt. A successful refresh returns a new access
token and a new refresh token. The presented refresh token is revoked
server-side.

Clients must persist the rotated token pair when possible. Persistence failure
does not invalidate the in-memory session for the current process, but the next
process may have to refresh or log in again.

## Local credential storage

Local credentials contain:

| Field | Meaning |
| --- | --- |
| `hub_url` | Hub base URL |
| `username` | Hub username associated with the token pair |
| `access_token` | Current access token |
| `refresh_token` | Current refresh token |

The credential store is selected by `CLUMSIES_AUTH_STORE`:

| Value | Behavior |
| --- | --- |
| `file` | Store credentials in `~/.clumsies/auth.json` |
| `keychain` | Store credentials in macOS Keychain; unsupported platforms fail |
| `auto` | Try Keychain when available, otherwise use `auth.json` |
| `memory` | Do not persist credentials; used for ephemeral sessions |

The default is `file`. This avoids frequent macOS Keychain prompts during local
development and TUI startup. Deployments that require OS-native secret storage
should set `CLUMSIES_AUTH_STORE=keychain` or `auto`.

The file store must create `~/.clumsies/auth.json` with mode `0600` where the
platform supports POSIX file modes.

## TUI behavior

On startup, the TUI loads local credentials. If an access token is expired but
the refresh token is valid, the TUI should refresh silently and continue into
the main workspace.

If no credentials exist, or both access and refresh tokens are unusable, the TUI
must enter a login state. The login state should eventually prefer a
browser/device flow, with username/password and invite activation as local or
self-hosted fallbacks.

Network reachability and authentication are separate states. A successful
unauthenticated health check must not clear an authentication failure.

## CLI behavior

`clumsies login` prompts for Hub URL, username, and password today. If the
server rejects the login for an invited user, it may prompt for the invitation
token and activate the account.

Future browser/device login should reuse the same credential storage and token
rotation behavior. The command name can stay, but the underlying flow must be
shared with the TUI.

## Security notes

Refresh token rotation reduces the value of a captured old refresh token. Hub
should keep explicit revoke support and should treat refresh token reuse as a
security signal when token families are added.

Longer refresh lifetimes improve daily UX but increase device-session risk.
Administrators can lower `HUB_REFRESH_TOKEN_TTL` for stricter environments.
