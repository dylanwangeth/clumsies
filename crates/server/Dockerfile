# syntax=docker/dockerfile:1

FROM oven/bun:1.3.5 AS web-builder

WORKDIR /workspace
COPY package.json bun.lock ./
COPY apps/web-admin ./apps/web-admin
COPY packages/api-client ./packages/api-client
COPY packages/api-contract ./packages/api-contract
RUN bun install --frozen-lockfile \
    --network-concurrency=1 \
    --registry=https://registry.npmjs.org
RUN bun run --cwd apps/web-admin build

FROM rust:1.92-slim-bookworm AS builder

WORKDIR /workspace
COPY Cargo.toml Cargo.lock ./
COPY crates/server ./crates/server
COPY crates/daemon ./crates/daemon
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/workspace/target \
    cargo build --locked --release -p server --bin clumsies-server \
    && cp /workspace/target/release/clumsies-server /tmp/clumsies-server

FROM debian:bookworm-slim AS runtime

RUN apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 clumsies

COPY --from=builder /tmp/clumsies-server /usr/local/bin/clumsies-server
COPY --from=web-builder /workspace/apps/web-admin/dist /opt/clumsies/web-admin

ENV CLUMSIES_WEB_ADMIN_DIR=/opt/clumsies/web-admin

USER clumsies
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/clumsies-server"]
