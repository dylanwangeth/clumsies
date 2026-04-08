# Code Review Instructions

## Review Priorities

**CRITICAL (Block merge)**
- Security: SQL injection, auth bypass, scope enforcement gaps, exposed secrets
- Memory safety: use-after-free, buffer overflows, uninitialized memory in ID buffers
- Correctness: wrong SQL queries, missing foreign key checks, broken cascade deletes
- Data loss: silent `catch {}` on writes that should propagate errors

**IMPORTANT (Requires discussion)**
- Missing E2E test coverage for new endpoints
- Permission model gaps: endpoints missing `auth.checkWorkspaceMember` or `auth.requireScope`
- Performance: N+1 queries in loops (e.g., per-event validation in trace upload)
- Spec compliance: API response format deviating from spec definitions

**SUGGESTION (Non-blocking)**
- Naming clarity, code simplification
- Query optimization opportunities
- Better error messages

## Project-Specific Standards

### Language and Toolchain
- Zig 0.15.1 (see `.prompts/rule/zig/` for deprecated API list)
- `zig fmt` enforced; `zig build && zig build test` must pass before merge
- No deprecated APIs: use `std.ArrayList(T) = .empty`, not `.init(allocator)`

### Hub Server Architecture
- All handlers follow the pattern: authenticate -> scope check -> acquire conn -> business logic -> JSON response
- `auth.authenticate()` returns `AuthUser` with `{user_id, org_id, username, role, scopes}`
- `auth.checkWorkspaceMember()` checks both `workspace_user_access` and `workspace_team_access` via UNION
- `auth.checkWorkspaceAdmin()` checks admin level across both access tables
- `auth.requireScope()` validates token scope; returns false and sends 403 if missing
- `apiError()` is the unified error response helper
- Arena allocator (`req.arena`) for per-request allocations; no manual free needed
- Connection pooling via `ctx.pool.acquire()` / `defer conn.release()`

### ID Generation Pattern
- Prefix + hex-encoded random bytes
- Buffer size must exactly match: prefix length + (random bytes * 2)
- Examples: `ws-` (3) + 32 hex = [35], `tm-` (3) + 32 hex = [35], `cpr-` (4) + 16 hex = [20]

### Database
- PostgreSQL 16, accessed via pg.zig
- Schema migrations run on startup (`CREATE TABLE IF NOT EXISTS`)
- All tables use `ON DELETE CASCADE` for foreign keys where appropriate
- Workspace access uses two tables: `workspace_user_access` (direct) and `workspace_team_access` (team-based)
- Context uses branch model: `context_branches`, `context_files`, `context_prs`, `context_pr_files`

### Error Handling
- HTTP handlers: use `catch { return apiError(...); }` pattern, never propagate raw DB errors to client
- `catch {}` is acceptable only for best-effort cleanup operations (cascade deletes)
- DB row results: always `defer row.deinit() catch {};` or `defer result.deinit();`

### Testing
- E2E tests in `test/hub-e2e.sh` using curl + bash assertions
- Every new endpoint must have at least one E2E test
- Tests must verify both success paths and permission/error paths
- `assert_status` checks HTTP status code; `assert_json` checks response body contains pattern
- DB is reset before each test run (`DROP SCHEMA public CASCADE; CREATE SCHEMA public;`)

### Security Checklist
- Every endpoint must call `auth.authenticate()` (except `POST /api/auth/login`)
- Write endpoints must check `auth.requireScope()` with appropriate scope
- Workspace endpoints must call `auth.checkWorkspaceMember()` or verify maintainer role
- Admin operations must check `auth.checkWorkspaceAdmin()` or maintainer role
- Token scopes enforce least-privilege: `min(role permissions, token scopes)`
- Rate limiting applied to auth endpoints and trace upload

### Code Style
- Functions: camelCase (`handleCreateTeam`)
- Types/Structs: PascalCase (`CreateRequest`, `AuthUser`)
- Constants: SCREAMING_SNAKE_CASE (`MEMBER_SCOPES`)
- Files: snake_case (`team.zig`, `rate_limit.zig`)
- Comments: English only, no decorative separators, no spec references
- No backward compatibility layers; modify interfaces directly
