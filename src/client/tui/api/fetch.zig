const std = @import("std");
const HubClient = @import("../../hub_client.zig").HubClient;
const model = @import("model.zig");
const parse = @import("parse.zig");
const state = @import("state.zig");

/// Seed api_state with the auth credentials and kick off the initial
/// compound bootstrap fetch. The spawned worker registers itself to
/// the shared thread registry so main.zig's exit path joins it.
pub fn startFetch(
    api_state: *state.ApiState,
    hub_url: []const u8,
    access_token: []const u8,
) !void {
    const alloc = api_state.allocator();
    const url_copy = try alloc.dupe(u8, hub_url);
    const token_copy = try alloc.dupe(u8, access_token);
    api_state.mutex.lock();
    api_state.hub_url = url_copy;
    api_state.access_token = token_copy;
    api_state.bootstrap_inflight = true;
    api_state.mutex.unlock();

    const thread = std.Thread.spawn(.{}, fetchAll, .{ api_state, url_copy, token_copy }) catch |err| {
        api_state.mutex.lock();
        api_state.bootstrap_inflight = false;
        api_state.mutex.unlock();
        return err;
    };
    try api_state.thread_registry.register(thread, api_state.backing_allocator);
}

pub fn refetchAllAsync(api_state: *state.ApiState) void {
    api_state.mutex.lock();
    if (api_state.bootstrap_inflight or api_state.hub_url == null or api_state.access_token == null) {
        api_state.mutex.unlock();
        return;
    }
    api_state.bootstrap_inflight = true;
    const hub_url = api_state.hub_url.?;
    const access_token = api_state.access_token.?;
    api_state.mutex.unlock();

    const thread = std.Thread.spawn(.{}, fetchAll, .{ api_state, hub_url, access_token }) catch {
        api_state.mutex.lock();
        api_state.bootstrap_inflight = false;
        api_state.mutex.unlock();
        return;
    };
    api_state.thread_registry.register(thread, api_state.backing_allocator) catch {};
}

fn fetchAll(
    api_state: *state.ApiState,
    hub_url: []const u8,
    access_token: []const u8,
) void {
    defer {
        api_state.mutex.lock();
        api_state.bootstrap_inflight = false;
        api_state.mutex.unlock();
    }
    api_state.mutex.lock();
    api_state.status = .connecting;
    api_state.mutex.unlock();

    const alloc = api_state.allocator();

    state.refreshLocalState(api_state);

    var client = HubClient.init(alloc, hub_url, access_token);
    defer client.deinit();

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

    const user = parse.parseUser(alloc, me_resp.body) orelse {
        setStatus(api_state, .error_network);
        return;
    };

    const directory = doFetchParse(
        &client,
        alloc,
        "/api/org/directory",
        model.DirectoryData,
        parse.parseDirectory,
    );
    const prompts_list = doFetchParse(
        &client,
        alloc,
        "/api/org/library/prompts",
        []const model.LibraryPrompt,
        parse.parseLibraryPrompts,
    );
    const org_stats = doFetchParse(
        &client,
        alloc,
        "/api/stats?period=daily&days=30",
        model.OrgStats,
        parse.parseOrgStats,
    );
    const bundles = doFetchParse(
        &client,
        alloc,
        "/api/org/bundles",
        []const model.BundleData,
        parse.parseBundles,
    );

    api_state.mutex.lock();
    api_state.current_user = user;
    api_state.directory = directory;
    api_state.prompts = prompts_list;
    api_state.bundles = bundles;
    api_state.org_stats = org_stats;
    api_state.status = .connected;
    api_state.mutex.unlock();
}

/// Produce a unified-diff rendering (prefixed with `  ` / `- ` / `+ `)
/// between two text blobs split on newlines. Used by the PR detail
/// consumer to materialise the diff view after fetching the operation.
pub fn computeDiffLines(
    alloc: std.mem.Allocator,
    base: []const u8,
    proposed: []const u8,
) []const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var base_it = std.mem.splitScalar(u8, base, '\n');
    var prop_it = std.mem.splitScalar(u8, proposed, '\n');

    while (true) {
        const b = base_it.next();
        const p = prop_it.next();
        if (b == null and p == null) break;
        if (b != null and p != null and std.mem.eql(u8, b.?, p.?)) {
            lines.append(
                alloc,
                std.fmt.allocPrint(alloc, "  {s}", .{b.?}) catch continue,
            ) catch continue;
        } else {
            if (b) |bl| {
                lines.append(
                    alloc,
                    std.fmt.allocPrint(alloc, "- {s}", .{bl}) catch continue,
                ) catch continue;
            }
            if (p) |pl| {
                lines.append(
                    alloc,
                    std.fmt.allocPrint(alloc, "+ {s}", .{pl}) catch continue,
                ) catch continue;
            }
        }
    }
    return lines.items;
}

fn setStatus(api_state: *state.ApiState, status: state.ConnectionStatus) void {
    api_state.mutex.lock();
    api_state.status = status;
    api_state.mutex.unlock();
}

fn doFetchParse(
    client: *HubClient,
    alloc: std.mem.Allocator,
    path: []const u8,
    comptime T: type,
    comptime parseFn: *const fn (std.mem.Allocator, []const u8) ?T,
) ?T {
    const resp = client.get(path) catch return null;
    defer resp.deinit();
    if (resp.status != .ok) return null;
    return parseFn(alloc, resp.body);
}
