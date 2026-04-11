const std = @import("std");
const HubClient = @import("hub_client.zig").HubClient;
const data = @import("mock_data.zig");

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
};

pub const TrendPoint = struct {
    date: []const u8,
    refer_count: i64,
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
    return std.Thread.spawn(.{}, fetchAll, .{ api_state, url_copy, token_copy });
}

fn fetchAll(api_state: *ApiState, hub_url: []const u8, access_token: []const u8) void {
    api_state.mutex.lock();
    api_state.status = .connecting;
    api_state.mutex.unlock();

    const alloc = api_state.arena.allocator();
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

    api_state.mutex.lock();
    api_state.current_user = user;
    api_state.directory = directory;
    api_state.prompts = prompts_list;
    api_state.bundles = bundles;
    api_state.prompt_prs = prs;
    api_state.org_stats = org_stats;
    api_state.status = .connected;
    api_state.mutex.unlock();
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

// Build InsightsData from OrgStats for chart header.
// Prompts/members/models/alerts fall back to mock data.
pub fn insightsFromStats(stats: OrgStats) data.InsightsData {
    var trend: [30]u16 = .{0} ** 30;
    const count = @min(stats.trend.len, 30);
    for (0..count) |i| {
        const idx = if (stats.trend.len > 30) stats.trend.len - 30 + i else i;
        trend[i] = @intCast(@min(stats.trend[idx].refer_count, std.math.maxInt(u16)));
    }

    const ratio_pct: u8 = @intCast(@min(@as(u64, @intFromFloat(stats.signal_ratio * 100)), 100));
    const idle: u32 = @intCast(@max(stats.idle_constraint_count, 0));
    const active: u32 = @intCast(@max(stats.active_constraint_count, 0));
    const total: u32 = @intCast(@max(stats.constraint_count, 0));

    var refers_per_hour: u16 = 0;
    if (count > 0) {
        const last_day = stats.trend[stats.trend.len - 1].refer_count;
        refers_per_hour = @intCast(@min(@divTrunc(@max(last_day, 0), 24), std.math.maxInt(u16)));
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
        .prompts = data.INSIGHTS.prompts,
        .members = data.INSIGHTS.members,
        .models = data.INSIGHTS.models,
        .alerts = data.INSIGHTS.alerts,
    };
}
