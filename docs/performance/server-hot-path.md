# Server hot path and Rust architecture

Review and Commit lists were slow because list requests hydrated payloads they never returned. Correct lookups still multiplied database, allocation, and decoding work.

## Design

List queries now select list-shaped rows and construct summaries directly. Detail routes retain full hydration. Commit metadata and payload reads are separate, so a list cannot accidentally depend on large immutable bodies. This removes work that an additional index could not remove.

The Server remains a bounded-context-first modular monolith. HTTP parsing, application services, domain models, and PostgreSQL access have separate responsibilities; performance-sensitive reads stay inside their owning context.

## Verification and debt

Tests use real PostgreSQL and the application router. Hot-path checks block payload dependencies structurally instead of relying on fragile timing thresholds. Production comparisons use the same route and body and separate upstream from transfer time.

The shared repository facade still exposes broad cross-context capabilities. Narrow it only when a concrete change touches that boundary.
