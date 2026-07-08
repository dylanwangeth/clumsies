import type { paths as AdminPaths } from "../generated/admin";
import type { paths as PublicPaths } from "../generated/public";
import type { paths as DaemonPaths } from "../generated/daemon";

type Method = "get" | "put" | "post" | "delete" | "options" | "head" | "patch" | "trace";
type Expect<T extends true> = T;
type Equals<TLeft, TRight> =
  (<T>() => T extends TLeft ? 1 : 2) extends (<T>() => T extends TRight ? 1 : 2)
    ? true
    : false;

type HasMethod<TPaths, TPath extends string, TMethod extends Method> =
  TPath extends keyof TPaths
    ? TMethod extends keyof TPaths[TPath]
      ? NonNullable<TPaths[TPath][TMethod]> extends never
        ? false
        : true
      : false
    : false;

type HubPathWithoutApiPrefix<TPaths> = Exclude<Extract<keyof TPaths, string>, `/api/v1/${string}`>;
type DaemonPathWithoutDaemonPrefix<TPaths> = Exclude<Extract<keyof TPaths, string>, `/daemon/${string}`>;

type _publicPathsUseApiV1 = Expect<Equals<HubPathWithoutApiPrefix<PublicPaths>, never>>;
type _adminPathsUseApiV1 = Expect<Equals<HubPathWithoutApiPrefix<AdminPaths>, never>>;
type _daemonPathsUseDaemonPrefix = Expect<Equals<DaemonPathWithoutDaemonPrefix<DaemonPaths>, never>>;

type _publicContract = [
  Expect<HasMethod<PublicPaths, "/api/v1/auth/token", "post">>,
  Expect<HasMethod<PublicPaths, "/api/v1/auth/session", "delete">>,
  Expect<HasMethod<PublicPaths, "/api/v1/me", "get">>,
  Expect<HasMethod<PublicPaths, "/api/v1/projects", "get">>,
  Expect<HasMethod<PublicPaths, "/api/v1/projects", "post">>,
  Expect<HasMethod<PublicPaths, "/api/v1/projects/{project_id}", "get">>,
  Expect<HasMethod<PublicPaths, "/api/v1/me/bundles", "get">>,
  Expect<HasMethod<PublicPaths, "/api/v1/org/rules", "get">>,
  Expect<HasMethod<PublicPaths, "/api/v1/org/rules/{rule_id}", "get">>,
  Expect<HasMethod<PublicPaths, "/api/v1/org/context", "get">>,
  Expect<HasMethod<PublicPaths, "/api/v1/org/context/{context_id}", "get">>,
  Expect<HasMethod<PublicPaths, "/api/v1/org/workflows", "get">>,
  Expect<HasMethod<PublicPaths, "/api/v1/org/workflows/{workflow_id}", "get">>,
  Expect<HasMethod<PublicPaths, "/api/v1/org/metaprompt", "get">>,
  Expect<HasMethod<PublicPaths, "/api/v1/projects/{project_id}/rules", "get">>,
  Expect<HasMethod<PublicPaths, "/api/v1/projects/{project_id}/context", "get">>,
  Expect<HasMethod<PublicPaths, "/api/v1/projects/{project_id}/workflows", "get">>,
  Expect<HasMethod<PublicPaths, "/api/v1/projects/{project_id}/metaprompt", "get">>,
  Expect<HasMethod<PublicPaths, "/api/v1/projects/{project_id}/org-selections", "put">>,
  Expect<HasMethod<PublicPaths, "/api/v1/drafts", "get">>,
  Expect<HasMethod<PublicPaths, "/api/v1/drafts", "post">>,
  Expect<HasMethod<PublicPaths, "/api/v1/draft-events", "get">>,
  Expect<HasMethod<PublicPaths, "/api/v1/draft-operation-batches", "post">>,
  Expect<HasMethod<PublicPaths, "/api/v1/reviews", "post">>,
  Expect<HasMethod<PublicPaths, "/api/v1/reviews/{review_id}/merges", "post">>,
  Expect<HasMethod<PublicPaths, "/api/v1/org/snapshots", "get">>,
  Expect<HasMethod<PublicPaths, "/api/v1/org/snapshot-state", "get">>,
  Expect<HasMethod<PublicPaths, "/api/v1/projects/{project_id}/snapshots", "get">>,
  Expect<HasMethod<PublicPaths, "/api/v1/projects/{project_id}/snapshot-state", "get">>,
  Expect<HasMethod<PublicPaths, "/api/v1/snapshots/{snapshot_id}", "get">>,
];

type _adminContract = [
  Expect<HasMethod<AdminPaths, "/api/v1/admin/org", "get">>,
  Expect<HasMethod<AdminPaths, "/api/v1/admin/org", "patch">>,
  Expect<HasMethod<AdminPaths, "/api/v1/admin/members", "get">>,
  Expect<HasMethod<AdminPaths, "/api/v1/admin/members", "post">>,
  Expect<HasMethod<AdminPaths, "/api/v1/admin/members/{user_id}", "patch">>,
  Expect<HasMethod<AdminPaths, "/api/v1/admin/members/{user_id}", "delete">>,
  Expect<HasMethod<AdminPaths, "/api/v1/admin/projects", "get">>,
  Expect<HasMethod<AdminPaths, "/api/v1/admin/tokens", "get">>,
  Expect<HasMethod<AdminPaths, "/api/v1/admin/tokens/{token_id}", "delete">>,
  Expect<HasMethod<AdminPaths, "/api/v1/admin/audit-events", "get">>,
  Expect<HasMethod<AdminPaths, "/api/v1/admin/health", "get">>,
];

type _daemonContract = [
  Expect<HasMethod<DaemonPaths, "/daemon/health", "get">>,
  Expect<HasMethod<DaemonPaths, "/daemon/project-config", "get">>,
  Expect<HasMethod<DaemonPaths, "/daemon/project-config", "put">>,
  Expect<HasMethod<DaemonPaths, "/daemon/sync-status", "get">>,
  Expect<HasMethod<DaemonPaths, "/daemon/sync-retries", "post">>,
  Expect<HasMethod<DaemonPaths, "/daemon/mcp-status", "get">>,
  Expect<HasMethod<DaemonPaths, "/daemon/mcp-restarts", "post">>,
  Expect<HasMethod<DaemonPaths, "/daemon/mcp-stops", "post">>,
  Expect<HasMethod<DaemonPaths, "/daemon/drafts", "get">>,
  Expect<HasMethod<DaemonPaths, "/daemon/drafts/{draft_id}", "get">>,
  Expect<HasMethod<DaemonPaths, "/daemon/draft-operations", "post">>,
];
