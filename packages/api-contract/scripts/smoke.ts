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
  Expect<HasMethod<PublicPaths, "/api/v1/org/memories", "get">>,
  Expect<HasMethod<PublicPaths, "/api/v1/org/memories/{memory_id}", "get">>,
  Expect<HasMethod<PublicPaths, "/api/v1/projects/{project_id}/memories", "get">>,
  Expect<HasMethod<PublicPaths, "/api/v1/projects/{project_id}/memories/{memory_id}", "get">>,
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
type DaemonMethods = DaemonSchemas["DaemonIpcMethod"];
type DaemonIpcRequestSchema = DaemonSchemas["DaemonIpcRequest"];
type AgentRuntimeIdentitySchema = DaemonSchemas["AgentRuntimeIdentity"];
type AgentRunSchema = DaemonSchemas["AgentRun"];
type RecordAgentRunEventRequestSchema = DaemonSchemas["RecordAgentRunEventRequest"];
type RecordAgentRunEventResponseSchema = DaemonSchemas["RecordAgentRunEventResponse"];
type IssueExternalReferenceSchema = DaemonSchemas["IssueExternalReference"];
type IssueBoardCardSchema = DaemonSchemas["IssueBoardCard"];
type IssueBoardResponseSchema = DaemonSchemas["IssueBoardResponse"];
type IssueDetailResponseSchema = DaemonSchemas["IssueDetailResponse"];
type GetIssueRequestSchema = DaemonSchemas["GetIssueRequest"];
type CreateIssueRequestSchema = DaemonSchemas["CreateIssueRequest"];
type UpdateIssueRequestSchema = DaemonSchemas["UpdateIssueRequest"];
type RemoveIssueRequestSchema = DaemonSchemas["RemoveIssueRequest"];
type IssueRemovalResponseSchema = DaemonSchemas["IssueRemovalResponse"];
type StartIssueWorkRequestSchema = DaemonSchemas["StartIssueWorkRequest"];
type RequestIssueClosureRequestSchema = DaemonSchemas["RequestIssueClosureRequest"];
type IssueWorkflowMutationResponseSchema = DaemonSchemas["IssueWorkflowMutationResponse"];
type ProjectAgentAdapterSchema = DaemonSchemas["DaemonProjectAgentAdapter"];
type ProjectAgentAdapterListResponseSchema = DaemonSchemas["DaemonProjectAgentAdapterListResponse"];
type LegacyAgentAdapterInspectionRequestSchema = DaemonSchemas["DaemonLegacyAgentAdapterInspectionRequest"];
type LegacyAgentAdapterConflictSchema = DaemonSchemas["DaemonLegacyAgentAdapterConflict"];
type LegacyAgentAdapterInspectionResponseSchema = DaemonSchemas["DaemonLegacyAgentAdapterInspectionResponse"];

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
  Expect<Equals<"AgentRun" extends keyof DaemonSchemas ? true : false, true>>,
  Expect<Equals<"RecordAgentRunEventRequest" extends keyof DaemonSchemas ? true : false, true>>,
  Expect<Equals<"RecordAgentRunEventResponse" extends keyof DaemonSchemas ? true : false, true>>,
  Expect<Equals<"IssueBoardListRequest" extends keyof DaemonSchemas ? true : false, true>>,
  Expect<Equals<"IssueBoardResponse" extends keyof DaemonSchemas ? true : false, true>>,
  Expect<Equals<"IssueDetailRequest" extends keyof DaemonSchemas ? true : false, true>>,
  Expect<Equals<"IssueDetailResponse" extends keyof DaemonSchemas ? true : false, true>>,
  Expect<Equals<"GetIssueRequest" extends keyof DaemonSchemas ? true : false, true>>,
  Expect<Equals<"CreateIssueRequest" extends keyof DaemonSchemas ? true : false, true>>,
  Expect<Equals<"UpdateIssueRequest" extends keyof DaemonSchemas ? true : false, true>>,
  Expect<Equals<"RemoveIssueRequest" extends keyof DaemonSchemas ? true : false, true>>,
  Expect<Equals<"IssueRemovalResponse" extends keyof DaemonSchemas ? true : false, true>>,
  Expect<Equals<"StartIssueWorkRequest" extends keyof DaemonSchemas ? true : false, true>>,
  Expect<Equals<"RequestIssueClosureRequest" extends keyof DaemonSchemas ? true : false, true>>,
  Expect<Equals<"IssueWorkflowMutationResponse" extends keyof DaemonSchemas ? true : false, true>>,
  Expect<Equals<"DaemonLegacyAgentAdapterInspectionRequest" extends keyof DaemonSchemas ? true : false, true>>,
  Expect<Equals<"DaemonLegacyAgentAdapterConflict" extends keyof DaemonSchemas ? true : false, true>>,
  Expect<Equals<"DaemonLegacyAgentAdapterInspectionResponse" extends keyof DaemonSchemas ? true : false, true>>,
];

type _daemonAgentRuntimeIdentityContract = [
  Expect<Equals<keyof DaemonIpcRequestSchema, "method" | "payload" | "agent_runtime">>,
  Expect<Equals<DaemonIpcRequestSchema["method"], DaemonMethods>>,
  Expect<Equals<
    DaemonIpcRequestSchema["agent_runtime"],
    AgentRuntimeIdentitySchema | undefined
  >>,
  Expect<Equals<keyof AgentRuntimeIdentitySchema, "protocol_revision" | "build_id">>,
  Expect<Equals<AgentRuntimeIdentitySchema["protocol_revision"], number>>,
  Expect<Equals<AgentRuntimeIdentitySchema["build_id"], string>>,
];

type _daemonAgentAdapterMethods = [
  Expect<Equals<
    Extract<DaemonMethods, "list_all_project_agent_adapters">,
    "list_all_project_agent_adapters"
  >>,
  Expect<Equals<
    Extract<DaemonMethods, "inspect_legacy_agent_adapters">,
    "inspect_legacy_agent_adapters"
  >>,
];

type _daemonAgentAdapterInspectionContract = [
  Expect<Equals<DaemonSchemas["ProjectAgentAdapterKind"], "codex" | "claude-code" | "opencode" | "dsh">>,
  Expect<Equals<keyof LegacyAgentAdapterInspectionRequestSchema, "runtime_binary_path">>,
  Expect<Equals<LegacyAgentAdapterInspectionRequestSchema["runtime_binary_path"], string>>,
  Expect<Equals<
    keyof LegacyAgentAdapterConflictSchema,
    "install_id" | "adapter" | "scope" | "target_root" | "code" | "message"
  >>,
  Expect<Equals<LegacyAgentAdapterConflictSchema["install_id"], string>>,
  Expect<Equals<
    LegacyAgentAdapterConflictSchema["adapter"],
    DaemonSchemas["ProjectAgentAdapterKind"]
  >>,
  Expect<Equals<
    LegacyAgentAdapterConflictSchema["scope"],
    "workspace" | "user" | "repo" | "unknown"
  >>,
  Expect<Equals<LegacyAgentAdapterConflictSchema["target_root"], string>>,
  Expect<Equals<LegacyAgentAdapterConflictSchema["code"], string>>,
  Expect<Equals<LegacyAgentAdapterConflictSchema["message"], string>>,
  Expect<Equals<
    keyof LegacyAgentAdapterInspectionResponseSchema,
    "scanned" | "deferred" | "conflicts"
  >>,
  Expect<Equals<LegacyAgentAdapterInspectionResponseSchema["scanned"], number>>,
  Expect<Equals<LegacyAgentAdapterInspectionResponseSchema["deferred"], number>>,
  Expect<Equals<
    LegacyAgentAdapterInspectionResponseSchema["conflicts"],
    LegacyAgentAdapterConflictSchema[]
  >>,
  Expect<Equals<keyof ProjectAgentAdapterListResponseSchema, "items">>,
  Expect<Equals<ProjectAgentAdapterListResponseSchema["items"], ProjectAgentAdapterSchema[]>>,
];

type _daemonIssueRunMethods = [
  Expect<Equals<Extract<DaemonMethods, "record_agent_run_event">, "record_agent_run_event">>,
  Expect<Equals<Extract<DaemonMethods, "list_issue_board">, "list_issue_board">>,
  Expect<Equals<Extract<DaemonMethods, "desktop_list_issue_board">, "desktop_list_issue_board">>,
  Expect<Equals<Extract<DaemonMethods, "get_issue_detail">, "get_issue_detail">>,
  Expect<Equals<Extract<DaemonMethods, "desktop_get_issue_detail">, "desktop_get_issue_detail">>,
  Expect<Equals<Extract<DaemonMethods, "desktop_store_draft_operation">, "desktop_store_draft_operation">>,
  Expect<Equals<Extract<DaemonMethods, "desktop_unclaim_issue">, "desktop_unclaim_issue">>,
  Expect<Equals<Extract<DaemonMethods, "export_issue">, "export_issue">>,
  Expect<Equals<Extract<DaemonMethods, "pause_issue">, "pause_issue">>,
  Expect<Equals<Extract<DaemonMethods, "resume_issue">, "resume_issue">>,
  Expect<Equals<Extract<DaemonMethods, "get_issue">, "get_issue">>,
  Expect<Equals<Extract<DaemonMethods, "create_issue">, "create_issue">>,
  Expect<Equals<Extract<DaemonMethods, "update_issue">, "update_issue">>,
  Expect<Equals<Extract<DaemonMethods, "apply_issue_gate">, "apply_issue_gate">>,
  Expect<Equals<Extract<DaemonMethods, "remove_issue">, "remove_issue">>,
  Expect<Equals<Extract<DaemonMethods, "start_issue_work">, "start_issue_work">>,
  Expect<Equals<Extract<DaemonMethods, "request_issue_closure">, "request_issue_closure">>,
];

type _daemonIssueRunContract = [
  Expect<Equals<DaemonSchemas["AgentRunHost"], "codex" | "claude-code" | "zed" | "manual" | "opencode" | "dsh">>,
  Expect<Equals<DaemonSchemas["IssueExternalReferenceKind"], "issue" | "pull_request">>,
  Expect<Equals<
    DaemonSchemas["AgentRunEventType"],
    "started" | "heartbeat" | "ended" | "session_ended"
  >>,
  Expect<Equals<RecordAgentRunEventRequestSchema["host_run_key"], string | null>>,
  Expect<Equals<RecordAgentRunEventRequestSchema["parent_host_run_key"], string | null>>,
  Expect<Equals<RecordAgentRunEventRequestSchema["occurred_at"], string | null>>,
  Expect<Equals<RecordAgentRunEventResponseSchema["run"], AgentRunSchema | null>>,
  Expect<Equals<RecordAgentRunEventResponseSchema["affected_runs"], AgentRunSchema[]>>,
  Expect<Equals<AgentRunSchema["issue_number"], number | null>>,
  Expect<Equals<AgentRunSchema["parent_run_id"], string | null>>,
  Expect<Equals<IssueBoardCardSchema["draft_revision"], string | null>>,
  Expect<Equals<IssueBoardCardSchema["issue_id"], string>>,
  Expect<Equals<IssueBoardCardSchema["description"], string>>,
  Expect<Equals<IssueBoardCardSchema["external_references"], IssueExternalReferenceSchema[]>>,
  Expect<Equals<IssueBoardCardSchema["created_at"], string | null>>,
  Expect<Equals<IssueBoardCardSchema["started_at"], string | null>>,
  Expect<Equals<IssueBoardCardSchema["closed_at"], string | null>>,
  Expect<Equals<IssueBoardCardSchema["archived_at"], string | null>>,
  Expect<Equals<IssueBoardCardSchema["is_stale"], boolean>>,
  Expect<Equals<IssueBoardCardSchema["state_revision"], number>>,
  Expect<Equals<IssueBoardResponseSchema["unlinked_runs"], AgentRunSchema[]>>,
  Expect<Equals<IssueDetailResponseSchema["body"], string>>,
  Expect<Equals<GetIssueRequestSchema["issue_id"], string>>,
  Expect<Equals<CreateIssueRequestSchema["description"], string>>,
  Expect<Equals<CreateIssueRequestSchema["external_references"], IssueExternalReferenceSchema[] | undefined>>,
  Expect<Equals<UpdateIssueRequestSchema["description"], string | null | undefined>>,
  Expect<Equals<UpdateIssueRequestSchema["external_references"], IssueExternalReferenceSchema[] | null | undefined>>,
  Expect<Equals<RemoveIssueRequestSchema["action"], "archive" | "delete">>,
  Expect<Equals<IssueRemovalResponseSchema["action"], "archive" | "delete">>,
  Expect<Equals<StartIssueWorkRequestSchema["project_id"], string>>,
  Expect<Equals<RequestIssueClosureRequestSchema["project_id"], string>>,
  Expect<Equals<IssueWorkflowMutationResponseSchema["board_state"], "todo" | "in_progress" | "paused" | "in_review" | "done">>,
  Expect<Equals<IssueWorkflowMutationResponseSchema["issue_id"], string>>,
];
