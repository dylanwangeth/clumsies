# Code Review Instructions

> Development workflow (worktrees + kanban) is documented in `docs/guides/development-workflow.md`; reviews should flag commits that violate the one-issue-one-worktree split.

## Review Priorities

**CRITICAL (Block merge)**
- Memory safety: missing `defer` for allocations, use-after-free from parsed slices pointing into freed buffers, uninitialized memory
- Security: path traversal (unsanitized server-provided paths joined with `fs.path.join`), injection (manual string formatting of JSON/TOML/URLs without escaping), exposed secrets
- Data loss: silent `catch {}` on write operations that should propagate errors

**IMPORTANT (Requires discussion)**
- Missing test coverage for new functions (every new module should have inline tests)
- Resource ownership unclear (who frees an allocated return value?)
- Cross-platform correctness (HOME vs USERPROFILE, path separators, build target vs host OS)

**SUGGESTION (Non-blocking)**
- Naming clarity, code simplification

## Zig 0.16 Conventions

### Style
- Functions: camelCase. Types/Structs: PascalCase. Constants: SCREAMING_SNAKE_CASE. Files: snake_case
- `zig fmt` enforced; `zig build && zig build test` must pass before merge
- Comments: English only, no decorative separators. Prefer `try` over manual error handling

### Memory Management
Every allocation must have a corresponding free:

- `getEnvVarOwned()`, `path.join()`, `allocPrint()` — must `defer allocator.free()`
- `parseFromSlice()` — must `defer parsed.deinit()`; dupe fields before returning
- `toOwnedSlice()` — caller must free or provide `deinit()`
- Use `errdefer` for error-path-only cleanup

Slices pointing into a buffer with `defer deinit()` become dangling after return. Dupe needed fields first.

### Deprecated APIs (0.16)
Flag any use of these:

- `std.io.getStdOut().writer()` — use `File.Writer.init(File.stdout(), &buf)` + `.interface`
- `std.json.stringifyAlloc` — does not exist; use `std.json.Stringify.valueAlloc()`
- `ArrayList(T).init(allocator)` — use `var list: ArrayList(T) = .empty;`
- `GeneralPurposeAllocator` — use `std.heap.DebugAllocator`
- `file.writeAll()` / `file.readToEndAlloc()` — use `File.Writer` / `File.Reader`
- `callconv(.C)` — use lowercase `callconv(.c)`

### Serialization Safety
- Never build JSON with `std.fmt.allocPrint("{s}")` — use `std.json.Stringify.valueAlloc()` with a typed struct
- Never build TOML strings by raw concatenation — escape `"`, `\`, `\n`, `\r`, `\t`
- Never interpolate values into URL query strings without percent-encoding
- Never join file paths with server-provided names without validating against `..` traversal and absolute paths

### Error Handling
- `catch {}` only for best-effort cleanup; `makeDirAbsolute` should check `error.PathAlreadyExists`
- Allocation errors must propagate, not be swallowed

### Build System
- Platform flags must use build **target** OS (`target.result.os.tag`), not host (`builtin.os.tag`)
- Test modules must have the same imports and framework links as the main module

## Compatibility
- No backward compat layers or deprecated wrappers; modify interfaces directly; delete unused code

## Testing
- E2E tests must isolate HOME to a temp directory with cleanup trap
- Inline tests use `std.testing.allocator` (detects leaks); new utility functions need tests for valid and invalid inputs
