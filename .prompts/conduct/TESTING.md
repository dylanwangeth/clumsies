
# Testing Requirements

**Core Principle**: Use automated tests to verify code, never start services to check for bugs.

## Prohibited

- Starting services to manually check for bugs
- Only relying on manual testing
- Skipping tests for "simple" changes

## Required

- Write unit tests for new functionality
- Run existing tests before committing
- Use `cargo test`, `pnpm test`, `forge test` etc.

## Test Commands

```bash
# Rust
cargo test

# Node.js
pnpm test

# Solidity
forge test
```

## Exception

Only skip tests when the user explicitly requests it.
