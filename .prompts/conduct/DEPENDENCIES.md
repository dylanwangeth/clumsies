
# Dependency Management

**Core Principle**: Use package managers, never edit dependency files manually.

## Prohibited

- Manually editing `Cargo.toml`
- Manually editing `package.json`
- Manually editing `foundry.toml`

## Required

- Use `cargo add <package>`
- Use `pnpm add <package>`
- Use `forge install <package>`

## Exception

Only manually edit when the user explicitly requests it.
