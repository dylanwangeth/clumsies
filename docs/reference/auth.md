# Authentication and sessions

## Login flow

Clumsies uses the organization's OpenID Connect provider. Desktop starts the
flow in the system browser and listens on an ephemeral `127.0.0.1` port for the
final authorization code.
Client and provider exchanges both use PKCE with `S256`; state and OIDC nonce
are validated before a session is issued.

```text
Desktop native
  -> Server /oauth2/authorization/oidc
  -> organization OIDC provider
  -> Server /login/oauth2/code/oidc
  -> Desktop loopback callback
  -> Server /api/v1/auth/token
  -> daemon credential store
```

The WebView renderer never receives the access token or refresh token. All
authenticated product requests are sent through daemon, which injects the
bearer token outside renderer JavaScript.

## Provider verification

Server discovers provider metadata and JWKS from the configured issuer and
requires the discovery document to return that exact issuer. Authorization
code exchange failures use `oidc_code_exchange_failed`; issuer, audience,
nonce, expiry, and signature failures use `oidc_id_token_invalid`.

When an ID Token references an unknown signing key, Server refreshes discovery
and JWKS once, then verifies the already received token again. It does not
redeem the one-time provider authorization code a second time. A signature
failure against a matching key is rejected without a refresh retry.

## Member admission

An organization owner or admin creates a member admission record through the
admin API. On first successful OIDC login, Server matches the verified email
and binds the stable `(issuer, subject)` identity to that record. Later logins
resolve the external identity directly, so an email claim change cannot move
the identity to another user. Unknown, disabled, unverified, or
disallowed-domain identities are rejected.

The bootstrap owner environment variables create the first organization owner
for a new self-hosted database. They do not create a password login path.

## Token lifecycle

Server issues opaque access and refresh tokens. Only hashes are stored in
PostgreSQL. Refresh is rotating: the presented refresh token is revoked and a
new access/refresh pair is returned.

Daemon handles a `401 Unauthorized` by attempting one refresh and one request
retry. It does not expose secrets through health, project config, IPC response,
or renderer state.

Sign-out calls `DELETE /api/v1/auth/session`, revokes the active session, and
clears local credentials.

## Required Server configuration

| Variable | Meaning |
| --- | --- |
| `CLUMSIES_PUBLIC_ORIGIN` | canonical HTTPS Server origin; loopback HTTP is allowed for local development |
| `CLUMSIES_OIDC_ISSUER` | exact organization OIDC issuer |
| `CLUMSIES_OIDC_CLIENT_ID` | OIDC confidential client ID |
| `CLUMSIES_OIDC_CLIENT_SECRET` | OIDC confidential client secret |
| `CLUMSIES_CLIENT_REDIRECT_URIS` | comma-separated additional trusted client callbacks |

Server derives the provider callback at `/login/oauth2/code/oidc` and the
same-origin Web Admin setup callback from `CLUMSIES_PUBLIC_ORIGIN`. This keeps
TLS, OIDC, and Admin on one authority and prevents independently configured
hostnames from drifting apart.

For Desktop dynamic loopback ports, configure
`CLUMSIES_CLIENT_REDIRECT_URIS=http://127.0.0.1/callback`. The missing port is a
deliberate template: Server accepts any ephemeral port only for that exact
loopback host, scheme, path, and query.

Remote Server URLs used by Desktop must be HTTPS. Plain HTTP is accepted only
for loopback development addresses.

## Local credential storage

Daemon stores one generic-password item in macOS Keychain. The service is
`io.github.lilhammerfun.clumsies`, the account is `server-session`, and the
encrypted value contains the Server URL plus the access/refresh token pair. The
Server URL binds the credentials to one endpoint; daemon refuses to load a
Keychain session when it does not match the configured Server.

SQLite stores only non-secret Server and project configuration. Login and token
refresh replace the Keychain value as one record, while clearing the daemon
session or an invalid refresh session deletes it. There is no SQLite or
plaintext-file credential fallback. Tests inject an isolated credential store;
a separately gated smoke test exercises the real macOS Keychain.
