//! Shared TUI API state. This module defines the long-lived caches, pending
//! request slots, local runtime snapshots, and helper accessors that connect
//! asynchronous Hub fetches to synchronous draw code.

const std = @import("std");
const collab_api = @import("clumsies_lib").protocol.collab_api;
const library_api = @import("clumsies_lib").protocol.library_api;
const workspace_api = @import("clumsies_lib").protocol.workspace_api;
const data = @import("../models/view_types.zig");
const drafts_reader = @import("../runtime/drafts_reader.zig");
const attestation_reader = @import("../runtime/attestation_reader.zig");
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

/// Response wrappers for endpoints whose wire response is a bare list
/// (or raw body) and thus carries no request key of its own. The
/// dispatcher parser dupes the relevant request field into the
/// long-lived allocator and returns it alongside the parsed body, so
/// the consumer can route the cache write against the request rather
/// than against whatever the UI happens to select at consume time.
pub const RulePrsPayload = struct {
    rule_id: []const u8,
    prs: []const model.RulePr,
};

pub const WsContextFilesPayload = struct {
    ws_id: []const u8,
    files: []const model.ContextFileData,
};

pub const WsManifestPayload = struct {
    ws_id: []const u8,
    rules: []const model.WsRuleData,
};

pub const WsContextContentPayload = struct {
    ws_id: []const u8,
    path: []const u8,
    body: []const u8,
};

pub const PrCommentsPayload = struct {
    pr_id: []const u8,
    comments: []const data.CommentEntry,
};

pub const CreateRulePrResponse = struct {
    pr_id: []const u8,
    status: []const u8,
};

pub const CreateContextPrResponse = struct {
    pr_id: []const u8,
    status: []const u8,
};

pub const DraftEntry = drafts_reader.DraftEntry;

pub const ConnectionStatus = enum {
    disconnected,
    connecting,
    connected,
    error_auth,
    error_network,
};

pub const AttestationUploadSummary = struct {
    workspace_count: usize = 0,
    events_sent: usize = 0,
    batches_sent: usize = 0,
};

pub const AttestationUploadResult = union(enum) {
    ok: AttestationUploadSummary,
    not_authenticated,
    failed: []const u8,
};

pub const ApiState = struct {
    mutex: std.Thread.Mutex = .{},
    status: ConnectionStatus = .disconnected,
    current_user: ?model.UserData = null,
    directory: ?model.DirectoryData = null,
    rules: ?[]const model.LibraryRule = null,
    bundles: ?[]const model.BundleData = null,
    org_stats: ?model.OrgStats = null,
    local_stats: ?attestation_reader.LocalStats = null,
    drafts: ?[]const DraftEntry = null,

    // Library rule content, keyed by rule path.
    rule_content_pending: request.PendingRequest(dispatcher.Result(library_api.RuleContentResponse)) = .{},
    rule_content_cache: cache.CacheSlot(cache.StringKey, library_api.RuleContentResponse) = .{},

    // Library rule PR list. Pending result carries the rule_id the
    // request was issued for so the consumer stores under the correct
    // cache key even if the UI's rule selection changed mid-flight.
    rule_prs_pending: request.PendingRequest(dispatcher.Result(RulePrsPayload)) = .{},
    rule_prs_cache: cache.CacheSlot(cache.StringKey, []const model.RulePr) = .{},

    // Workspace context file content, keyed by (ws_id, path). Payload
    // includes both halves of the key so the consumer routes the body
    // to the exact request that produced it.
    ws_context_content_pending: request.PendingRequest(dispatcher.Result(WsContextContentPayload)) = .{},
    ws_context_content_cache: cache.CacheSlot(WsPathKey, []const u8) = .{},

    // Workspace detail (compound): two independent fetches keyed by ws_id,
    // combined on read via `wsDetail(ws_id)`. Each pending payload carries
    // its ws_id so a workspace switch mid-flight cannot mis-associate.
    ws_context_files_pending: request.PendingRequest(dispatcher.Result(WsContextFilesPayload)) = .{},
    ws_context_files_cache: cache.CacheSlot(cache.StringKey, []const model.ContextFileData) = .{},
    ws_manifest_pending: request.PendingRequest(dispatcher.Result(WsManifestPayload)) = .{},
    ws_manifest_cache: cache.CacheSlot(cache.StringKey, []const model.WsRuleData) = .{},

    // Pr detail (compound): detail response + comments keyed by pr_id.
    // The detail response carries operations + attestation_summary; the consumer
    // computes the diff and picks the active operation against the cached
    // rule prs list. pr_detail response already echoes pr_id; comments
    // wrap the bare list with a PrCommentsPayload.
    pr_detail_pending: request.PendingRequest(dispatcher.Result(collab_api.RulePrDetailResponse)) = .{},
    pr_detail_cache: cache.CacheSlot(cache.StringKey, collab_api.RulePrDetailResponse) = .{},
    pr_comments_pending: request.PendingRequest(dispatcher.Result(PrCommentsPayload)) = .{},
    pr_comments_cache: cache.CacheSlot(cache.StringKey, []const data.CommentEntry) = .{},

    // Write endpoints. All three carry void payloads on success: the
    // consumer only cares about ok / api_error / network_error.
    sign_out_pending: request.PendingRequest(dispatcher.Result(void)) = .{},
    submit_comment_pending: request.PendingRequest(dispatcher.Result(void)) = .{},
    pr_action_pending: request.PendingRequest(dispatcher.Result(void)) = .{},
    create_rule_pr_pending: request.PendingRequest(dispatcher.Result(CreateRulePrResponse)) = .{},
    create_context_pr_pending: request.PendingRequest(dispatcher.Result(CreateContextPrResponse)) = .{},
    attestation_upload_pending: request.PendingRequest(AttestationUploadResult) = .{},
    // Derived pr_detail view state, recomputed by consumers whenever
    // pr_detail_cache or pr_comments_cache changes. Kept here because
    // computing the diff on every draw would be wasteful; the consumer
    // caches it once per (pr_id, active rule_id) transition.
    pr_detail_id: ?[]const u8 = null,
    pr_detail_diff: ?[]const []const u8 = null,
    pr_detail_attestation_refers: u16 = 0,
    pr_detail_op_type: ?[]const u8 = null,
    pr_detail_op_current_path: ?[]const u8 = null,
    pr_detail_op_new_path: ?[]const u8 = null,
    pr_detail_op_base_hash: ?[]const u8 = null,
    pr_detail_op_index: u16 = 0,
    pr_detail_op_total: u16 = 0,
    hub_url: ?[]const u8 = null,
    access_token: ?[]const u8 = null,
    /// True while the compound bootstrap fetch (/me + directory + rules
    /// + bundles + stats) is running. Prevents overlapping bootstrap
    /// triggers; does not gate any other endpoint, which now run
    /// independently via their own PendingRequest slots.
    bootstrap_inflight: bool = false,
    bootstrap_refetch_requested: bool = false,
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

    api_state.local_stats = attestation_reader.readLocalStats(alloc);
    api_state.drafts = drafts_reader.readAllDrafts(alloc);
}

pub fn invalidateOnDemandCaches(api_state: *ApiState) void {
    api_state.rule_prs_cache.invalidate();
    api_state.rule_content_cache.invalidate();
    api_state.ws_context_content_cache.invalidate();
    api_state.ws_context_files_cache.invalidate();
    api_state.ws_manifest_cache.invalidate();
    api_state.pr_detail_cache.invalidate();
    api_state.pr_comments_cache.invalidate();

    // Cancel in-flight on-demand requests so a worker completing after
    // invalidation cannot repopulate the cache (with either a fresh
    // value or a remembered failure) for data the caller explicitly
    // declared stale.
    api_state.rule_prs_pending.cancel();
    api_state.rule_content_pending.cancel();
    api_state.ws_context_content_pending.cancel();
    api_state.ws_context_files_pending.cancel();
    api_state.ws_manifest_pending.cancel();
    api_state.pr_detail_pending.cancel();
    api_state.pr_comments_pending.cancel();

    api_state.mutex.lock();
    defer api_state.mutex.unlock();

    api_state.pr_detail_id = null;
    api_state.pr_detail_diff = null;
    api_state.pr_detail_attestation_refers = 0;
    api_state.pr_detail_op_type = null;
    api_state.pr_detail_op_current_path = null;
    api_state.pr_detail_op_new_path = null;
    api_state.pr_detail_op_base_hash = null;
    api_state.pr_detail_op_index = 0;
    api_state.pr_detail_op_total = 0;
}

/// Combine the two independently-fetched halves into a WsDetail view.
/// Returns null when either half is not yet cached or they are stale
/// relative to `ws_id`.
pub fn wsDetail(api_state: *ApiState, ws_id: []const u8) ?model.WsDetail {
    const files = api_state.ws_context_files_cache.lookup(.{ .value = ws_id }) orelse return null;
    const rules = api_state.ws_manifest_cache.lookup(.{ .value = ws_id }) orelse return null;
    return .{
        .ws_id = ws_id,
        .context_files = files,
        .ws_rules = rules,
    };
}

/// Combined pr detail view: raw detail response + comments. Returns
/// null when either half is still pending.
pub const PrDetailView = struct {
    detail: collab_api.RulePrDetailResponse,
    comments: []const data.CommentEntry,
};

pub fn prDetailView(api_state: *ApiState, pr_id: []const u8) ?PrDetailView {
    const detail = api_state.pr_detail_cache.lookup(.{ .value = pr_id }) orelse return null;
    const comments = api_state.pr_comments_cache.lookup(.{ .value = pr_id }) orelse return null;
    return .{ .detail = detail, .comments = comments };
}
