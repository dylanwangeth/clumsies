# Cross-region transfer and gzip: a causal experiment

After Server computation was reduced, cross-region transfer became visible. Proxy gzip helps only when the client advertises an accepted encoding.

## Experiment

Compare the same route and body with and without `Accept-Encoding: gzip`. Record upstream time, end-to-end time, `Content-Encoding`, wire bytes, and decoded bytes while holding revision, region, credentials, and request shape constant. Unchanged upstream work plus changed transfer representation gives stronger causal evidence than an unrelated deployment before/after.

gzip does not improve DNS, TCP, TLS, or TTFB. Small responses may not benefit, one sample is not an SLO, and compression does not replace field selection or incremental sync. Configuration alone is not acceptance evidence: verify headers and wire size at the real client boundary.

See the [evidence ledger](/performance/evidence-ledger) for the dated snapshot.
