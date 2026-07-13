# Deploy for an organization

This guide deploys the Rust Server and PostgreSQL for one self-hosted
organization. Hub is the organization-memory view in Desktop; it is not the
name of the deployed process.

## Prerequisites

- Docker Engine with Docker Compose v2
- a public HTTPS hostname for Server
- an OIDC confidential client registered with the organization's IdP
- the Server callback URL registered with that IdP

The registered redirect URI must be:

```text
https://memory.example.com/login/oauth2/code/oidc
```

## Configure

```bash
cp .env.example .env
```

Set at least these values in `.env`:

```dotenv
CLUMSIES_DB_PASSWORD=replace-with-a-random-password
CLUMSIES_BOOTSTRAP_ORG_NAME=Example
CLUMSIES_BOOTSTRAP_OWNER_EMAIL=owner@example.com
CLUMSIES_BOOTSTRAP_OWNER_NAME=Owner
CLUMSIES_BOOTSTRAP_PROJECT_NAME=Default
CLUMSIES_OIDC_ISSUER=https://identity.example.com
CLUMSIES_OIDC_CLIENT_ID=replace-with-oidc-client-id
CLUMSIES_OIDC_CLIENT_SECRET=replace-with-oidc-client-secret
CLUMSIES_OIDC_CALLBACK_URL=https://memory.example.com/login/oauth2/code/oidc
CLUMSIES_CLIENT_REDIRECT_URIS=http://127.0.0.1/callback
```

`CLUMSIES_CLIENT_REDIRECT_URIS` is the allowlist for clumsies clients after the
provider callback. The loopback template above accepts Desktop's dynamic port;
it does not allow arbitrary remote redirects.

`CLUMSIES_CORS_ORIGINS` is only for Web Admin/browser origins. Desktop requests
are native and travel through daemon, so Tauri origins do not belong in this
list.

## Start

```bash
docker compose up --build -d
```

Server runs database migrations before listening and bootstraps the first
organization, owner, project, and organization/project Refs when the database
is empty.

Put a TLS reverse proxy or ingress in front of port `8080`. Do not expose the
default PostgreSQL port publicly.

## Verify

```bash
curl --fail --silent https://memory.example.com/api/v1/admin/health
docker compose ps
```

A usable deployment reports `ok` for database, schema, commit service, and
OIDC. If OIDC is `down`, the Server can answer diagnostics but users cannot log
in.

Open Desktop, enter the public Server URL, and continue with organization SSO.
On first login, the verified OIDC email must match the bootstrap owner or a
member record created through Web Admin. Later logins use the bound
`(issuer, subject)` identity.

## Operations

Database state lives in the `clumsies-postgres` volume. Back up PostgreSQL with
standard PostgreSQL tooling before upgrades. Server Commit, Tree, Blob, Ref,
draft, review, identity, and audit data are all part of the same transactional
database and must be backed up together.

To inspect logs and stop the stack:

```bash
docker compose logs server
docker compose down
```

Do not use `down -v` for an installed organization; it deletes the database
volume.
