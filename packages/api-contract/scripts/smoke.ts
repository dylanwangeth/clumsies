import type { paths as AdminPaths } from "../generated/admin";
import type { paths as PublicPaths } from "../generated/public";
import type { components as DaemonComponents, paths as DaemonPaths } from "../generated/daemon";

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

type ServerPathWithoutApiPrefix<TPaths> = Exclude<Extract<keyof TPaths, string>, `/api/v1/${string}`>;
type PublicBrowserAuthPath =
  | "/oauth2/authorization/oidc"
  | "/login/oauth2/code/oidc";

type _publicPathsUseApiV1 = Expect<
  Equals<ServerPathWithoutApiPrefix<PublicPaths>, PublicBrowserAuthPath>
>;
type _adminPathsUseApiV1 = Expect<Equals<ServerPathWithoutApiPrefix<AdminPaths>, never>>;
type _daemonHasNoHttpPaths = Expect<Equals<DaemonPaths, Record<string, never>>>;

type _publicContract = [
  Expect<HasMethod<PublicPaths, "/oauth2/authorization/oidc", "get">>,
  Expect<HasMethod<PublicPaths, "/login/oauth2/code/oidc", "get">>,
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
  Expect<HasMethod<PublicPaths, "/api/v1/projects/{project_id}/rules", "get">>,
  Expect<HasMethod<PublicPaths, "/api/v1/projects/{project_id}/context", "get">>,
  Expect<HasMethod<PublicPaths, "/api/v1/projects/{project_id}/workflows", "get">>,
  Expect<HasMethod<PublicPaths, "/api/v1/projects/{project_id}/org-selections", "put">>,
  Expect<HasMethod<PublicPaths, "/api/v1/drafts", "get">>,
  Expect<HasMethod<PublicPaths, "/api/v1/drafts", "post">>,
  Expect<HasMethod<PublicPaths, "/api/v1/draft-events", "get">>,
  Expect<HasMethod<PublicPaths, "/api/v1/draft-operation-batches", "post">>,
  Expect<HasMethod<PublicPaths, "/api/v1/reviews", "post">>,
  Expect<HasMethod<PublicPaths, "/api/v1/reviews/{review_id}/merges", "post">>,
  Expect<HasMethod<PublicPaths, "/api/v1/org/commits", "get">>,
  Expect<HasMethod<PublicPaths, "/api/v1/org/commit-state", "get">>,
  Expect<HasMethod<PublicPaths, "/api/v1/projects/{project_id}/commits", "get">>,
  Expect<HasMethod<PublicPaths, "/api/v1/projects/{project_id}/commit-state", "get">>,
  Expect<HasMethod<PublicPaths, "/api/v1/commits/{commit_id}", "get">>,
];

type _adminContract = [
  Expect<HasMethod<AdminPaths, "/api/v1/setup", "get">>,
  Expect<HasMethod<AdminPaths, "/api/v1/setup/sessions", "post">>,
  Expect<HasMethod<AdminPaths, "/api/v1/setup/configuration", "put">>,
  Expect<HasMethod<AdminPaths, "/api/v1/setup/oidc-authorizations", "post">>,
  Expect<HasMethod<AdminPaths, "/api/v1/admin/org", "get">>,
  Expect<HasMethod<AdminPaths, "/api/v1/admin/org", "patch">>,
  Expect<HasMethod<AdminPaths, "/api/v1/admin/members", "get">>,
  Expect<HasMethod<AdminPaths, "/api/v1/admin/members", "post">>,
  Expect<HasMethod<AdminPaths, "/api/v1/admin/members/{user_id}", "patch">>,
  Expect<HasMethod<AdminPaths, "/api/v1/admin/members/{user_id}", "delete">>,
  Expect<HasMethod<AdminPaths, "/api/v1/admin/projects", "get">>,
  Expect<HasMethod<AdminPaths, "/api/v1/admin/projects/{project_id}/members", "get">>,
  Expect<HasMethod<AdminPaths, "/api/v1/admin/projects/{project_id}/members", "post">>,
  Expect<HasMethod<AdminPaths, "/api/v1/admin/projects/{project_id}/members/{user_id}", "patch">>,
  Expect<HasMethod<AdminPaths, "/api/v1/admin/projects/{project_id}/members/{user_id}", "delete">>,
  Expect<HasMethod<AdminPaths, "/api/v1/admin/tokens", "get">>,
  Expect<HasMethod<AdminPaths, "/api/v1/admin/tokens/{token_id}", "delete">>,
  Expect<HasMethod<AdminPaths, "/api/v1/admin/audit-events", "get">>,
  Expect<HasMethod<AdminPaths, "/api/v1/admin/health", "get">>,
];

type DaemonSchemas = DaemonComponents["schemas"];
type _daemonContract = [
  Expect<Equals<"DaemonBootstrapStatus" extends keyof DaemonSchemas ? true : false, true>>,
  Expect<Equals<"DaemonIpcEndpoint" extends keyof DaemonSchemas ? true : false, true>>,
  Expect<Equals<"DaemonIpcRequest" extends keyof DaemonSchemas ? true : false, true>>,
  Expect<Equals<"DaemonIpcResponse" extends keyof DaemonSchemas ? true : false, true>>,
  Expect<Equals<"LaunchAgentRuntimeStatus" extends keyof DaemonSchemas ? true : false, true>>,
  Expect<Equals<"DaemonHealth" extends keyof DaemonSchemas ? true : false, true>>,
  Expect<Equals<"DaemonSyncStatus" extends keyof DaemonSchemas ? true : false, true>>,
  Expect<Equals<"DaemonMcpStatus" extends keyof DaemonSchemas ? true : false, true>>,
  Expect<Equals<"DaemonDraftOperationRequest" extends keyof DaemonSchemas ? true : false, true>>,
  Expect<Equals<"DaemonDraftOperationResponse" extends keyof DaemonSchemas ? true : false, true>>,
  Expect<Equals<"DaemonServerRequest" extends keyof DaemonSchemas ? true : false, true>>,
  Expect<Equals<"DaemonServerResponse" extends keyof DaemonSchemas ? true : false, true>>,
];
