const std = @import("std");
const HubClient = @import("hub_client.zig").HubClient;
const data = @import("mock_data.zig");
const trace_reader = @import("trace_reader.zig");

pub const ConnectionStatus = enum {
    disconnected,
    connecting,
    connected,
    error_auth,
    error_network,
};

// Settings data
pub const UserData = struct {
    user_id: []const u8,
    username: []const u8,
    role: []const u8,
    scopes: []const u8,
    workspaces: []const WsData,
};

pub const WsData = struct {
    ws_id: []const u8,
    name: []const u8,
    role: []const u8 = "",
};

pub const DirectoryMember = struct {
    user_id: []const u8,
    username: []const u8,
    role: []const u8,
    joined_at: []const u8,
};

pub const DirectoryData = struct {
    members: []const DirectoryMember,
};

// Library data
pub const LibraryPrompt = struct {
    prompt_id: []const u8,
    canonical_name: []const u8,
    kind: []const u8,
    content_hash: []const u8,
    updated_at: []const u8,
    refer_count: i64 = 0,
    active_constraint_count: i64 = 0,
    workspace_count: i64 = 0,
    bundle_count: i64 = 0,
    open_pr_count: i64 = 0,
};

pub const BundleData = struct {
    name: []const u8,
    description: []const u8,
    prompt_count: usize,
};

pub const PromptPr = struct {
    pr_id: []const u8,
    prompt_id: []const u8,
    status: []const u8,
    description: []const u8,
    created_at: []const u8,
    author: []const u8,
};

// Stats / Insights data
pub const PromptStats = struct {
    prompt_id: []const u8,
    refer_count: i64,
    active_constraint_count: i64,
    workspace_count: i64,
    bundle_count: i64,
    open_pr_count: i64,
};

pub const OrgStats = struct {
    total_refer_count: i64,
    workspace_count: i64,
    prompt_count: i64,
    constraint_count: i64 = 0,
    active_constraint_count: i64 = 0,
    idle_constraint_count: i64 = 0,
    signal_ratio: f64 = 0,
    last_event_at: ?i64 = null,
    trend: []const TrendPoint,
    prompts: []const PromptStats = &.{},
};

pub const TrendPoint = struct {
    date: []const u8,
    refer_count: i64,
};

// Workspace stats (members + models from /api/stats/workspace/{id})
pub const WsStatsMember = struct {
    username: []const u8,
    refer_count: i64,
    active_days: i64,
    trend: []const i64,
};

pub const WsStatsModel = struct {
    model_id: []const u8,
    refer_count: i64,
};

// Workspace-specific data (fetched on demand)
pub const WsDetail = struct {
    ws_id: []const u8,
    context_files: []const ContextFileData,
    ws_prompts: []const WsPromptData,
};

pub const ContextFileData = struct {
    path: []const u8,
    hash: []const u8,
    size: i64,
    author: []const u8 = "",
    updated_at: []const u8 = "",
};

pub const WsPromptData = struct {
    prompt_id: []const u8,
    content_hash: []const u8,
};

pub const ApiState = struct {
    mutex: std.Thread.Mutex = .{},
    status: ConnectionStatus = .disconnected,
    // Settings
    current_user: ?UserData = null,
    directory: ?DirectoryData = null,
    // Library
    prompts: ?[]const LibraryPrompt = null,
    bundles: ?[]const BundleData = null,
    prompt_prs: ?[]const PromptPr = null,
    // Insights
    org_stats: ?OrgStats = null,
    // Workspace detail (on-demand)
    ws_detail: ?WsDetail = null,
    // Workspace stats (for Insights team activity)
    ws_stats_members: ?[]const WsStatsMember = null,
    ws_stats_models: ?[]const WsStatsModel = null,
    // Local trace stats from ~/.clumsies/log/*.jsonl
    local_stats: ?trace_reader.LocalStats = null,
    prompt_content: ?[]const u8 = null,
    prompt_content_name: ?[]const u8 = null,
    // PR detail (on-demand)
    pr_detail_id: ?[]const u8 = null,
    pr_detail_diff: ?[]const []const u8 = null,
    pr_detail_comments: ?[]const data.CommentEntry = null,
    pr_detail_trace_refers: u16 = 0,
    // Fetch coordination
    hub_url: ?[]const u8 = null,
    access_token: ?[]const u8 = null,
    fetch_busy: bool = false,
    // Arena for all fetched data
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) ApiState {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *ApiState) void {
        self.arena.deinit();
    }
};

pub fn startFetch(api_state: *ApiState, hub_url: []const u8, access_token: []const u8) !std.Thread {
    const alloc = api_state.arena.allocator();
    const url_copy = try alloc.dupe(u8, hub_url);
    const token_copy = try alloc.dupe(u8, access_token);
    api_state.hub_url = url_copy;
    api_state.access_token = token_copy;
    return std.Thread.spawn(.{}, fetchAll, .{ api_state, url_copy, token_copy });
}

// Fetch workspace detail on demand (context files + prompts from manifest)
pub fn fetchWorkspaceAsync(api_state: *ApiState, ws_id: []const u8) void {
    api_state.mutex.lock();
    if (api_state.fetch_busy or api_state.hub_url == null) {
        api_state.mutex.unlock();
        return;
    }
    api_state.fetch_busy = true;
    api_state.mutex.unlock();

    const alloc = api_state.arena.allocator();
    const ws_id_copy = alloc.dupe(u8, ws_id) catch {
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    _ = std.Thread.spawn(.{}, fetchWorkspace, .{ api_state, ws_id_copy }) catch {
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
    };
}

// Fetch prompt content on demand
pub fn fetchPromptContentAsync(api_state: *ApiState, canonical_name: []const u8) void {
    api_state.mutex.lock();
    if (api_state.fetch_busy or api_state.hub_url == null) {
        api_state.mutex.unlock();
        return;
    }
    // Skip if already cached
    if (api_state.prompt_content_name) |cached| {
        if (std.mem.eql(u8, cached, canonical_name)) {
            api_state.mutex.unlock();
            return;
        }
    }
    api_state.fetch_busy = true;
    api_state.mutex.unlock();

    const alloc = api_state.arena.allocator();
    const name_copy = alloc.dupe(u8, canonical_name) catch {
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    _ = std.Thread.spawn(.{}, fetchPromptContent, .{ api_state, name_copy }) catch {
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
    };
}

fn fetchAll(api_state: *ApiState, hub_url: []const u8, access_token: []const u8) void {
    api_state.mutex.lock();
    api_state.status = .connecting;
    api_state.mutex.unlock();

    const alloc = api_state.arena.allocator();

    // Read local trace.jsonl first (available even if server is unreachable)
    const local = trace_reader.readLocalStats(alloc);
    api_state.mutex.lock();
    api_state.local_stats = local;
    api_state.mutex.unlock();

    var client = HubClient.init(alloc, hub_url, access_token);

    // GET /api/auth/me
    const me_resp = client.get("/api/auth/me") catch {
        setStatus(api_state, .error_network);
        return;
    };
    defer me_resp.deinit();

    if (me_resp.status == .unauthorized) {
        setStatus(api_state, .error_auth);
        return;
    }
    if (me_resp.status != .ok) {
        setStatus(api_state, .error_network);
        return;
    }

    const user = parseUser(alloc, me_resp.body) orelse {
        setStatus(api_state, .error_network);
        return;
    };

    // GET /api/org/directory
    const directory = doFetchParse(&client, alloc, "/api/org/directory", DirectoryData, parseDirectory);

    // GET /api/org/library/prompts
    const prompts_list = doFetchParse(&client, alloc, "/api/org/library/prompts", []const LibraryPrompt, parseLibraryPrompts);

    // GET /api/stats?period=daily&days=30
    const org_stats = doFetchParse(&client, alloc, "/api/stats?period=daily&days=30", OrgStats, parseOrgStats);

    // GET /api/org/bundles
    const bundles = doFetchParse(&client, alloc, "/api/org/bundles", []const BundleData, parseBundles);

    // GET /api/org/prompt-prs
    const prs = doFetchParse(&client, alloc, "/api/org/prompt-prs", []const PromptPr, parsePromptPrs);

    // GET /api/stats/workspace/{first_ws_id}?period=daily&days=30
    var ws_members: ?[]const WsStatsMember = null;
    var ws_models: ?[]const WsStatsModel = null;
    if (user.workspaces.len > 0) {
        const ws_stats_path = std.fmt.allocPrint(alloc, "/api/stats/workspace/{s}?period=daily&days=30", .{user.workspaces[0].ws_id}) catch null;
        if (ws_stats_path) |path| {
            const ws_resp = client.get(path) catch null;
            if (ws_resp) |resp| {
                defer resp.deinit();
                if (resp.status == .ok) {
                    const result = parseWsStats(alloc, resp.body);
                    ws_members = result.members;
                    ws_models = result.models;
                }
            }
        }
    }

    api_state.mutex.lock();
    api_state.current_user = user;
    api_state.directory = directory;
    api_state.prompts = prompts_list;
    api_state.bundles = bundles;
    api_state.prompt_prs = prs;
    api_state.org_stats = org_stats;
    api_state.ws_stats_members = ws_members;
    api_state.ws_stats_models = ws_models;
    api_state.status = .connected;
    api_state.mutex.unlock();
}

// Fetch PR detail (diff + comments) on demand
pub fn fetchPrDetailAsync(api_state: *ApiState, pr_id: []const u8) void {
    api_state.mutex.lock();
    if (api_state.fetch_busy or api_state.hub_url == null) {
        api_state.mutex.unlock();
        return;
    }
    if (api_state.pr_detail_id) |cached| {
        if (std.mem.eql(u8, cached, pr_id)) {
            api_state.mutex.unlock();
            return;
        }
    }
    api_state.fetch_busy = true;
    api_state.mutex.unlock();

    const alloc = api_state.arena.allocator();
    const id_copy = alloc.dupe(u8, pr_id) catch {
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    _ = std.Thread.spawn(.{}, fetchPrDetail, .{ api_state, id_copy }) catch {
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
    };
}

fn fetchPrDetail(api_state: *ApiState, pr_id: []const u8) void {
    const alloc = api_state.arena.allocator();
    api_state.mutex.lock();
    const hub_url = api_state.hub_url orelse {
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    const token = api_state.access_token orelse {
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    api_state.mutex.unlock();

    var client = HubClient.init(alloc, hub_url, token);

    // GET /api/org/prompt-prs/{id}
    const detail_path = std.fmt.allocPrint(alloc, "/api/org/prompt-prs/{s}", .{pr_id}) catch {
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    const detail_resp = client.get(detail_path) catch {
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    defer detail_resp.deinit();

    var diff_lines: ?[]const []const u8 = null;
    var trace_refers: u16 = 0;
    if (detail_resp.status == .ok) {
        const DetailJson = struct {
            diff: ?struct {
                base: []const u8 = "",
                proposed: []const u8 = "",
            } = null,
            trace_summary: ?struct {
                refer_count: i64 = 0,
            } = null,
        };
        const parsed = std.json.parseFromSlice(DetailJson, alloc, detail_resp.body, .{ .allocate = .alloc_always }) catch null;
        if (parsed) |p| {
            defer p.deinit();
            if (p.value.diff) |d| {
                diff_lines = computeDiffLines(alloc, d.base, d.proposed);
            }
            if (p.value.trace_summary) |ts| {
                trace_refers = @intCast(@min(ts.refer_count, std.math.maxInt(u16)));
            }
        }
    }

    // GET /api/org/prompt-prs/{id}/comments
    const comments_path = std.fmt.allocPrint(alloc, "/api/org/prompt-prs/{s}/comments", .{pr_id}) catch null;
    var comments: ?[]const data.CommentEntry = null;
    if (comments_path) |cpath| {
        const c_resp = client.get(cpath) catch null;
        if (c_resp) |resp| {
            defer resp.deinit();
            if (resp.status == .ok) {
                comments = parseComments(alloc, resp.body);
            }
        }
    }

    api_state.mutex.lock();
    api_state.pr_detail_id = pr_id;
    api_state.pr_detail_diff = diff_lines;
    api_state.pr_detail_comments = comments;
    api_state.pr_detail_trace_refers = trace_refers;
    api_state.fetch_busy = false;
    api_state.mutex.unlock();
}

fn computeDiffLines(alloc: std.mem.Allocator, base: []const u8, proposed: []const u8) []const []const u8 {
    // Simple line-level diff: lines in base but not proposed get "-", new lines get "+"
    var lines: std.ArrayList([]const u8) = .empty;
    var base_it = std.mem.splitScalar(u8, base, '\n');
    var prop_it = std.mem.splitScalar(u8, proposed, '\n');

    while (true) {
        const b = base_it.next();
        const p = prop_it.next();
        if (b == null and p == null) break;
        if (b != null and p != null and std.mem.eql(u8, b.?, p.?)) {
            lines.append(alloc, std.fmt.allocPrint(alloc, "  {s}", .{b.?}) catch continue) catch continue;
        } else {
            if (b) |bl| {
                lines.append(alloc, std.fmt.allocPrint(alloc, "- {s}", .{bl}) catch continue) catch continue;
            }
            if (p) |pl| {
                lines.append(alloc, std.fmt.allocPrint(alloc, "+ {s}", .{pl}) catch continue) catch continue;
            }
        }
    }
    return lines.items;
}

fn parseComments(alloc: std.mem.Allocator, body: []const u8) ?[]const data.CommentEntry {
    const Json = struct {
        comment_id: []const u8 = "",
        body: []const u8 = "",
        author: []const u8 = "",
        created_at: []const u8 = "",
    };
    // Response is an array of comments
    const parsed = std.json.parseFromSlice([]const Json, alloc, body, .{ .allocate = .alloc_always }) catch return null;
    defer parsed.deinit();

    var list: std.ArrayList(data.CommentEntry) = .empty;
    for (parsed.value) |c| {
        list.append(alloc, .{
            .id = alloc.dupe(u8, c.comment_id) catch continue,
            .author = alloc.dupe(u8, c.author) catch continue,
            .body = alloc.dupe(u8, c.body) catch continue,
            .created = alloc.dupe(u8, c.created_at) catch continue,
        }) catch continue;
    }
    return list.items;
}

// Write operations
pub fn postAction(api_state: *ApiState, alloc: std.mem.Allocator, method: std.http.Method, path: []const u8, body: ?[]const u8) ![]const u8 {
    api_state.mutex.lock();
    const hub_url = api_state.hub_url orelse {
        api_state.mutex.unlock();
        return error.NotConnected;
    };
    const token = api_state.access_token orelse {
        api_state.mutex.unlock();
        return error.NotConnected;
    };
    api_state.mutex.unlock();

    var client = HubClient.init(alloc, hub_url, token);
    const resp = switch (method) {
        .POST => try client.post(path, body orelse "{}"),
        .PUT => try client.put(path, body orelse "{}"),
        .PATCH => try client.patch(path, body orelse "{}"),
        .DELETE => try client.delete(path),
        else => return error.UnsupportedMethod,
    };
    defer resp.deinit();

    if (resp.status == .ok or resp.status == .created or resp.status == .no_content) {
        return alloc.dupe(u8, resp.body);
    }
    return error.RequestFailed;
}

fn fetchWorkspace(api_state: *ApiState, ws_id: []const u8) void {
    const alloc = api_state.arena.allocator();
    api_state.mutex.lock();
    const hub_url = api_state.hub_url orelse {
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    const token = api_state.access_token orelse {
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    api_state.mutex.unlock();

    var client = HubClient.init(alloc, hub_url, token);

    // GET /api/workspaces/{ws_id}/context/files
    const files_path = std.fmt.allocPrint(alloc, "/api/workspaces/{s}/context/files", .{ws_id}) catch {
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    const files = doFetchParse(&client, alloc, files_path, []const ContextFileData, parseContextFiles);

    // GET /api/workspaces/{ws_id}/manifest
    const manifest_path = std.fmt.allocPrint(alloc, "/api/workspaces/{s}/manifest", .{ws_id}) catch {
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    const ws_prompts = doFetchParse(&client, alloc, manifest_path, []const WsPromptData, parseManifestPrompts);

    api_state.mutex.lock();
    api_state.ws_detail = .{
        .ws_id = ws_id,
        .context_files = files orelse &.{},
        .ws_prompts = ws_prompts orelse &.{},
    };
    api_state.fetch_busy = false;
    api_state.mutex.unlock();
}

fn fetchPromptContent(api_state: *ApiState, canonical_name: []const u8) void {
    const alloc = api_state.arena.allocator();
    api_state.mutex.lock();
    const hub_url = api_state.hub_url orelse {
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    const token = api_state.access_token orelse {
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    api_state.mutex.unlock();

    var client = HubClient.init(alloc, hub_url, token);
    const path = std.fmt.allocPrint(alloc, "/api/org/library/prompt/content?name={s}", .{canonical_name}) catch {
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };

    const resp = client.get(path) catch {
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    defer resp.deinit();

    if (resp.status == .ok) {
        // Parse {"body": "content..."} or use raw body
        const ContentJson = struct { body: []const u8 = "" };
        const parsed = std.json.parseFromSlice(ContentJson, alloc, resp.body, .{ .allocate = .alloc_always }) catch null;
        const content = if (parsed) |p| blk: {
            defer p.deinit();
            break :blk alloc.dupe(u8, p.value.body) catch null;
        } else null;

        api_state.mutex.lock();
        api_state.prompt_content = content;
        api_state.prompt_content_name = canonical_name;
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
    } else {
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
    }
}

fn parseContextFiles(alloc: std.mem.Allocator, body: []const u8) ?[]const ContextFileData {
    const Json = struct {
        files: []const struct {
            path: []const u8,
            hash: []const u8,
            size: i64 = 0,
            author: []const u8 = "",
            updated_at: []const u8 = "",
        } = &.{},
    };
    const parsed = std.json.parseFromSlice(Json, alloc, body, .{ .allocate = .alloc_always }) catch return null;
    defer parsed.deinit();

    var list: std.ArrayList(ContextFileData) = .empty;
    for (parsed.value.files) |f| {
        list.append(alloc, .{
            .path = alloc.dupe(u8, f.path) catch continue,
            .hash = alloc.dupe(u8, f.hash) catch continue,
            .size = f.size,
            .author = alloc.dupe(u8, f.author) catch continue,
            .updated_at = alloc.dupe(u8, f.updated_at) catch continue,
        }) catch continue;
    }
    return list.items;
}

fn parseManifestPrompts(alloc: std.mem.Allocator, body: []const u8) ?[]const WsPromptData {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{ .allocate = .alloc_always }) catch return null;
    defer parsed.deinit();

    const prompts_obj = switch (parsed.value) {
        .object => |obj| obj.get("prompts") orelse return null,
        else => return null,
    };
    const map = switch (prompts_obj) {
        .object => |obj| obj,
        else => return null,
    };

    var list: std.ArrayList(WsPromptData) = .empty;
    var it = map.iterator();
    while (it.next()) |entry| {
        const hash = switch (entry.value_ptr.*) {
            .string => |s| s,
            else => "",
        };
        list.append(alloc, .{
            .prompt_id = alloc.dupe(u8, entry.key_ptr.*) catch continue,
            .content_hash = alloc.dupe(u8, hash) catch continue,
        }) catch continue;
    }
    return list.items;
}

const WsStatsResult = struct {
    members: ?[]const WsStatsMember,
    models: ?[]const WsStatsModel,
};

fn parseWsStats(alloc: std.mem.Allocator, body: []const u8) WsStatsResult {
    const Json = struct {
        members: []const struct {
            username: []const u8 = "",
            refer_count: i64 = 0,
            active_days: i64 = 0,
            trend: []const i64 = &.{},
        } = &.{},
        models: []const struct {
            model_id: []const u8 = "",
            refer_count: i64 = 0,
        } = &.{},
    };
    const parsed = std.json.parseFromSlice(Json, alloc, body, .{ .allocate = .alloc_always }) catch return .{ .members = null, .models = null };
    defer parsed.deinit();

    var members: std.ArrayList(WsStatsMember) = .empty;
    for (parsed.value.members) |m| {
        var trend_copy: std.ArrayList(i64) = .empty;
        for (m.trend) |t| {
            trend_copy.append(alloc, t) catch continue;
        }
        members.append(alloc, .{
            .username = alloc.dupe(u8, m.username) catch continue,
            .refer_count = m.refer_count,
            .active_days = m.active_days,
            .trend = trend_copy.items,
        }) catch continue;
    }

    var models: std.ArrayList(WsStatsModel) = .empty;
    for (parsed.value.models) |m| {
        models.append(alloc, .{
            .model_id = alloc.dupe(u8, m.model_id) catch continue,
            .refer_count = m.refer_count,
        }) catch continue;
    }

    return .{
        .members = members.items,
        .models = models.items,
    };
}

fn setStatus(api_state: *ApiState, status: ConnectionStatus) void {
    api_state.mutex.lock();
    api_state.status = status;
    api_state.mutex.unlock();
}

fn doFetchParse(client: *HubClient, alloc: std.mem.Allocator, path: []const u8, comptime T: type, comptime parseFn: *const fn (std.mem.Allocator, []const u8) ?T) ?T {
    const resp = client.get(path) catch return null;
    defer resp.deinit();
    if (resp.status != .ok) return null;
    return parseFn(alloc, resp.body);
}

fn parseUser(alloc: std.mem.Allocator, body: []const u8) ?UserData {
    const MeJson = struct {
        user_id: []const u8,
        username: []const u8,
        role: []const u8,
        scopes: []const u8,
        workspaces: []const struct { ws_id: []const u8, name: []const u8, role: []const u8 = "" },
    };
    const parsed = std.json.parseFromSlice(MeJson, alloc, body, .{ .allocate = .alloc_always }) catch return null;
    defer parsed.deinit();
    const v = parsed.value;

    var ws_list: std.ArrayList(WsData) = .empty;
    for (v.workspaces) |ws| {
        ws_list.append(alloc, .{
            .ws_id = alloc.dupe(u8, ws.ws_id) catch continue,
            .name = alloc.dupe(u8, ws.name) catch continue,
            .role = alloc.dupe(u8, ws.role) catch continue,
        }) catch continue;
    }

    return .{
        .user_id = alloc.dupe(u8, v.user_id) catch return null,
        .username = alloc.dupe(u8, v.username) catch return null,
        .role = alloc.dupe(u8, v.role) catch return null,
        .scopes = alloc.dupe(u8, v.scopes) catch return null,
        .workspaces = ws_list.items,
    };
}

fn parseDirectory(alloc: std.mem.Allocator, body: []const u8) ?DirectoryData {
    const DirJson = struct {
        members: []const struct {
            user_id: []const u8,
            username: []const u8,
            role: []const u8,
            joined_at: []const u8,
        },
    };
    const parsed = std.json.parseFromSlice(DirJson, alloc, body, .{ .allocate = .alloc_always }) catch return null;
    defer parsed.deinit();

    var members: std.ArrayList(DirectoryMember) = .empty;
    for (parsed.value.members) |m| {
        members.append(alloc, .{
            .user_id = alloc.dupe(u8, m.user_id) catch continue,
            .username = alloc.dupe(u8, m.username) catch continue,
            .role = alloc.dupe(u8, m.role) catch continue,
            .joined_at = alloc.dupe(u8, m.joined_at) catch continue,
        }) catch continue;
    }

    return .{ .members = members.items };
}

fn parseLibraryPrompts(alloc: std.mem.Allocator, body: []const u8) ?[]const LibraryPrompt {
    const Json = struct {
        prompts: []const struct {
            prompt_id: []const u8,
            kind: []const u8,
            source: []const u8 = "",
            canonical_name: []const u8,
            content_hash: []const u8,
            updated_at: []const u8,
        },
    };
    const parsed = std.json.parseFromSlice(Json, alloc, body, .{ .allocate = .alloc_always }) catch return null;
    defer parsed.deinit();

    var list: std.ArrayList(LibraryPrompt) = .empty;
    for (parsed.value.prompts) |p| {
        list.append(alloc, .{
            .prompt_id = alloc.dupe(u8, p.prompt_id) catch continue,
            .canonical_name = alloc.dupe(u8, p.canonical_name) catch continue,
            .kind = alloc.dupe(u8, p.kind) catch continue,
            .content_hash = alloc.dupe(u8, p.content_hash) catch continue,
            .updated_at = alloc.dupe(u8, p.updated_at) catch continue,
        }) catch continue;
    }
    return list.items;
}

fn parseOrgStats(alloc: std.mem.Allocator, body: []const u8) ?OrgStats {
    const StatsJson = struct {
        total_refer_count: i64 = 0,
        workspace_count: i64 = 0,
        prompt_count: i64 = 0,
        constraint_count: i64 = 0,
        active_constraint_count: i64 = 0,
        idle_constraint_count: i64 = 0,
        signal_ratio: f64 = 0,
        last_event_at: ?i64 = null,
        prompts: []const struct {
            prompt_id: []const u8,
            refer_count: i64 = 0,
            active_constraint_count: i64 = 0,
            workspace_count: i64 = 0,
            bundle_count: i64 = 0,
            open_pr_count: i64 = 0,
        } = &.{},
        trend: struct {
            period: []const u8 = "",
            data: []const struct {
                date: []const u8,
                refer_count: i64 = 0,
            } = &.{},
        } = .{},
    };
    const parsed = std.json.parseFromSlice(StatsJson, alloc, body, .{ .allocate = .alloc_always }) catch return null;
    defer parsed.deinit();
    const v = parsed.value;

    var trend_list: std.ArrayList(TrendPoint) = .empty;
    for (v.trend.data) |t| {
        trend_list.append(alloc, .{
            .date = alloc.dupe(u8, t.date) catch continue,
            .refer_count = t.refer_count,
        }) catch continue;
    }

    var prompt_stats: std.ArrayList(PromptStats) = .empty;
    for (v.prompts) |p| {
        prompt_stats.append(alloc, .{
            .prompt_id = alloc.dupe(u8, p.prompt_id) catch continue,
            .refer_count = p.refer_count,
            .active_constraint_count = p.active_constraint_count,
            .workspace_count = p.workspace_count,
            .bundle_count = p.bundle_count,
            .open_pr_count = p.open_pr_count,
        }) catch continue;
    }

    return .{
        .total_refer_count = v.total_refer_count,
        .workspace_count = v.workspace_count,
        .prompt_count = v.prompt_count,
        .constraint_count = v.constraint_count,
        .active_constraint_count = v.active_constraint_count,
        .idle_constraint_count = v.idle_constraint_count,
        .signal_ratio = v.signal_ratio,
        .last_event_at = v.last_event_at,
        .trend = trend_list.items,
        .prompts = prompt_stats.items,
    };
}

fn parseBundles(alloc: std.mem.Allocator, body: []const u8) ?[]const BundleData {
    const Json = struct {
        bundles: []const struct {
            name: []const u8,
            description: []const u8 = "",
            updated_at: []const u8 = "",
            prompt_ids: []const []const u8 = &.{},
        },
    };
    const parsed = std.json.parseFromSlice(Json, alloc, body, .{ .allocate = .alloc_always }) catch return null;
    defer parsed.deinit();

    var list: std.ArrayList(BundleData) = .empty;
    for (parsed.value.bundles) |b| {
        list.append(alloc, .{
            .name = alloc.dupe(u8, b.name) catch continue,
            .description = alloc.dupe(u8, b.description) catch continue,
            .prompt_count = b.prompt_ids.len,
        }) catch continue;
    }
    return list.items;
}

fn parsePromptPrs(alloc: std.mem.Allocator, body: []const u8) ?[]const PromptPr {
    const Json = struct {
        prs: []const struct {
            pr_id: []const u8,
            prompt_id: []const u8,
            status: []const u8,
            description: []const u8,
            created_at: []const u8,
            author: []const u8 = "",
        },
    };
    const parsed = std.json.parseFromSlice(Json, alloc, body, .{ .allocate = .alloc_always }) catch return null;
    defer parsed.deinit();

    var list: std.ArrayList(PromptPr) = .empty;
    for (parsed.value.prs) |pr| {
        list.append(alloc, .{
            .pr_id = alloc.dupe(u8, pr.pr_id) catch continue,
            .prompt_id = alloc.dupe(u8, pr.prompt_id) catch continue,
            .status = alloc.dupe(u8, pr.status) catch continue,
            .description = alloc.dupe(u8, pr.description) catch continue,
            .created_at = alloc.dupe(u8, pr.created_at) catch continue,
            .author = alloc.dupe(u8, pr.author) catch continue,
        }) catch continue;
    }
    return list.items;
}

// Convert API LibraryPrompts to mock-compatible PromptEntry slice.
// This lets syncLibraryWidgets work unchanged with live data.
pub fn toPromptEntries(alloc: std.mem.Allocator, prompts: []const LibraryPrompt) []const data.PromptEntry {
    var list: std.ArrayList(data.PromptEntry) = .empty;
    for (prompts) |p| {
        const refer_str = formatCount(alloc, p.refer_count) catch "";
        list.append(alloc, .{
            .canonical_name = p.canonical_name,
            .kind = p.kind,
            .refer_count = refer_str,
            .constraint_count = @intCast(@min(p.active_constraint_count, 255)),
            .bundle_count = @intCast(@min(p.bundle_count, 255)),
            .bundle_names = "",
            .updated = p.updated_at,
            .age = "",
            .summary = "",
            .trend = .{0} ** 8,
            .content_hash = p.content_hash,
            .open_pr_count = @intCast(@min(p.open_pr_count, 255)),
            .workspace_count = @intCast(@min(p.workspace_count, 255)),
            .workspace_names = "",
            .revision = 0,
        }) catch continue;
    }
    return list.items;
}

fn formatCount(alloc: std.mem.Allocator, n: i64) ![]const u8 {
    if (n >= 1000) {
        const k = @as(f64, @floatFromInt(n)) / 1000.0;
        return std.fmt.allocPrint(alloc, "{d:.1}k", .{k});
    }
    return std.fmt.allocPrint(alloc, "{d}", .{n});
}

// Convert API BundleData to mock-compatible BundleEntry slice.
pub fn toBundleEntries(alloc: std.mem.Allocator, bundles: []const BundleData) []const data.BundleEntry {
    var list: std.ArrayList(data.BundleEntry) = .empty;
    for (bundles) |b| {
        list.append(alloc, .{
            .name = b.name,
            .count = @intCast(@min(b.prompt_count, std.math.maxInt(u16))),
        }) catch continue;
    }
    return list.items;
}

// Convert API PromptPr to mock-compatible PullRequestEntry slice.
// If pr_detail is available for a PR, its diff/comments are populated.
pub fn toPrEntries(alloc: std.mem.Allocator, prs: []const PromptPr, canonical_name: []const u8, library: ?[]const LibraryPrompt, api_state: *ApiState) []const data.PullRequestEntry {
    // Find prompt_id for the given canonical_name
    const target_id: ?[]const u8 = if (library) |lib| blk: {
        for (lib) |lp| {
            if (std.mem.eql(u8, lp.canonical_name, canonical_name))
                break :blk lp.prompt_id;
        }
        break :blk null;
    } else null;

    var list: std.ArrayList(data.PullRequestEntry) = .empty;
    for (prs) |pr| {
        // Filter by prompt_id if we found one, otherwise skip
        if (target_id) |tid| {
            if (!std.mem.eql(u8, pr.prompt_id, tid)) continue;
        } else continue;

        // Populate diff/comments from cached PR detail if matching
        var diff: []const []const u8 = &.{};
        var comments: []const data.CommentEntry = &.{};
        var trace_refers: u16 = 0;
        if (api_state.pr_detail_id) |cached_id| {
            if (std.mem.eql(u8, cached_id, pr.pr_id)) {
                diff = api_state.pr_detail_diff orelse &.{};
                comments = api_state.pr_detail_comments orelse &.{};
                trace_refers = api_state.pr_detail_trace_refers;
            }
        }

        list.append(alloc, .{
            .id = pr.pr_id,
            .prompt_name = canonical_name,
            .status = pr.status,
            .author = pr.author,
            .created = pr.created_at,
            .description = pr.description,
            .base_hash = "",
            .diff = diff,
            .comments = comments,
            .trace_refers = trace_refers,
            .trace_sessions = 0,
        }) catch continue;
    }
    return list.items;
}

fn toInsightsMembers(alloc: std.mem.Allocator, members: []const WsStatsMember) []const data.InsightsMember {
    var list: std.ArrayList(data.InsightsMember) = .empty;
    for (members) |m| {
        var trend30: [30]u16 = .{0} ** 30;
        const count = @min(m.trend.len, 30);
        for (0..count) |i| {
            trend30[i] = @intCast(@min(@max(m.trend[i], 0), std.math.maxInt(u16)));
        }
        list.append(alloc, .{
            .username = m.username,
            .refer_count = @intCast(@min(m.refer_count, std.math.maxInt(u32))),
            .active_days = @intCast(@min(m.active_days, 255)),
            .trend = trend30,
            .top_prompts = &.{},
            .models = &.{},
        }) catch continue;
    }
    return list.items;
}

fn toInsightsModels(alloc: std.mem.Allocator, models: []const WsStatsModel) []const data.InsightsModel {
    var total: i64 = 0;
    for (models) |m| total += m.refer_count;
    var list: std.ArrayList(data.InsightsModel) = .empty;
    for (models) |m| {
        const pct: u8 = if (total > 0) @intCast(@min(@divTrunc(m.refer_count * 100, total), 100)) else 0;
        list.append(alloc, .{
            .model_id = m.model_id,
            .refer_count = @intCast(@min(m.refer_count, std.math.maxInt(u32))),
            .pct = pct,
        }) catch continue;
    }
    return list.items;
}

// Build InsightsData from OrgStats.
// Members/models/alerts fall back to mock (need workspace-level stats).
pub fn insightsFromStats(alloc: std.mem.Allocator, stats: OrgStats, library: ?[]const LibraryPrompt, ws_members: ?[]const WsStatsMember, ws_models: ?[]const WsStatsModel, local: ?trace_reader.LocalStats) data.InsightsData {
    var trend: [30]u16 = .{0} ** 30;
    const tcount = @min(stats.trend.len, 30);
    for (0..tcount) |i| {
        const idx = if (stats.trend.len > 30) stats.trend.len - 30 + i else i;
        trend[i] = @intCast(@min(stats.trend[idx].refer_count, std.math.maxInt(u16)));
    }

    const ratio_pct: u8 = @intCast(@min(@as(u64, @intFromFloat(stats.signal_ratio * 100)), 100));
    const idle: u32 = @intCast(@max(stats.idle_constraint_count, 0));
    const active: u32 = @intCast(@max(stats.active_constraint_count, 0));
    const total: u32 = @intCast(@max(stats.constraint_count, 0));

    var refers_per_hour: u16 = 0;
    if (tcount > 0) {
        const last_day = stats.trend[stats.trend.len - 1].refer_count;
        refers_per_hour = @intCast(@min(@divTrunc(@max(last_day, 0), 24), std.math.maxInt(u16)));
    }

    // Build InsightsPrompt from per-prompt stats
    var prompts_list: std.ArrayList(data.InsightsPrompt) = .empty;
    for (stats.prompts) |ps| {
        const name = if (library) |lib| blk: {
            for (lib) |lp| {
                if (std.mem.eql(u8, lp.prompt_id, ps.prompt_id))
                    break :blk lp.canonical_name;
            }
            break :blk ps.prompt_id;
        } else ps.prompt_id;

        const c_total: u8 = @intCast(@min(ps.active_constraint_count, 255));
        const c_idle: u8 = 0;
        const sig: u8 = if (c_total > 0) @intCast(@min(@divTrunc(ps.active_constraint_count * 100, @max(c_total, 1)), 100)) else 0;
        const rate: u16 = @intCast(@min(@divTrunc(@max(ps.refer_count, 0), @max(@as(i64, @intCast(tcount)), 1)), std.math.maxInt(u16)));

        prompts_list.append(alloc, .{
            .name = name,
            .constraint_count = c_total,
            .active_constraint_count = c_total,
            .idle_constraint_count = c_idle,
            .signal_ratio = sig,
            .refer_count = @intCast(@min(ps.refer_count, std.math.maxInt(u32))),
            .rate_per_day = rate,
            .delta_pct = 0,
            .last_referred_days_ago = 0,
            .trend = .{0} ** 30,
            .constraints = &.{},
        }) catch continue;
    }

    // Prefer local trace data for chart and prompts (personal real-time)
    // Fall back to server stats for team-level data
    if (local) |l| {
        return .{
            .constraint_count = l.constraint_count,
            .active_constraint_count = l.active_constraint_count,
            .idle_constraint_count = if (l.constraint_count > l.active_constraint_count) l.constraint_count - l.active_constraint_count else 0,
            .signal_ratio = l.signal_ratio,
            .refers_per_hour = refers_per_hour,
            .today_delta_pct = 0,
            .last_event_minutes_ago = 0,
            .refer_trend = l.refer_trend,
            .prompts = l.prompts,
            .members = if (ws_members) |wm| toInsightsMembers(alloc, wm) else &.{},
            .models = if (ws_models) |wmod| toInsightsModels(alloc, wmod) else &.{},
            .alerts = &.{},
        };
    }

    return .{
        .constraint_count = total,
        .active_constraint_count = active,
        .idle_constraint_count = idle,
        .signal_ratio = ratio_pct,
        .refers_per_hour = refers_per_hour,
        .today_delta_pct = 0,
        .last_event_minutes_ago = 0,
        .refer_trend = trend,
        .prompts = prompts_list.items,
        .members = if (ws_members) |wm| toInsightsMembers(alloc, wm) else &.{},
        .models = if (ws_models) |wmod| toInsightsModels(alloc, wmod) else &.{},
        .alerts = &.{},
    };
}
