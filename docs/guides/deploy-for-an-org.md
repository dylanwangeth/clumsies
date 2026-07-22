# Deploy for an organization

This guide deploys one self-hosted Clumsies organization. The Rust Server image
contains Web Admin; Hub remains the organization-memory view in Desktop and is
not a deployed process.

## Runtime boundary

Production runs three containers:

- PostgreSQL stores every authority, draft, review, identity, audit, Blob,
  Tree, Commit, and Ref;
- Server runs migrations, the Public/Admin APIs, OIDC, and Web Admin;
- Caddy terminates public HTTPS and proxies Server.

Only Caddy publishes host ports. Server and PostgreSQL stay on the Compose
network.

## Prerequisites

- Docker Engine and Docker Compose v2;
- a public HTTPS hostname;
- an OIDC confidential client with the callback below registered at the IdP;
- a published Clumsies Server image pinned by digest.

```text
https://memory.example.com/login/oauth2/code/oidc
```

Production must not use the legacy Python `docker-compose` command. The release
script rejects every Compose major version except 2.

## Configure

Copy `.env.example` to `.env`, restrict it to the installation administrator,
and replace every placeholder. In particular:

```dotenv
CLUMSIES_SERVER_IMAGE=ghcr.io/lilhammerfun/clumsies-server@sha256:published-digest
CLUMSIES_PUBLIC_ORIGIN=https://memory.example.com
CLUMSIES_DB_PASSWORD=replace-with-a-random-password
CLUMSIES_SETUP_CODE=replace-with-at-least-32-random-characters
CLUMSIES_OIDC_ISSUER=https://identity.example.com
CLUMSIES_OIDC_CLIENT_ID=replace-with-oidc-client-id
CLUMSIES_OIDC_CLIENT_SECRET=replace-with-oidc-client-secret
CLUMSIES_CLIENT_REDIRECT_URIS=http://127.0.0.1/callback
```

`CLUMSIES_CLIENT_REDIRECT_URIS` is the post-provider allowlist for Clumsies
clients. The loopback template accepts Desktop's dynamic port only at the exact
callback path. Server derives both the IdP callback and same-origin Web Admin
setup callback from `CLUMSIES_PUBLIC_ORIGIN`. `CLUMSIES_CORS_ORIGINS` is only
for additional browser origins; same-origin Web Admin and native Desktop
traffic do not require it.

When the host requires an outbound proxy, configure Docker Engine and the
standard proxy variables in `.env`. Deployment-specific proxy or mirror
addresses are not embedded in the image.

## Start and initialize

```bash
docker compose --project-name clumsies -f compose.production.yml up -d --wait
curl --fail --silent https://memory.example.com/api/v1/admin/health
```

Open `https://memory.example.com/admin/setup`. Web Setup consumes the one-time
Setup Code, creates the organization, first Owner, default Project, external
identity, and initial Refs in one transaction, then permanently locks the
installation. Remove `CLUMSIES_SETUP_CODE` from the active `.env` after Setup.

Later organization configuration and membership are managed at `/admin/` with
the configured enterprise identity provider.

## GitHub delivery

`.github/workflows/server-delivery.yml` runs only after the `CI` workflow has
succeeded on `main`. It builds `linux/amd64` and `linux/arm64`, publishes the
image to GHCR with OCI source/revision labels, records provenance, and deploys
the exact manifest digest. A manual dispatch accepts only an existing immutable
digest and its full commit, so it serves as retry and rollback rather than an
untested source build.

The GHCR package is linked to this repository through its OCI source label.
Make the package public once so self-hosted installations can pull it without a
personal token. GitHub documents both [anonymous pulls for public container
packages](https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility)
and the recommended [`GITHUB_TOKEN` publishing
flow](https://docs.github.com/en/actions/tutorials/publish-packages/publish-docker-images).

Create a GitHub Environment named `production` with these secrets:

| Secret | Value |
|---|---|
| `DEPLOY_HOST` | SSH hostname or IP of the installation |
| `DEPLOY_USER` | `clumsies-deploy` |
| `DEPLOY_SSH_KEY` | Dedicated Ed25519 private key used only by Actions |
| `DEPLOY_KNOWN_HOSTS` | Pinned SSH host-key line for `DEPLOY_HOST` |

Set repository variable `SERVER_AUTO_DEPLOY_ENABLED=false` during bootstrap.
After the image package is public and the restricted deploy identity has been
tested, set it to `true`. Future green `main` commits then deploy automatically.

Do not upload a personal or root SSH key. Generate a dedicated key, copy the
public half to the host, install Compose v2, then run the installer from a
trusted release checkout:

```bash
sudo apt-get install --yes docker-compose-v2
sudo deploy/server/install.sh /path/to/github-deploy-key.pub
```

The installer creates `clumsies-deploy`. Its `authorized_keys` entry disables
PTY, forwarding, and user rc files and forces `clumsies-github-command`. The
command accepts only:

```text
deploy ghcr.io/lilhammerfun/clumsies-server@sha256:<64 hex> <40 hex commit>
```

The account can invoke only the validated release command through `sudo`; it
cannot obtain an interactive deployment shell.

## Release transaction

`clumsies-server-release deploy` performs the following operation under an
exclusive host lock:

1. validate Compose v2, the digest, commit, current configuration, and public origin;
2. pull the immutable image and render the Compose configuration;
3. create and validate an online PostgreSQL backup;
4. restore that backup into isolated PostgreSQL, start the target image against
   it, run its real SQLx migrations, and require Server health;
5. stop the current Server so no writes can occur during the cutover;
6. create a second, write-free PostgreSQL backup and verify it with `pg_restore`;
7. atomically persist the desired image digest, start only Server, and require
   both container and public HTTPS health;
8. record the commit, target and previous images, both backups, timestamp, and result.

If target container or public health fails after cutover, the script stops the
target Server, replaces the production database from the write-free backup,
then starts and verifies the previous image. Database and application rollback
are one operation. Released migrations therefore do not need to remain readable
by the previous Server image; destructive migrations still need migration tests,
but they do not require a compatibility implementation.

To retry a delivery, dispatch `Server Delivery` with its published digest and
original commit. Do not treat an older image as a standalone rollback after a
destructive migration: restoring such a release requires its recorded
pre-deploy database backup and previous image as one recovery operation.
Production never rebuilds source code.

Changing the canonical origin is a separate configuration transaction:

```bash
sudo clumsies-server-release reconfigure \
  https://memory.example.com \
  http://127.0.0.1/callback
```

The command backs up PostgreSQL and the active environment file, validates the
rendered Compose configuration, recreates Server and Caddy, waits for container
and public HTTPS health, and restores the previous environment and services if
the new origin fails.

## Backup and restore

The installer enables:

- `clumsies-backup.timer`: daily custom-format backup, verification, checksum,
  and 14-day local scheduled-backup retention;
- `clumsies-restore-drill.timer`: weekly restore into an isolated PostgreSQL and
  Server stack, followed by the real Server health check and automatic cleanup.

Run either operation explicitly:

```bash
sudo clumsies-server-release backup manual
sudo clumsies-server-release restore-drill
```

Backups and deployment records live under `/opt/clumsies/backups` and
`/opt/clumsies/releases`. Local retention is not disaster recovery. Configure
encrypted off-host storage appropriate to the installing organization and test
restoration from that copy; do not place database dumps in the source
repository or ordinary GitHub Actions artifacts.

## Operations

```bash
sudo clumsies-server-release preflight
docker compose --project-name clumsies -f compose.production.yml ps
docker compose --project-name clumsies -f compose.production.yml logs server
systemctl list-timers 'clumsies-*'
```

Do not use `docker compose down --volumes` for an installed organization. It
deletes the PostgreSQL volume.
