FROM rust:1.92-bookworm AS builder

WORKDIR /workspace
COPY Cargo.toml Cargo.lock ./
COPY crates/server ./crates/server
COPY crates/daemon ./crates/daemon
RUN cargo build --locked --release -p server

FROM debian:bookworm-slim AS runtime

RUN apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 clumsies

COPY --from=builder /workspace/target/release/clumsies-server /usr/local/bin/clumsies-server

USER clumsies
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/clumsies-server"]
