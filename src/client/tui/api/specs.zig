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
const workspace_api = @import("clumsies_lib").protocol.workspace_api;

const dispatcher = @import("dispatcher.zig");
const request = @import("request.zig");
const state = @import("state.zig");

pub const create_workspace = dispatcher.RequestSpec(
    workspace_api.CreateWorkspaceRequest,
    workspace_api.CreateWorkspaceResponse,
){
    .method = .POST,
    .path_builder = dispatcher.staticPath(workspace_api.CreateWorkspaceRequest, "/api/workspaces"),
    .body_builder = dispatcher.jsonBody(workspace_api.CreateWorkspaceRequest),
    .parse_ok = dispatcher.jsonParser(workspace_api.CreateWorkspaceResponse),
};

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
        api_state.allocator(),
        req,
    );
}
