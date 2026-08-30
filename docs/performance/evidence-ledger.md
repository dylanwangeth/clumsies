# End-to-end latency evidence ledger

This is the dated index for performance evidence. A number is meaningful only with its revision, environment, route, input, sample count, and completion definition.

## Evidence groups

- Server hot-path comparisons use identical list routes before and after list-shaped reads.
- macOS evidence separates first-ready from background settlement.
- gzip evidence compares upstream time, end-to-end time, encoding, and wire size.
- no-change synchronization verifies that idle passes avoid unnecessary payload and persistence work.

Structural tests are the strongest guard for properties such as “a list does not hydrate payload.” Repeated production samples show operational impact; one-off local timings are diagnostic only.

Applicable verification includes Rust tests and linting, macOS contracts, API compatibility, the VitePress build, internal links, and signing inspection. Production evidence identifies the deployed revision separately from local builds. Detailed dated measurements and trace links are retained in the corresponding Chinese page.
