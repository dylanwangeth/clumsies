# Deployment

This page is for the person bringing up the Hub and database for a team. It is not the day-to-day member workflow.

The current repo supports a clear local bring-up flow. It does not yet document a full production deployment story such as TLS termination, secret rotation, reverse proxy layout, or multi-node operations. This page stays honest about that boundary.

## Prerequisites

Before you start, decide which problem you are solving.

If you are bringing up clumsies for local development, this page is ready to use.

If you are planning a production-style deployment for an organization, treat this page as the bootstrap baseline, not as the complete operations manual.

For the current local bring-up path, you need:

| Requirement | Notes |
| --- | --- |
| `curl` or `wget` | required by the release installer |
| [Zig 0.16+](https://ziglang.org/download/) | only required when building from source |
| [PostgreSQL](https://www.postgresql.org/docs/current/) 16 or [Docker Compose](https://docs.docker.com/compose/) | the repo ships a local Postgres compose file |
| free local ports `5432` and `8400` | defaults for Postgres and Hub |
| a shell environment where you can export variables | used for Hub and bootstrap configuration |

## What this guide actually covers

The minimum stack described here is:

1. PostgreSQL
2. `clumsies hub`
3. one bootstrap org and one bootstrap maintainer

After that, you can verify login, then hand off to the member workflow.

## Step 1: install clumsies

Install the latest release:

```bash
curl -fsSL https://raw.githubusercontent.com/lilhammerfun/clumsies/main/install.sh | sh
```

The same `clumsies` binary contains the member CLI, TUI, MCP server, adapter
installer, and Hub server command.

If you are developing clumsies itself, build from source instead:

```bash
git clone https://github.com/lilhammerfun/clumsies.git
cd clumsies
zig build -Doptimize=ReleaseFast
export PATH="$PWD/zig-out/bin:$PATH"
```

## Step 2: start PostgreSQL for local bring-up

The repo already carries a local compose file:

```bash
docker compose up -d
```

The current compose file maps these environment variables:

| Variable | Default |
| --- | --- |
| `HUB_DB_NAME` | `clumsies` |
| `HUB_DB_USER` | `clumsies` |
| `HUB_DB_PASSWORD` | `clumsies` |
| `HUB_DB_PORT` | `5432` |

This is a local development default. It is not a production database deployment guide.

## Step 3: configure the Hub and bootstrap identity

The Hub reads its runtime config from environment variables and from `.env` in
the current directory. Shell environment variables win over `.env` values.
Start from the checked-in example:

```bash
cp .env.example .env
```

| Variable | Default |
| --- | --- |
| `HUB_PORT` | `8400` |
| `HUB_DB_HOST` | `127.0.0.1` |
| `HUB_DB_PORT` | `5432` |
| `HUB_DB_NAME` | `clumsies` |
| `HUB_DB_USER` | `clumsies` |
| `HUB_DB_PASSWORD` | `clumsies` |
| `HUB_TOKEN_TTL` | `3600` |
| `HUB_REFRESH_TOKEN_TTL` | `7776000` |
| `CLUMSIES_LOG_LEVEL` | `info` |
| `CLUMSIES_LOG_ROTATE` | `1` |
| `CLUMSIES_LOG_MAX_BYTES` | `10485760` |
| `CLUMSIES_LOG_BACKUPS` | `10` |

Hub writes application logs and access logs to the configured log sink.
Application logs keep the `[INFO]`, `[WARN]`, and `[ERROR]` prefix. Access
logs use a request-oriented format with status, latency, client, method, and
path. `CLUMSIES_LOG_LEVEL` filters both layers; access logs map 2xx/3xx to
info, 4xx to warn, and 5xx to error.

Client file logging keeps `client.log` as the active file and archives old logs
as dated files such as `client-2026-05-12.log`. The client also reads `.env`
for `CLUMSIES_LOG_*` values, so local log behavior can be configured in the
same file.

Bootstrap user and org settings:

| Variable | Default |
| --- | --- |
| `HUB_BOOTSTRAP_USERNAME` | `admin` |
| `HUB_BOOTSTRAP_PASSWORD` | `admin` |
| `HUB_BOOTSTRAP_ORG` | `default` |

Those bootstrap values are only used when the users table is still empty.

Two facts matter here:

- the bootstrap account is created as a `maintainer`, not a `member`
- the defaults `admin/admin/default` are only appropriate for local development

If you want explicit values instead of defaults, set them before starting the Hub:

```bash
export HUB_BOOTSTRAP_USERNAME=admin
export HUB_BOOTSTRAP_PASSWORD=change-me
export HUB_BOOTSTRAP_ORG=my-org
```

## Step 4: start the Hub

Run:

```bash
clumsies hub
```

On first start, the Hub runs migrations and bootstraps the first org and first maintainer if the database is empty.

## Step 5: verify with the bootstrap maintainer

From another terminal or from the TUI login state:

```bash
clumsies login --hub-url http://127.0.0.1:8400 --username admin
```

If that succeeds, the stack is up enough for the first maintainer to continue bootstrap work.

## What this page does not finish yet

Starting the Hub is not the whole org setup story.

An organization-level rollout still needs at least two more documented flows:

1. maintainer-driven member onboarding
2. workspace creation and workspace membership assignment

The current implementation clearly supports a maintainer role and separate workspace admin and member roles. This page should not pretend the deployment is complete before those flows are documented.

## What happens next

If you are the person verifying the stack locally, the next practical guide is [Member workflow](/guides/how-to-use-clumsies).

That is where normal workspace usage starts: `login`, `init`, `sync`, adapters, and TUI.

If we want this page to become a full org deployment guide, the next missing section is not more architecture. It is maintainer onboarding flow and member provisioning.
