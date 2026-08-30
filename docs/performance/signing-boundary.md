# Appendix: debug and distribution signing boundaries

A helper rejected by macOS can trigger retries that resemble a latency regression. Diagnose identity before interpreting those samples as performance.

Ad-hoc signing supplies local structural integrity and a designated requirement, but not a distribution identity. Development, ad-hoc testing, Developer ID, and App Store distribution have different valid requirements.

## Diagnosis

1. Verify bundle and nested-code structure.
2. Inspect identifier, team, and signing flags.
3. Inspect the designated requirement.
4. Check certificates only when the release mode requires them.
5. Return to the caller/helper boundary.

Regression checks protect the identity contract for each release mode; local debug builds do not require a production certificate.
