//! Bootstrap and warmup fetch loop for the TUI. This module owns the
//! coarse-grained authenticated fetch that seeds `/api/auth/me` first,
//! then fills slower module metadata such as directory, rules, bundles,
//! and org stats without blocking workspace selection.

const std = @import("std");
const HubClient = @import("../../hub_client.zig").HubClient;
const model = @import("model.zig");
const parse = @import("parse.zig");
const state = @import("state.zig");

const log = std.log.scoped(.tui_api);

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
    log.info("bootstrap_start", .{});
    api_state.mutex.lock();
    api_state.hub_url = url_copy;
    api_state.access_token = token_copy;
    api_state.bootstrap_inflight = true;
    api_state.mutex.unlock();

    const thread = std.Thread.spawn(.{}, fetchAll, .{ api_state, url_copy, token_copy }) catch |err| {
        log.warn("bootstrap_spawn_failed error={s}", .{@errorName(err)});
        api_state.mutex.lock();
        api_state.bootstrap_inflight = false;
        api_state.mutex.unlock();
        return err;
    };
    try api_state.thread_registry.register(thread, api_state.backing_allocator);
}

pub fn refetchAllAsync(api_state: *state.ApiState) void {
    api_state.mutex.lock();
    if (api_state.hub_url == null or api_state.access_token == null) {
        api_state.mutex.unlock();
        return;
    }
    if (api_state.bootstrap_inflight) {
        log.info("bootstrap_refetch_queued", .{});
        api_state.bootstrap_refetch_requested = true;
        api_state.mutex.unlock();
        return;
    }
    api_state.bootstrap_inflight = true;
    const hub_url = api_state.hub_url.?;
    const access_token = api_state.access_token.?;
    api_state.mutex.unlock();

    const thread = std.Thread.spawn(.{}, fetchAll, .{ api_state, hub_url, access_token }) catch {
        log.warn("bootstrap_refetch_spawn_failed", .{});
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
        var next_hub_url: ?[]const u8 = null;
        var next_access_token: ?[]const u8 = null;
        api_state.mutex.lock();
        api_state.bootstrap_inflight = false;
        if (api_state.bootstrap_refetch_requested and api_state.hub_url != null and api_state.access_token != null) {
            api_state.bootstrap_refetch_requested = false;
            api_state.bootstrap_inflight = true;
            next_hub_url = api_state.hub_url.?;
            next_access_token = api_state.access_token.?;
        }
        api_state.mutex.unlock();
        if (next_hub_url) |url| {
            const token = next_access_token.?;
            if (std.Thread.spawn(.{}, fetchAll, .{ api_state, url, token })) |thread| {
                api_state.thread_registry.register(thread, api_state.backing_allocator) catch {};
            } else |_| {
                api_state.mutex.lock();
                api_state.bootstrap_inflight = false;
                api_state.mutex.unlock();
            }
        }
    }
    api_state.mutex.lock();
    api_state.status = .connecting;
    api_state.mutex.unlock();

    const alloc = api_state.allocator();

    state.refreshLocalState(api_state);
    log.info("bootstrap_local_state_refreshed", .{});

    var client = HubClient.init(alloc, hub_url, access_token);
    defer client.deinit();

    const me_resp = client.get("/api/auth/me") catch {
        log.warn("bootstrap_auth_me network_error", .{});
        setStatus(api_state, .error_network);
        return;
    };
    defer me_resp.deinit();

    if (me_resp.status == .unauthorized) {
        log.warn("bootstrap_auth_me unauthorized", .{});
        setStatus(api_state, .error_auth);
        return;
    }
    if (me_resp.status != .ok) {
        log.warn("bootstrap_auth_me status={d}", .{@intFromEnum(me_resp.status)});
        setStatus(api_state, .error_network);
        return;
    }

    const user = parse.parseUser(alloc, me_resp.body) orelse {
        log.warn("bootstrap_auth_me invalid_response", .{});
        setStatus(api_state, .error_network);
        return;
    };
    log.info("bootstrap_auth_me ok", .{});

    api_state.mutex.lock();
    api_state.current_user = user;
    api_state.status = .connected;
    api_state.mutex.unlock();

    const directory = doFetchParse(
        &client,
        alloc,
        "/api/org/directory",
        model.DirectoryData,
        parse.parseDirectory,
    );
    const rules_list = doFetchParse(
        &client,
        alloc,
        "/api/org/artifact/rules",
        []const model.ArtifactRule,
        parse.parseArtifactRules,
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
    if (directory) |value| api_state.directory = value;
    if (rules_list) |value| api_state.rules = value;
    if (bundles) |value| api_state.bundles = value;
    if (org_stats) |value| api_state.org_stats = value;
    api_state.mutex.unlock();
    log.info("bootstrap_complete directory={} rules={} bundles={} org_stats={}", .{
        directory != null,
        rules_list != null,
        bundles != null,
        org_stats != null,
    });
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
    const resp = client.get(path) catch {
        log.warn("bootstrap_fetch_failed path={s} result=network_error", .{redactedPath(path)});
        return null;
    };
    defer resp.deinit();
    if (resp.status != .ok) {
        log.warn("bootstrap_fetch_failed path={s} status={d}", .{ redactedPath(path), @intFromEnum(resp.status) });
        return null;
    }
    const parsed = parseFn(alloc, resp.body) orelse {
        log.warn("bootstrap_fetch_failed path={s} result=invalid_response", .{redactedPath(path)});
        return null;
    };
    log.info("bootstrap_fetch_ok path={s}", .{redactedPath(path)});
    return parsed;
}

fn redactedPath(path: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, path, '?')) |idx| return path[0..idx];
    return path;
}
