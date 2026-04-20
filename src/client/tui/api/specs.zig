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
const collab_api = @import("clumsies_lib").protocol.collab_api;
const library_api = @import("clumsies_lib").protocol.library_api;
const workspace_api = @import("clumsies_lib").protocol.workspace_api;

const data = @import("../view_types.zig");
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
pub const PromptPrsParams = struct { prompt_id: []const u8 };
pub const WsContextContentParams = struct { ws_id: []const u8, path: []const u8 };
pub const WsIdParams = struct { ws_id: []const u8 };
pub const PrIdParams = struct { pr_id: []const u8 };

pub const PromptPrsPayload = state.PromptPrsPayload;
pub const WsContextFilesPayload = state.WsContextFilesPayload;
pub const WsManifestPayload = state.WsManifestPayload;
pub const WsContextContentPayload = state.WsContextContentPayload;
pub const PrCommentsPayload = state.PrCommentsPayload;
pub const CreatePromptPrResponse = state.CreatePromptPrResponse;

/// Parameters for creating a prompt PR with a single modify operation.
/// Multi-op PRs are a follow-up; the composer UI submits one draft at
/// a time for now. `base_hash` is null until the cache tracks it.
pub const CreatePromptPrParams = struct {
    description: []const u8,
    prompt_id: []const u8,
    content: []const u8,
    base_hash: ?[]const u8 = null,
};

pub const library_prompt_content = dispatcher.RequestSpec(
    PathParams,
    library_api.PromptContentResponse,
){
    .method = .GET,
    .path_builder = promptContentPath,
    .parse_ok = dispatcher.jsonParser(PathParams, library_api.PromptContentResponse),
};

pub const library_prompt_prs = dispatcher.RequestSpec(
    PromptPrsParams,
    PromptPrsPayload,
){
    .method = .GET,
    .path_builder = promptPrsPath,
    .parse_ok = parsePromptPrsPayload,
};

pub const workspace_context_content = dispatcher.RequestSpec(
    WsContextContentParams,
    WsContextContentPayload,
){
    .method = .GET,
    .path_builder = wsContextContentPath,
    .parse_ok = parseWsContextContentPayload,
};

pub const workspace_context_files = dispatcher.RequestSpec(
    WsIdParams,
    WsContextFilesPayload,
){
    .method = .GET,
    .path_builder = wsContextFilesPath,
    .parse_ok = parseWsContextFilesPayload,
};

pub const workspace_manifest = dispatcher.RequestSpec(
    WsIdParams,
    WsManifestPayload,
){
    .method = .GET,
    .path_builder = wsManifestPath,
    .parse_ok = parseWsManifestPayload,
};

pub const pr_detail = dispatcher.RequestSpec(
    PrIdParams,
    collab_api.PromptPrDetailResponse,
){
    .method = .GET,
    .path_builder = prDetailPath,
    .parse_ok = dispatcher.jsonParser(PrIdParams, collab_api.PromptPrDetailResponse),
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
    body: []const u8,
};

pub const PrActionParams = struct {
    pr_id: []const u8,
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

pub const create_prompt_pr = dispatcher.RequestSpec(CreatePromptPrParams, CreatePromptPrResponse){
    .method = .POST,
    .path_builder = dispatcher.staticPath(CreatePromptPrParams, "/api/org/prompt-prs"),
    .body_builder = createPromptPrBody,
    .parse_ok = dispatcher.jsonParser(CreatePromptPrParams, CreatePromptPrResponse),
};

fn createPromptPrBody(alloc: std.mem.Allocator, p: CreatePromptPrParams) anyerror![]const u8 {
    const Op = struct {
        type: []const u8,
        prompt_id: []const u8,
        base_hash: ?[]const u8,
        content: []const u8,
    };
    const Body = struct {
        description: []const u8,
        operations: []const Op,
    };
    const ops = [_]Op{.{
        .type = "modify",
        .prompt_id = p.prompt_id,
        .base_hash = p.base_hash,
        .content = p.content,
    }};
    return std.json.Stringify.valueAlloc(alloc, Body{
        .description = p.description,
        .operations = &ops,
    }, .{});
}

fn submitCommentPath(alloc: std.mem.Allocator, p: SubmitCommentParams) anyerror![]const u8 {
    return std.fmt.allocPrint(alloc, "/api/org/prompt-prs/{s}/comments", .{p.pr_id});
}

fn submitCommentBody(alloc: std.mem.Allocator, p: SubmitCommentParams) anyerror![]const u8 {
    const Payload = struct { body: []const u8 };
    return std.json.Stringify.valueAlloc(alloc, Payload{ .body = p.body }, .{});
}

fn prActionPath(alloc: std.mem.Allocator, p: PrActionParams) anyerror![]const u8 {
    return std.fmt.allocPrint(alloc, "/api/org/prompt-prs/{s}", .{p.pr_id});
}

fn prActionBody(alloc: std.mem.Allocator, p: PrActionParams) anyerror![]const u8 {
    const Payload = struct { action: []const u8 };
    return std.json.Stringify.valueAlloc(alloc, Payload{ .action = p.action }, .{});
}

fn promptContentPath(alloc: std.mem.Allocator, p: PathParams) anyerror![]const u8 {
    const encoded = try std.fmt.allocPrint(alloc, "{f}", .{
        std.fmt.alt(std.Uri.Component{ .raw = p.path }, .formatQuery),
    });
    defer alloc.free(encoded);
    return std.fmt.allocPrint(alloc, "/api/org/library/prompt/content?path={s}", .{encoded});
}

fn promptPrsPath(alloc: std.mem.Allocator, p: PromptPrsParams) anyerror![]const u8 {
    return std.fmt.allocPrint(alloc, "/api/org/prompt-prs?prompt_id={s}", .{p.prompt_id});
}

fn wsContextContentPath(alloc: std.mem.Allocator, p: WsContextContentParams) anyerror![]const u8 {
    const encoded = try std.fmt.allocPrint(alloc, "{f}", .{
        std.fmt.alt(std.Uri.Component{ .raw = p.path }, .formatQuery),
    });
    defer alloc.free(encoded);
    return std.fmt.allocPrint(alloc, "/api/workspaces/{s}/context/file/content?path={s}", .{ p.ws_id, encoded });
}

fn wsContextFilesPath(alloc: std.mem.Allocator, p: WsIdParams) anyerror![]const u8 {
    return std.fmt.allocPrint(alloc, "/api/workspaces/{s}/context/files", .{p.ws_id});
}

fn wsManifestPath(alloc: std.mem.Allocator, p: WsIdParams) anyerror![]const u8 {
    return std.fmt.allocPrint(alloc, "/api/workspaces/{s}/manifest", .{p.ws_id});
}

fn prDetailPath(alloc: std.mem.Allocator, p: PrIdParams) anyerror![]const u8 {
    return std.fmt.allocPrint(alloc, "/api/org/prompt-prs/{s}", .{p.pr_id});
}

fn prCommentsPath(alloc: std.mem.Allocator, p: PrIdParams) anyerror![]const u8 {
    return std.fmt.allocPrint(alloc, "/api/org/prompt-prs/{s}/comments", .{p.pr_id});
}

/// Wrap the existing `parse.parsePromptPrs` into the payload shape that
/// carries the requested `prompt_id` alongside the parsed list. The
/// server response is a bare array, so the key is duped out of the
/// request into the long-lived allocator before returning.
fn parsePromptPrsPayload(
    alloc: std.mem.Allocator,
    req: PromptPrsParams,
    body: []const u8,
) anyerror!PromptPrsPayload {
    const prs = parse.parsePromptPrs(alloc, body) orelse return error.ParseFailed;
    return .{
        .prompt_id = try alloc.dupe(u8, req.prompt_id),
        .prs = prs,
    };
}

fn parseWsContextFilesPayload(
    alloc: std.mem.Allocator,
    req: WsIdParams,
    body: []const u8,
) anyerror!WsContextFilesPayload {
    const files = parse.parseContextFiles(alloc, body) orelse return error.ParseFailed;
    return .{
        .ws_id = try alloc.dupe(u8, req.ws_id),
        .files = files,
    };
}

fn parseWsManifestPayload(
    alloc: std.mem.Allocator,
    req: WsIdParams,
    body: []const u8,
) anyerror!WsManifestPayload {
    const prompts = parse.parseManifestPrompts(alloc, body) orelse return error.ParseFailed;
    return .{
        .ws_id = try alloc.dupe(u8, req.ws_id),
        .prompts = prompts,
    };
}

fn parseWsContextContentPayload(
    alloc: std.mem.Allocator,
    req: WsContextContentParams,
    body: []const u8,
) anyerror!WsContextContentPayload {
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
    const access_token = api_state.access_token;
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
        api_state.backing_allocator,
        api_state.allocator(),
        req,
    );
}
