//! Declarative endpoint specs. Each constant describes one Hub endpoint:
//! method, path, body shape, response parser. Consumers hand one of these
//! specs — along with the PendingRequest slot that will receive the
//! result — to `dispatchFromState`, which extracts transport credentials
//! from `ApiState` and delegates to the core dispatcher.
//!
//! Adding a new endpoint = adding a new const here plus a PendingRequest
//! field on the appropriate domain state. No thread code, no mutex code,
//! no boilerplate.

const std = @import("std");
const auth_mod = @import("../../auth.zig");
const collab_api = @import("clumsies_lib").protocol.collab_api;
const artifact_api = @import("clumsies_lib").protocol.artifact_api;
const workspace_api = @import("clumsies_lib").protocol.workspace_api;

const data = @import("../models/view_types.zig");
const dispatcher = @import("dispatcher.zig");
const request = @import("request.zig");
const state = @import("state.zig");
const model = @import("model.zig");
const parse = @import("parse.zig");

pub const create_workspace = dispatcher.RequestSpec(
    workspace_api.CreateWorkspaceRequest,
    workspace_api.CreateWorkspaceResponse,
){
    .method = .POST,
    .path_builder = dispatcher.staticPath(workspace_api.CreateWorkspaceRequest, "/api/workspaces"),
    .body_builder = dispatcher.jsonBody(workspace_api.CreateWorkspaceRequest),
    .parse_ok = dispatcher.jsonParser(workspace_api.CreateWorkspaceRequest, workspace_api.CreateWorkspaceResponse),
};

pub const PathParams = struct { path: []const u8 };
pub const RuleContentParams = struct { path: []const u8, rule_id: ?[]const u8 = null };
pub const RulePrsParams = struct { rule_id: []const u8 };
pub const WorkspaceContextContentParams = struct { ws_id: []const u8, path: []const u8 };
pub const WorkspaceIdParams = struct { ws_id: []const u8 };
pub const PrIdParams = struct { pr_id: []const u8, target_kind: data.PrTargetKind = .rule, ws_id: ?[]const u8 = null };
pub const ReviewPrsParams = struct { target_kind: ?data.PrTargetKind = null, status: []const u8 = "open" };

pub const RulePrsPayload = state.RulePrsPayload;
pub const WorkspaceContextPayload = state.WorkspaceContextPayload;
pub const WorkspaceManifestPayload = state.WorkspaceManifestPayload;
pub const WorkspaceContextContentPayload = state.WorkspaceContextContentPayload;
pub const PrCommentsPayload = state.PrCommentsPayload;
pub const CreateRulePrResponse = state.CreateRulePrResponse;
pub const CreateContextPrResponse = state.CreateContextPrResponse;

/// Parameters for creating a rule PR with a single operation.
/// Mirrors CreateContextPrParams so the composer submit path is
/// symmetric across the two categories. Multi-op PRs remain a
/// follow-up; the composer UI submits one draft at a time. Which
/// fields must be non-null depends on `operation_type`: modify,
/// rename, and delete carry `rule_id`; create carries `path`; rename
/// carries `new_path`; modify and rename carry `base_hash`.
pub const CreateRulePrParams = struct {
    description: []const u8,
    operation_type: []const u8,
    rule_id: ?[]const u8 = null,
    path: ?[]const u8 = null,
    new_path: ?[]const u8 = null,
    content: ?[]const u8 = null,
    base_hash: ?[]const u8 = null,
    base_content: ?[]const u8 = null,
};

/// Parameters for creating a context PR. Mirrors the rule PR shape
/// but against a workspace-scoped endpoint. `context_id` identifies
/// an existing file (modify/rename/delete); create-ops leave it null
/// and populate `path` instead. Rename ops populate `new_path`.
pub const CreateContextPrParams = struct {
    ws_id: []const u8,
    description: []const u8,
    operation_type: []const u8,
    context_id: ?[]const u8 = null,
    path: ?[]const u8 = null,
    new_path: ?[]const u8 = null,
    content: []const u8,
    base_hash: ?[]const u8 = null,
    base_content: ?[]const u8 = null,
};

pub const artifact_rule_content = dispatcher.RequestSpec(
    RuleContentParams,
    artifact_api.RuleContentResponse,
){
    .method = .GET,
    .path_builder = ruleContentPath,
    .parse_ok = dispatcher.jsonParser(RuleContentParams, artifact_api.RuleContentResponse),
};

pub const artifact_rule_prs = dispatcher.RequestSpec(
    RulePrsParams,
    RulePrsPayload,
){
    .method = .GET,
    .path_builder = rulePrsPath,
    .parse_ok = parseRulePrsPayload,
};

pub const review_prs = dispatcher.RequestSpec(
    ReviewPrsParams,
    []const model.RulePr,
){
    .method = .GET,
    .path_builder = reviewPrsPath,
    .parse_ok = parseReviewPrsPayload,
};

pub const workspace_context_content = dispatcher.RequestSpec(
    WorkspaceContextContentParams,
    WorkspaceContextContentPayload,
){
    .method = .GET,
    .path_builder = workspaceContextContentPath,
    .parse_ok = parseWorkspaceContextContentPayload,
};

pub const workspace_context = dispatcher.RequestSpec(
    WorkspaceIdParams,
    WorkspaceContextPayload,
){
    .method = .GET,
    .path_builder = workspaceContextFilesPath,
    .parse_ok = parseWorkspaceContextPayload,
};

pub const workspace_manifest = dispatcher.RequestSpec(
    WorkspaceIdParams,
    WorkspaceManifestPayload,
){
    .method = .GET,
    .path_builder = workspaceManifestPath,
    .parse_ok = parseWorkspaceManifestPayload,
};

pub const pr_detail = dispatcher.RequestSpec(
    PrIdParams,
    collab_api.RulePrDetailResponse,
){
    .method = .GET,
    .path_builder = prDetailPath,
    .parse_ok = dispatcher.jsonParser(PrIdParams, collab_api.RulePrDetailResponse),
};

pub const pr_comments = dispatcher.RequestSpec(
    PrIdParams,
    PrCommentsPayload,
){
    .method = .GET,
    .path_builder = prCommentsPath,
    .parse_ok = parsePrCommentsPayload,
};

pub const EmptyParams = struct {};

pub const SubmitCommentParams = struct {
    pr_id: []const u8,
    target_kind: data.PrTargetKind = .rule,
    ws_id: ?[]const u8 = null,
    body: []const u8,
};

pub const PrActionParams = struct {
    pr_id: []const u8,
    target_kind: data.PrTargetKind = .rule,
    ws_id: ?[]const u8 = null,
    action: []const u8,
};

pub const sign_out = dispatcher.RequestSpec(EmptyParams, void){
    .method = .DELETE,
    .path_builder = dispatcher.staticPath(EmptyParams, "/api/auth/token"),
    .body_builder = null,
    .parse_ok = dispatcher.parseVoid(EmptyParams),
};

pub const submit_comment = dispatcher.RequestSpec(SubmitCommentParams, void){
    .method = .POST,
    .path_builder = submitCommentPath,
    .body_builder = submitCommentBody,
    .parse_ok = dispatcher.parseVoid(SubmitCommentParams),
};

pub const pr_action = dispatcher.RequestSpec(PrActionParams, void){
    .method = .PUT,
    .path_builder = prActionPath,
    .body_builder = prActionBody,
    .parse_ok = dispatcher.parseVoid(PrActionParams),
};

pub const create_rule_pr = dispatcher.RequestSpec(CreateRulePrParams, CreateRulePrResponse){
    .method = .POST,
    .path_builder = dispatcher.staticPath(CreateRulePrParams, "/api/org/rule-prs"),
    .body_builder = createRulePrBody,
    .parse_ok = dispatcher.jsonParser(CreateRulePrParams, CreateRulePrResponse),
};

pub const create_context_pr = dispatcher.RequestSpec(CreateContextPrParams, CreateContextPrResponse){
    .method = .POST,
    .path_builder = createContextPrPath,
    .body_builder = createContextPrBody,
    .parse_ok = dispatcher.jsonParser(CreateContextPrParams, CreateContextPrResponse),
};

fn createRulePrBody(alloc: std.mem.Allocator, p: CreateRulePrParams) anyerror![]const u8 {
    // Every op-type field is optional on the wire — the hub tolerates
    // `"field": null` as equivalent to "field absent" (see
    // hub/collab.zig `Operation`), so emitting all fields keeps the
    // body shape uniform and lets the validator branch on `type`.
    // submit code in shell.zig decides which fields to populate per
    // operation_type based on the draft index entry; this function
    // just serializes the decision.
    const Op = struct {
        type: []const u8,
        rule_id: ?[]const u8 = null,
        base_hash: ?[]const u8 = null,
        base_content: ?[]const u8 = null,
        content: ?[]const u8 = null,
        path: ?[]const u8 = null,
        new_path: ?[]const u8 = null,
    };
    const Body = struct {
        description: []const u8,
        operations: []const Op,
    };
    const ops = [_]Op{.{
        .type = p.operation_type,
        .rule_id = p.rule_id,
        .base_hash = p.base_hash,
        .base_content = p.base_content,
        .content = p.content,
        .path = p.path,
        .new_path = p.new_path,
    }};
    return std.json.Stringify.valueAlloc(alloc, Body{
        .description = p.description,
        .operations = &ops,
    }, .{});
}

fn createContextPrPath(alloc: std.mem.Allocator, p: CreateContextPrParams) anyerror![]const u8 {
    return std.fmt.allocPrint(alloc, "/api/workspaces/{s}/context/prs", .{p.ws_id});
}

fn createContextPrBody(alloc: std.mem.Allocator, p: CreateContextPrParams) anyerror![]const u8 {
    const Op = struct {
        type: []const u8,
        context_id: ?[]const u8,
        base_hash: ?[]const u8,
        base_content: ?[]const u8 = null,
        content: []const u8,
        path: ?[]const u8,
        new_path: ?[]const u8,
    };
    const Body = struct {
        description: []const u8,
        operations: []const Op,
    };
    const ops = [_]Op{.{
        .type = p.operation_type,
        .context_id = p.context_id,
        .base_hash = p.base_hash,
        .base_content = p.base_content,
        .content = p.content,
        .path = p.path,
        .new_path = p.new_path,
    }};
    return std.json.Stringify.valueAlloc(alloc, Body{
        .description = p.description,
        .operations = &ops,
    }, .{});
}

fn submitCommentPath(alloc: std.mem.Allocator, p: SubmitCommentParams) anyerror![]const u8 {
    if (p.target_kind == .context) {
        return std.fmt.allocPrint(alloc, "/api/workspaces/{s}/context/prs/{s}/comments", .{ try requireContextWsId(p.ws_id), p.pr_id });
    }
    return std.fmt.allocPrint(alloc, "/api/org/rule-prs/{s}/comments", .{p.pr_id});
}

fn submitCommentBody(alloc: std.mem.Allocator, p: SubmitCommentParams) anyerror![]const u8 {
    const Payload = struct { body: []const u8 };
    return std.json.Stringify.valueAlloc(alloc, Payload{ .body = p.body }, .{});
}

fn prActionPath(alloc: std.mem.Allocator, p: PrActionParams) anyerror![]const u8 {
    if (p.target_kind == .context) {
        return std.fmt.allocPrint(alloc, "/api/workspaces/{s}/context/prs/{s}", .{ try requireContextWsId(p.ws_id), p.pr_id });
    }
    return std.fmt.allocPrint(alloc, "/api/org/rule-prs/{s}", .{p.pr_id});
}

fn prActionBody(alloc: std.mem.Allocator, p: PrActionParams) anyerror![]const u8 {
    const Payload = struct { action: []const u8 };
    const action = if (p.target_kind == .context and std.mem.eql(u8, p.action, "accept")) "merge" else p.action;
    return std.json.Stringify.valueAlloc(alloc, Payload{ .action = action }, .{});
}

fn ruleContentPath(alloc: std.mem.Allocator, p: RuleContentParams) anyerror![]const u8 {
    if (p.rule_id) |rule_id| {
        const encoded = try std.fmt.allocPrint(alloc, "{f}", .{
            std.fmt.alt(std.Uri.Component{ .raw = rule_id }, .formatQuery),
        });
        defer alloc.free(encoded);
        return std.fmt.allocPrint(alloc, "/api/org/artifact/rule/content?rule_id={s}", .{encoded});
    }
    const encoded = try std.fmt.allocPrint(alloc, "{f}", .{
        std.fmt.alt(std.Uri.Component{ .raw = p.path }, .formatQuery),
    });
    defer alloc.free(encoded);
    return std.fmt.allocPrint(alloc, "/api/org/artifact/rule/content?path={s}", .{encoded});
}

fn rulePrsPath(alloc: std.mem.Allocator, p: RulePrsParams) anyerror![]const u8 {
    return std.fmt.allocPrint(alloc, "/api/org/rule-prs?rule_id={s}", .{p.rule_id});
}

fn reviewPrsPath(alloc: std.mem.Allocator, p: ReviewPrsParams) anyerror![]const u8 {
    const target = if (p.target_kind) |kind| kind.label() else "";
    return std.fmt.allocPrint(alloc, "/api/org/review/prs?target={s}&status={s}", .{ target, p.status });
}

fn workspaceContextContentPath(alloc: std.mem.Allocator, p: WorkspaceContextContentParams) anyerror![]const u8 {
    const encoded = try std.fmt.allocPrint(alloc, "{f}", .{
        std.fmt.alt(std.Uri.Component{ .raw = p.path }, .formatQuery),
    });
    defer alloc.free(encoded);
    return std.fmt.allocPrint(alloc, "/api/workspaces/{s}/context/file/content?path={s}", .{ p.ws_id, encoded });
}

fn workspaceContextFilesPath(alloc: std.mem.Allocator, p: WorkspaceIdParams) anyerror![]const u8 {
    return std.fmt.allocPrint(alloc, "/api/workspaces/{s}/context/files", .{p.ws_id});
}

fn workspaceManifestPath(alloc: std.mem.Allocator, p: WorkspaceIdParams) anyerror![]const u8 {
    return std.fmt.allocPrint(alloc, "/api/workspaces/{s}/manifest", .{p.ws_id});
}

fn prDetailPath(alloc: std.mem.Allocator, p: PrIdParams) anyerror![]const u8 {
    if (p.target_kind == .context) {
        return std.fmt.allocPrint(alloc, "/api/workspaces/{s}/context/prs/{s}", .{ try requireContextWsId(p.ws_id), p.pr_id });
    }
    return std.fmt.allocPrint(alloc, "/api/org/rule-prs/{s}", .{p.pr_id});
}

fn prCommentsPath(alloc: std.mem.Allocator, p: PrIdParams) anyerror![]const u8 {
    if (p.target_kind == .context) {
        return std.fmt.allocPrint(alloc, "/api/workspaces/{s}/context/prs/{s}/comments", .{ try requireContextWsId(p.ws_id), p.pr_id });
    }
    return std.fmt.allocPrint(alloc, "/api/org/rule-prs/{s}/comments", .{p.pr_id});
}

fn requireContextWsId(ws_id: ?[]const u8) anyerror![]const u8 {
    const value = ws_id orelse return error.MissingWorkspaceId;
    if (value.len == 0) return error.MissingWorkspaceId;
    return value;
}

test "context PR paths require workspace id" {
    const alloc = std.testing.allocator;

    try std.testing.expectError(error.MissingWorkspaceId, prDetailPath(alloc, .{
        .pr_id = "cpr-1",
        .target_kind = .context,
    }));
    try std.testing.expectError(error.MissingWorkspaceId, prCommentsPath(alloc, .{
        .pr_id = "cpr-1",
        .target_kind = .context,
        .ws_id = "",
    }));
    try std.testing.expectError(error.MissingWorkspaceId, submitCommentPath(alloc, .{
        .pr_id = "cpr-1",
        .target_kind = .context,
        .body = "Looks good.",
    }));
    try std.testing.expectError(error.MissingWorkspaceId, prActionPath(alloc, .{
        .pr_id = "cpr-1",
        .target_kind = .context,
        .action = "accept",
    }));
}

test "context PR paths include workspace id when present" {
    const alloc = std.testing.allocator;
    const path = try prDetailPath(alloc, .{
        .pr_id = "cpr-1",
        .target_kind = .context,
        .ws_id = "ws-1",
    });
    defer alloc.free(path);
    try std.testing.expectEqualStrings("/api/workspaces/ws-1/context/prs/cpr-1", path);
}

test "rename PR bodies include new_path" {
    const alloc = std.testing.allocator;

    const rule_body = try createRulePrBody(alloc, .{
        .description = "rename rule",
        .operation_type = "rename",
        .rule_id = "p-1",
        .new_path = "new/RULE.md",
        .content = "# Rule\n\nBody.\n",
        .base_hash = "sha256:abc",
    });
    defer alloc.free(rule_body);
    try std.testing.expect(std.mem.indexOf(u8, rule_body, "\"new_path\":\"new/RULE.md\"") != null);

    const context_body = try createContextPrBody(alloc, .{
        .ws_id = "ws-1",
        .description = "rename context",
        .operation_type = "rename",
        .context_id = "c-1",
        .new_path = "new/context.md",
        .content = "# Context\n\nBody.\n",
        .base_hash = "sha256:def",
    });
    defer alloc.free(context_body);
    try std.testing.expect(std.mem.indexOf(u8, context_body, "\"new_path\":\"new/context.md\"") != null);
}

/// Wrap the existing `parse.parseRulePrs` into the payload shape that
/// carries the requested `rule_id` alongside the parsed list. The
/// server response is a bare array, so the key is duped out of the
/// request into the long-lived allocator before returning.
fn parseRulePrsPayload(
    alloc: std.mem.Allocator,
    req: RulePrsParams,
    body: []const u8,
) anyerror!RulePrsPayload {
    const prs = parse.parseRulePrs(alloc, body) orelse return error.ParseFailed;
    return .{
        .rule_id = try alloc.dupe(u8, req.rule_id),
        .prs = prs,
    };
}

fn parseReviewPrsPayload(
    alloc: std.mem.Allocator,
    req: ReviewPrsParams,
    body: []const u8,
) anyerror![]const model.RulePr {
    _ = req;
    return parse.parseReviewPrs(alloc, body) orelse error.ParseFailed;
}

fn parseWorkspaceContextPayload(
    alloc: std.mem.Allocator,
    req: WorkspaceIdParams,
    body: []const u8,
) anyerror!WorkspaceContextPayload {
    const files = parse.parseWorkspaceContext(alloc, body) orelse return error.ParseFailed;
    return .{
        .ws_id = try alloc.dupe(u8, req.ws_id),
        .files = files,
    };
}

fn parseWorkspaceManifestPayload(
    alloc: std.mem.Allocator,
    req: WorkspaceIdParams,
    body: []const u8,
) anyerror!WorkspaceManifestPayload {
    const rules = parse.parseManifestRules(alloc, body) orelse return error.ParseFailed;
    return .{
        .ws_id = try alloc.dupe(u8, req.ws_id),
        .rules = rules,
    };
}

fn parseWorkspaceContextContentPayload(
    alloc: std.mem.Allocator,
    req: WorkspaceContextContentParams,
    body: []const u8,
) anyerror!WorkspaceContextContentPayload {
    return .{
        .ws_id = try alloc.dupe(u8, req.ws_id),
        .path = try alloc.dupe(u8, req.path),
        .body = try alloc.dupe(u8, body),
    };
}

fn parsePrCommentsPayload(
    alloc: std.mem.Allocator,
    req: PrIdParams,
    body: []const u8,
) anyerror!PrCommentsPayload {
    const comments = parse.parseComments(alloc, body) orelse return error.ParseFailed;
    return .{
        .pr_id = try alloc.dupe(u8, req.pr_id),
        .comments = comments,
    };
}

/// Dispatch a request using the transport state already held on
/// `api_state`. Hides the mutex-guarded read of `hub_url` and
/// `access_token`, the ApiState arena allocator, and the thread
/// registry plumbing so consumers stay at the level of "call this spec
/// and land the result in this slot."
///
/// If the ApiState has no hub_url or access_token (not yet authed), the
/// call marks the slot as `network_error` via `tryBegin` + immediate
/// `complete`, so the consumer's next `consume` sees a classified
/// failure instead of silent inaction.
pub fn dispatchFromState(
    comptime ReqT: type,
    comptime RespT: type,
    spec: dispatcher.RequestSpec(ReqT, RespT),
    pending: *request.PendingRequest(dispatcher.Result(RespT)),
    api_state: *state.ApiState,
    req: ReqT,
) void {
    api_state.mutex.lock();
    const hub_url = api_state.hub_url;
    const username = api_state.username;
    const access_token = api_state.access_token;
    const refresh_token = api_state.refresh_token;
    api_state.mutex.unlock();

    if (hub_url == null or access_token == null) {
        const gen = pending.tryBegin() orelse return;
        pending.complete(gen, .network_error);
        return;
    }

    dispatcher.dispatch(
        ReqT,
        RespT,
        spec,
        pending,
        &api_state.thread_registry,
        api_state.backing_allocator,
        hub_url.?,
        access_token.?,
        api_state.clientIdHex(),
        if (username != null and refresh_token != null) .{
            .username = username.?,
            .refresh_token = refresh_token.?,
            .persist_fn = auth_mod.persistRotatedTokens,
            .update_ctx = api_state,
            .update_fn = updateAuthTokens,
        } else null,
        api_state.backing_allocator,
        api_state.allocator(),
        req,
    );
}

fn updateAuthTokens(ctx: *anyopaque, access_token: []const u8, refresh_token: []const u8) void {
    const api_state: *state.ApiState = @ptrCast(@alignCast(ctx));
    api_state.updateAuthTokens(access_token, refresh_token);
}

pub const health = dispatcher.RequestSpec(EmptyParams, void){
    .method = .GET,
    .path_builder = dispatcher.staticPath(EmptyParams, "/api/health"),
    .body_builder = null,
    .parse_ok = dispatcher.parseVoid(EmptyParams),
};

pub fn dispatchHealthCheck(api_state: *state.ApiState) void {
    api_state.mutex.lock();
    const hub_url = api_state.hub_url orelse {
        api_state.mutex.unlock();
        return;
    };
    api_state.mutex.unlock();

    dispatcher.dispatch(
        EmptyParams,
        void,
        health,
        &api_state.health_pending,
        &api_state.thread_registry,
        api_state.backing_allocator,
        hub_url,
        "",
        api_state.clientIdHex(),
        null,
        api_state.backing_allocator,
        api_state.allocator(),
        .{},
    );
}
