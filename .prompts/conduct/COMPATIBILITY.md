
# Backward Compatibility

**Core Principle**: Project is in development phase, breaking changes are expected.

## Prohibited

- Writing deprecated functions
- Adding compatibility layers
- Keeping old interfaces
- Using `_unusedVar` and other backward compatibility hacks

## Recommended

- Directly modify existing interfaces when refactoring
- Delete unused code
- Prioritize code simplicity and correctness

## Exception

Only consider backward compatibility when the user explicitly requests it.
