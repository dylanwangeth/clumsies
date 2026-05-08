//! Shared TUI API state. This module defines the long-lived caches, pending
//! request slots, local runtime snapshots, and helper accessors that connect
//! asynchronous Hub fetches to synchronous draw code.

const std = @import("std");
const collab_api = @import("clumsies_lib").protocol.collab_api;
const artifact_api = @import("clumsies_lib").protocol.artifact_api;
const auth_api = @import("clumsies_lib").protocol.auth_api;
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
pub const WorkspacePathKey = struct {
    ws_id: []const u8,
    path: []const u8,

    pub fn eql(self: WorkspacePathKey, other: WorkspacePathKey) bool {
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

pub const WorkspaceContextPayload = struct {
    ws_id: []const u8,
    files: []const model.WorkspaceContextData,
};

pub const WorkspaceManifestPayload = struct {
    ws_id: []const u8,
    rules: []const model.WorkspaceRuleData,
};

pub const WorkspaceContextContentPayload = struct {
    ws_id: []const u8,
    path: []const u8,
    body: []const u8,
};

pub const WorkspaceMembersPayload = struct {
    ws_id: []const u8,
    members: []const model.WorkspaceMemberData,
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
    rules: ?[]const model.ArtifactRule = null,
    bundles: ?[]const model.BundleData = null,
    org_stats: ?model.OrgStats = null,
    local_stats: ?attestation_reader.LocalStats = null,
    drafts: ?[]const DraftEntry = null,

    // Artifact rule content, keyed by rule path.
    rule_content_pending: request.PendingRequest(dispatcher.Result(artifact_api.RuleContentResponse)) = .{},
    rule_content_cache: cache.CacheSlot(cache.StringKey, artifact_api.RuleContentResponse) = .{},

    // Artifact rule PR list. Pending result carries the rule_id the
    // request was issued for so the consumer stores under the correct
    // cache key even if the UI's rule selection changed mid-flight.
    rule_prs_pending: request.PendingRequest(dispatcher.Result(RulePrsPayload)) = .{},
    rule_prs_cache: cache.CacheSlot(cache.StringKey, []const model.RulePr) = .{},
    review_prs_pending: request.PendingRequest(dispatcher.Result([]const model.RulePr)) = .{},
    review_prs_cache: cache.CacheSlot(cache.StringKey, []const model.RulePr) = .{},

    // Workspace context file content, keyed by (ws_id, path). Payload
    // includes both halves of the key so the consumer routes the body
    // to the exact request that produced it.
    workspace_context_content_pending: request.PendingRequest(dispatcher.Result(WorkspaceContextContentPayload)) = .{},
    workspace_context_content_cache: cache.CacheSlot(WorkspacePathKey, []const u8) = .{},

    // Workspace detail (compound): two independent fetches keyed by ws_id,
    // combined on read via `workspaceDetail(ws_id)`. Each pending payload carries
    // its ws_id so a workspace switch mid-flight cannot mis-associate.
    workspace_context_pending: request.PendingRequest(dispatcher.Result(WorkspaceContextPayload)) = .{},
    workspace_context_cache: cache.CacheSlot(cache.StringKey, []const model.WorkspaceContextData) = .{},
    workspace_manifest_pending: request.PendingRequest(dispatcher.Result(WorkspaceManifestPayload)) = .{},
    workspace_manifest_cache: cache.CacheSlot(cache.StringKey, []const model.WorkspaceRuleData) = .{},
    workspace_members_pending: request.PendingRequest(dispatcher.Result(WorkspaceMembersPayload)) = .{},
    workspace_members_cache: cache.CacheSlot(cache.StringKey, []const model.WorkspaceMemberData) = .{},

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
    health_pending: request.PendingRequest(dispatcher.Result(void)) = .{},
    submit_comment_pending: request.PendingRequest(dispatcher.Result(void)) = .{},
    pr_action_pending: request.PendingRequest(dispatcher.Result(void)) = .{},
    create_rule_pr_pending: request.PendingRequest(dispatcher.Result(CreateRulePrResponse)) = .{},
    create_context_pr_pending: request.PendingRequest(dispatcher.Result(CreateContextPrResponse)) = .{},
    update_profile_pending: request.PendingRequest(dispatcher.Result(auth_api.UpdateProfileResponse)) = .{},
    invite_member_pending: request.PendingRequest(dispatcher.Result(auth_api.InviteMemberResponse)) = .{},
    change_member_role_pending: request.PendingRequest(dispatcher.Result(void)) = .{},
    remove_member_pending: request.PendingRequest(dispatcher.Result(void)) = .{},
    add_workspace_member_pending: request.PendingRequest(dispatcher.Result(void)) = .{},
    change_workspace_member_role_pending: request.PendingRequest(dispatcher.Result(void)) = .{},
    remove_workspace_member_pending: request.PendingRequest(dispatcher.Result(void)) = .{},
    update_ws_pending: request.PendingRequest(dispatcher.Result(workspace_api.CreateWorkspaceResponse)) = .{},
    delete_ws_pending: request.PendingRequest(dispatcher.Result(void)) = .{},
    attestation_upload_pending: request.PendingRequest(AttestationUploadResult) = .{},
    // Derived pr_detail view state, recomputed by consumers whenever
    // pr_detail_cache or pr_comments_cache changes. Kept here because
    // computing the diff on every draw would be wasteful; the consumer
    // caches it once per (pr_id, active rule_id) transition.
    pr_detail_id: ?[]const u8 = null,
    pr_detail_base: ?[]const u8 = null,
    pr_detail_proposed: ?[]const u8 = null,
    pr_detail_attestation_refers: u16 = 0,
    pr_detail_op_type: ?[]const u8 = null,
    pr_detail_op_current_path: ?[]const u8 = null,
    pr_detail_op_new_path: ?[]const u8 = null,
    pr_detail_op_base_hash: ?[]const u8 = null,
    pr_detail_op_index: u16 = 0,
    pr_detail_op_total: u16 = 0,
    hub_url: ?[]const u8 = null,
    username: ?[]const u8 = null,
    access_token: ?[]const u8 = null,
    refresh_token: ?[]const u8 = null,
    /// True while the compound bootstrap fetch (/me + directory + rules
    /// + bundles + stats) is running. Prevents overlapping bootstrap
    /// triggers; does not gate any other endpoint, which now run
    /// independently via their own PendingRequest slots.
    bootstrap_inflight: bool = false,
    bootstrap_refetch_requested: bool = false,
    create_ws_pending: request.PendingRequest(dispatcher.Result(workspace_api.CreateWorkspaceResponse)) = .{},
    thread_registry: dispatcher.ThreadRegistry = .{},
    client_id: [16]u8,
    _client_id_hex: ?[]const u8 = null,
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

        var id_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&id_bytes);

        return .{
            .backing_allocator = base_allocator,
            .arena = arena_ptr,
            .local_arena = local_arena_ptr,
            .client_id = id_bytes,
            .ts_allocator = undefined,
        };
    }

    pub fn bindAllocator(self: *ApiState) void {
        self.ts_allocator = .{ .child_allocator = self.arena.allocator() };
    }

    pub fn clientIdHex(self: *ApiState) []const u8 {
        if (self._client_id_hex) |cached| return cached;
        var buf: [32]u8 = undefined;
        const hex_chars = "0123456789abcdef";
        for (self.client_id, 0..) |byte, i| {
            buf[i * 2] = hex_chars[byte >> 4];
            buf[i * 2 + 1] = hex_chars[byte & 0x0f];
        }
        self._client_id_hex = self.arena.allocator().dupe(u8, &buf) catch "";
        return self._client_id_hex.?;
    }

    pub fn deinit(self: *ApiState) void {
        if (self.access_token) |token| self.backing_allocator.free(token);
        if (self.refresh_token) |token| self.backing_allocator.free(token);
        self.arena.deinit();
        self.local_arena.deinit();
        self.backing_allocator.destroy(self.arena);
        self.backing_allocator.destroy(self.local_arena);
    }

    pub fn allocator(self: *ApiState) std.mem.Allocator {
        return self.ts_allocator.allocator();
    }

    pub fn updateAuthTokens(self: *ApiState, access_token: []const u8, refresh_token: []const u8) void {
        const alloc = self.backing_allocator;
        const access_copy = alloc.dupe(u8, access_token) catch return;
        const refresh_copy = alloc.dupe(u8, refresh_token) catch {
            alloc.free(access_copy);
            return;
        };
        self.mutex.lock();
        const old_access = self.access_token;
        const old_refresh = self.refresh_token;
        self.access_token = access_copy;
        self.refresh_token = refresh_copy;
        self.mutex.unlock();
        if (old_access) |token| alloc.free(token);
        if (old_refresh) |token| alloc.free(token);
    }

    pub fn clearAuthSession(self: *ApiState) void {
        const alloc = self.backing_allocator;
        self.mutex.lock();
        const old_access = self.access_token;
        const old_refresh = self.refresh_token;
        self.access_token = null;
        self.refresh_token = null;
        self.current_user = null;
        self.status = .error_auth;
        self.bootstrap_inflight = false;
        self.bootstrap_refetch_requested = false;
        self.mutex.unlock();
        if (old_access) |token| alloc.free(token);
        if (old_refresh) |token| alloc.free(token);
    }
};

pub fn setConnectionStatus(api_state: *ApiState, status: ConnectionStatus) void {
    api_state.mutex.lock();
    api_state.status = status;
    api_state.mutex.unlock();
}

pub fn refreshLocalState(api_state: *ApiState) void {
    api_state.mutex.lock();
    defer api_state.mutex.unlock();

    _ = api_state.local_arena.reset(.retain_capacity);
    const alloc = api_state.local_arena.allocator();

    api_state.local_stats = attestation_reader.readLocalStats(alloc);
    api_state.drafts = drafts_reader.readAllDrafts(alloc);
}

pub const RemoteCacheScope = enum {
    pr_lists,
    pr_lifecycle,
    artifact_detail,
    workspace_detail,
    all_on_demand,
};

pub fn invalidateRemoteCaches(api_state: *ApiState, scope: RemoteCacheScope) void {
    switch (scope) {
        .pr_lists => {
            invalidatePrLists(api_state);
        },
        .pr_lifecycle => {
            invalidatePrLifecycle(api_state);
        },
        .artifact_detail => {
            api_state.rule_content_cache.invalidate();
            api_state.rule_content_pending.cancel();
        },
        .workspace_detail => {
            invalidateWorkspaceDetail(api_state);
        },
        .all_on_demand => {
            invalidatePrLifecycle(api_state);
            api_state.rule_content_cache.invalidate();
            invalidateWorkspaceDetail(api_state);
            api_state.rule_content_pending.cancel();
            resetPrDetailState(api_state);
        },
    }
}

fn invalidatePrLists(api_state: *ApiState) void {
    api_state.rule_prs_cache.invalidate();
    api_state.review_prs_cache.invalidate();

    api_state.rule_prs_pending.cancel();
    api_state.review_prs_pending.cancel();
}

fn invalidatePrLifecycle(api_state: *ApiState) void {
    invalidatePrLists(api_state);
    api_state.pr_detail_cache.invalidate();
    api_state.pr_comments_cache.invalidate();

    api_state.pr_detail_pending.cancel();
    api_state.pr_comments_pending.cancel();
    resetPrDetailState(api_state);
}

fn invalidateWorkspaceDetail(api_state: *ApiState) void {
    // Workspace manifest/context caches are the TUI's last successful
    // remote authority snapshot. Refresh must not drop them: pull
    // availability is computed by comparing that snapshot against the
    // materialized local manifest, and falling back to local data during
    // a failed tick would make tree rows appear to rename themselves.
    api_state.workspace_context_content_cache.invalidate();
    api_state.workspace_context_cache.clearFailure();
    api_state.workspace_manifest_cache.clearFailure();
    api_state.workspace_context_content_pending.cancel();
    api_state.workspace_context_pending.cancel();
    api_state.workspace_manifest_pending.cancel();
}

pub fn resetPrDetailState(api_state: *ApiState) void {
    api_state.mutex.lock();
    defer api_state.mutex.unlock();

    api_state.pr_detail_id = null;
    api_state.pr_detail_base = null;
    api_state.pr_detail_proposed = null;
    api_state.pr_detail_attestation_refers = 0;
    api_state.pr_detail_op_type = null;
    api_state.pr_detail_op_current_path = null;
    api_state.pr_detail_op_new_path = null;
    api_state.pr_detail_op_base_hash = null;
    api_state.pr_detail_op_index = 0;
    api_state.pr_detail_op_total = 0;
}

/// Combine the two independently-fetched halves into a WorkspaceDetail view.
/// Returns null when either half is not yet cached or they are stale
/// relative to `ws_id`.
pub fn workspaceDetail(api_state: *ApiState, ws_id: []const u8) ?model.WorkspaceDetail {
    const files = api_state.workspace_context_cache.lookup(.{ .value = ws_id }) orelse return null;
    const rules = api_state.workspace_manifest_cache.lookup(.{ .value = ws_id }) orelse return null;
    return .{
        .ws_id = ws_id,
        .workspace_context = files,
        .workspace_rules = rules,
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
