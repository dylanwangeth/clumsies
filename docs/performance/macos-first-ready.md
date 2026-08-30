# macOS first-ready and daemon synchronization

`first-ready` means the selected Project can render a usable authoritative view. It does not mean every Draft, Issue, Review, cache write, and projection has settled.

## Critical-path split

The old path treated completeness as availability and serialized work amplified by cross-region RTT. The current path keeps only identity, selection, and minimum authoritative state before first-ready; independent datasets load afterward.

Every background result carries the Workspace generation that initiated it. Authority or session changes invalidate stale work. Deferred records merge per record instead of replacing a newer collection.

## Synchronization

Project Commit State uses bounded concurrency. Draft projection deduplicates base Commit loads. Projection updates and cursor advancement are atomic. GET cache persistence uses a bounded coalescing writer, while 401 refresh compares its session snapshot again before publishing credentials or cache state.

First-ready and background-settled measurements remain separate. Dated results and open items are in the [evidence ledger](/performance/evidence-ledger).
