const std = @import("std");
const collab_api = @import("clumsies_lib").protocol.collab_api;
const library_api = @import("clumsies_lib").protocol.library_api;
const workspace_api = @import("clumsies_lib").protocol.workspace_api;
const data = @import("../view_types.zig");
const drafts_reader = @import("../drafts_reader.zig");
const session_reader = @import("../session_reader.zig");
const trace_reader = @import("../trace_reader.zig");
const model = @import("model.zig");
const cache = @import("cache.zig");
const dispatcher = @import("dispatcher.zig");
const request = @import("request.zig");

/// Composite cache key for endpoints scoped to (workspace, path), used
/// by workspace context file content. `cache.StringKey` would not fit:
/// pointer equality on two `[]const u8` fields is wrong.
pub const WsPathKey = struct {
    ws_id: []const u8,
    path: []const u8,

    pub fn eql(self: WsPathKey, other: WsPathKey) bool {
        return std.mem.eql(u8, self.ws_id, other.ws_id) and std.mem.eql(u8, self.path, other.path);
    }
};

pub const DraftEntry = drafts_reader.DraftEntry;
pub const ActiveSession = session_reader.ActiveSession;

pub const ConnectionStatus = enum {
    disconnected,
    connecting,
    connected,
    error_auth,
    error_network,
};

pub const ApiState = struct {
    mutex: std.Thread.Mutex = .{},
    status: ConnectionStatus = .disconnected,
    current_user: ?model.UserData = null,
    directory: ?model.DirectoryData = null,
    prompts: ?[]const model.LibraryPrompt = null,
    bundles: ?[]const model.BundleData = null,
    org_stats: ?model.OrgStats = null,
    local_stats: ?trace_reader.LocalStats = null,
    drafts: ?[]const DraftEntry = null,
    active_sessions: ?[]const ActiveSession = null,

    // Library prompt content, keyed by prompt path.
    prompt_content_pending: request.PendingRequest(dispatcher.Result(library_api.PromptContentResponse)) = .{},
    prompt_content_cache: cache.CacheSlot(cache.StringKey, library_api.PromptContentResponse) = .{},

    // Library prompt PR list, keyed by prompt path (request itself uses prompt_id).
    prompt_prs_pending: request.PendingRequest(dispatcher.Result([]const model.PromptPr)) = .{},
    prompt_prs_cache: cache.CacheSlot(cache.StringKey, []const model.PromptPr) = .{},

    // Workspace context file content, keyed by (ws_id, path).
    ws_context_content_pending: request.PendingRequest(dispatcher.Result([]const u8)) = .{},
    ws_context_content_cache: cache.CacheSlot(WsPathKey, []const u8) = .{},

    // Workspace detail (compound): two independent fetches keyed by ws_id,
    // combined on read via `wsDetail(ws_id)`.
    ws_context_files_pending: request.PendingRequest(dispatcher.Result([]const model.ContextFileData)) = .{},
    ws_context_files_cache: cache.CacheSlot(cache.StringKey, []const model.ContextFileData) = .{},
    ws_manifest_pending: request.PendingRequest(dispatcher.Result([]const model.WsPromptData)) = .{},
    ws_manifest_cache: cache.CacheSlot(cache.StringKey, []const model.WsPromptData) = .{},

    // Pr detail (compound): detail response + comments keyed by pr_id.
    // The detail response carries operations + trace_summary; the consumer
    // computes the diff and picks the active operation against the cached
    // prompt prs list.
    pr_detail_pending: request.PendingRequest(dispatcher.Result(collab_api.PromptPrDetailResponse)) = .{},
    pr_detail_cache: cache.CacheSlot(cache.StringKey, collab_api.PromptPrDetailResponse) = .{},
    pr_comments_pending: request.PendingRequest(dispatcher.Result([]const data.CommentEntry)) = .{},
    pr_comments_cache: cache.CacheSlot(cache.StringKey, []const data.CommentEntry) = .{},

    // Write endpoints. All three carry void payloads on success: the
    // consumer only cares about ok / api_error / network_error.
    sign_out_pending: request.PendingRequest(dispatcher.Result(void)) = .{},
    submit_comment_pending: request.PendingRequest(dispatcher.Result(void)) = .{},
    pr_action_pending: request.PendingRequest(dispatcher.Result(void)) = .{},
    // Derived pr_detail view state, recomputed by consumers whenever
    // pr_detail_cache or pr_comments_cache changes. Kept here because
    // computing the diff on every draw would be wasteful; the consumer
    // caches it once per (pr_id, active prompt_id) transition.
    pr_detail_id: ?[]const u8 = null,
    pr_detail_diff: ?[]const []const u8 = null,
    pr_detail_trace_refers: u16 = 0,
    pr_detail_op_type: ?[]const u8 = null,
    pr_detail_op_current_path: ?[]const u8 = null,
    pr_detail_op_new_path: ?[]const u8 = null,
    pr_detail_op_index: u16 = 0,
    pr_detail_op_total: u16 = 0,
    hub_url: ?[]const u8 = null,
    access_token: ?[]const u8 = null,
    /// True while the compound bootstrap fetch (/me + directory + prompts
    /// + bundles + stats) is running. Prevents overlapping bootstrap
    /// triggers; does not gate any other endpoint, which now run
    /// independently via their own PendingRequest slots.
    bootstrap_inflight: bool = false,
    create_ws_pending: request.PendingRequest(dispatcher.Result(workspace_api.CreateWorkspaceResponse)) = .{},
    thread_registry: dispatcher.ThreadRegistry = .{},
    backing_allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    local_arena: *std.heap.ArenaAllocator,
    ts_allocator: std.heap.ThreadSafeAllocator,

    pub fn init(base_allocator: std.mem.Allocator) ApiState {
        const arena_ptr = base_allocator.create(std.heap.ArenaAllocator) catch
            @panic("ApiState.init: arena allocation failed");
        arena_ptr.* = std.heap.ArenaAllocator.init(base_allocator);
        const local_arena_ptr = base_allocator.create(std.heap.ArenaAllocator) catch
            @panic("ApiState.init: local arena allocation failed");
        local_arena_ptr.* = std.heap.ArenaAllocator.init(base_allocator);
        return .{
            .backing_allocator = base_allocator,
            .arena = arena_ptr,
            .local_arena = local_arena_ptr,
            .ts_allocator = undefined,
        };
    }

    pub fn bindAllocator(self: *ApiState) void {
        self.ts_allocator = .{ .child_allocator = self.arena.allocator() };
    }

    pub fn deinit(self: *ApiState) void {
        self.arena.deinit();
        self.local_arena.deinit();
        self.backing_allocator.destroy(self.arena);
        self.backing_allocator.destroy(self.local_arena);
    }

    pub fn allocator(self: *ApiState) std.mem.Allocator {
        return self.ts_allocator.allocator();
    }
};

pub fn refreshLocalState(api_state: *ApiState) void {
    api_state.mutex.lock();
    defer api_state.mutex.unlock();

    _ = api_state.local_arena.reset(.retain_capacity);
    const alloc = api_state.local_arena.allocator();

    api_state.local_stats = trace_reader.readLocalStats(alloc);
    api_state.drafts = drafts_reader.readAllDrafts(alloc);
    api_state.active_sessions = session_reader.readAllSessions(alloc);
}

pub fn invalidateOnDemandCaches(api_state: *ApiState) void {
    api_state.prompt_prs_cache.invalidate();
    api_state.prompt_content_cache.invalidate();
    api_state.ws_context_content_cache.invalidate();
    api_state.ws_context_files_cache.invalidate();
    api_state.ws_manifest_cache.invalidate();
    api_state.pr_detail_cache.invalidate();
    api_state.pr_comments_cache.invalidate();

    // Cancel in-flight on-demand requests so a worker completing after
    // invalidation cannot repopulate the cache with data the caller
    // explicitly declared stale.
    api_state.prompt_prs_pending.cancel();
    api_state.prompt_content_pending.cancel();
    api_state.ws_context_content_pending.cancel();
    api_state.ws_context_files_pending.cancel();
    api_state.ws_manifest_pending.cancel();
    api_state.pr_detail_pending.cancel();
    api_state.pr_comments_pending.cancel();

    api_state.mutex.lock();
    defer api_state.mutex.unlock();

    api_state.pr_detail_id = null;
    api_state.pr_detail_diff = null;
    api_state.pr_detail_trace_refers = 0;
    api_state.pr_detail_op_type = null;
    api_state.pr_detail_op_current_path = null;
    api_state.pr_detail_op_new_path = null;
    api_state.pr_detail_op_index = 0;
    api_state.pr_detail_op_total = 0;
}

/// Combine the two independently-fetched halves into a WsDetail view.
/// Returns null when either half is not yet cached or they are stale
/// relative to `ws_id`.
pub fn wsDetail(api_state: *ApiState, ws_id: []const u8) ?model.WsDetail {
    const files = api_state.ws_context_files_cache.lookup(.{ .value = ws_id }) orelse return null;
    const prompts = api_state.ws_manifest_cache.lookup(.{ .value = ws_id }) orelse return null;
    return .{
        .ws_id = ws_id,
        .context_files = files,
        .ws_prompts = prompts,
    };
}

/// Combined pr detail view: raw detail response + comments. Returns
/// null when either half is still pending.
pub const PrDetailView = struct {
    detail: collab_api.PromptPrDetailResponse,
    comments: []const data.CommentEntry,
};

pub fn prDetailView(api_state: *ApiState, pr_id: []const u8) ?PrDetailView {
    const detail = api_state.pr_detail_cache.lookup(.{ .value = pr_id }) orelse return null;
    const comments = api_state.pr_comments_cache.lookup(.{ .value = pr_id }) orelse return null;
    return .{ .detail = detail, .comments = comments };
}
