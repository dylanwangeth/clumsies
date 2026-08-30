# End-to-end latency model and diagnosis

Performance work starts by defining completion: first usable UI, complete response, background settlement, or sustained throughput. These metrics are not interchangeable.

## Critical path

End-to-end latency includes required DNS, connection and TLS setup, round trips, Server work, transfer, decoding, persistence, and UI publication. Parallel work contributes its longest required branch, not the sum of all branches.

Record percentiles with sample count. Separate TTFB from full-response time and wire bytes from decoded size. Correlate the client, proxy, Server, database, daemon, and UI with a shared operation identity.

## Optimization order

1. Remove unnecessary critical-path work.
2. Move nonessential work after completion.
3. Batch boundary crossings and bound independent concurrency.
4. Reuse sessions and connections.
5. Reduce wire bytes and post-response work.

Define the event and environment, capture a baseline, localize the dominant boundary, change one causal variable, repeat, then add the smallest structural regression check. See the [Server](/performance/server-hot-path), [macOS](/performance/macos-first-ready), and [gzip](/performance/gzip-experiment) cases.
