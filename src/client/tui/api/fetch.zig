//! Bootstrap and warmup fetch loop for the TUI. This module owns the
//! coarse-grained authenticated fetch that seeds `/api/auth/me` first,
//! then fills slower module metadata such as directory, rules, bundles,
//! and org stats without blocking workspace selection.

const std = @import("std");
const HubClient = @import("../../hub_client.zig").HubClient;
const logger = @import("clumsies_lib").logger;
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
    username: []const u8,
    access_token: []const u8,
    refresh_token: []const u8,
) !void {
    const alloc = api_state.allocator();
    const token_alloc = api_state.backing_allocator;
    const url_copy = try alloc.dupe(u8, hub_url);
    const username_copy = try alloc.dupe(u8, username);
    const token_copy = try token_alloc.dupe(u8, access_token);
    const refresh_copy = token_alloc.dupe(u8, refresh_token) catch |err| {
        token_alloc.free(token_copy);
        return err;
    };
    log.info("bootstrap_start", .{});
    api_state.mutex.lock();
    const old_access = api_state.access_token;
    const old_refresh = api_state.refresh_token;
    api_state.hub_url = url_copy;
    api_state.username = username_copy;
    api_state.access_token = token_copy;
    api_state.refresh_token = refresh_copy;
    api_state.bootstrap_inflight = true;
    api_state.mutex.unlock();
    if (old_access) |token| token_alloc.free(token);
    if (old_refresh) |token| token_alloc.free(token);

    const thread = std.Thread.spawn(.{}, fetchAll, .{ api_state, url_copy, username_copy, token_copy, refresh_copy }) catch |err| {
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
    if (api_state.hub_url == null or api_state.username == null or api_state.access_token == null or api_state.refresh_token == null) {
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
    const username = api_state.username.?;
    const access_token = api_state.access_token.?;
    const refresh_token = api_state.refresh_token.?;
    api_state.mutex.unlock();

    const thread = std.Thread.spawn(.{}, fetchAll, .{ api_state, hub_url, username, access_token, refresh_token }) catch {
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
    username: []const u8,
    access_token: []const u8,
    refresh_token: []const u8,
) void {
    _ = username;
    _ = refresh_token;
    defer {
        var next_hub_url: ?[]const u8 = null;
        var next_username: ?[]const u8 = null;
        var next_access_token: ?[]const u8 = null;
        var next_refresh_token: ?[]const u8 = null;
        api_state.mutex.lock();
        if (api_state.bootstrap_refetch_requested and api_state.hub_url != null and api_state.username != null and api_state.access_token != null and api_state.refresh_token != null) {
            api_state.bootstrap_refetch_requested = false;
            next_hub_url = api_state.hub_url.?;
            next_username = api_state.username.?;
            next_access_token = api_state.access_token.?;
            next_refresh_token = api_state.refresh_token.?;
        } else {
            api_state.bootstrap_inflight = false;
        }
        api_state.mutex.unlock();
        if (next_hub_url) |url| {
            const next_user = next_username.?;
            const token = next_access_token.?;
            const refresh = next_refresh_token.?;
            if (std.Thread.spawn(.{}, fetchAll, .{ api_state, url, next_user, token, refresh })) |thread| {
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

    var me_resp = client.get("/api/auth/me") catch {
        log.warn("bootstrap_auth_me network_error", .{});
        setStatus(api_state, .error_network);
        return;
    };
    var me_resp_active = true;
    defer if (me_resp_active) me_resp.deinit();

    if (me_resp.status == .unauthorized) {
        log.info("bootstrap_refresh_token path=/api/auth/me", .{});
        const tokens = api_state.refreshAuthTokens(alloc, access_token) catch |err| {
            log.warn("bootstrap_refresh_token_failed path=/api/auth/me error={s}", .{@errorName(err)});
            setStatus(api_state, .error_auth);
            return;
        };
        me_resp.deinit();
        me_resp_active = false;

        var retry_client = HubClient.init(alloc, hub_url, tokens.access_token);
        defer retry_client.deinit();
        me_resp = retry_client.get("/api/auth/me") catch {
            log.warn("bootstrap_auth_me network_error", .{});
            setStatus(api_state, .error_network);
            return;
        };
        me_resp_active = true;
        client.access_token = tokens.access_token;
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
    state.setConnectionStatus(api_state, status);
}

fn doFetchParse(
    client: *HubClient,
    alloc: std.mem.Allocator,
    path: []const u8,
    comptime T: type,
    comptime parseFn: *const fn (std.mem.Allocator, []const u8) ?T,
) ?T {
    const resp = client.get(path) catch {
        log.warn("bootstrap_fetch_failed path={s} result=network_error", .{logger.redactedPath(path)});
        return null;
    };
    defer resp.deinit();
    if (resp.status != .ok) {
        log.warn("bootstrap_fetch_failed path={s} status={d}", .{ logger.redactedPath(path), @intFromEnum(resp.status) });
        return null;
    }
    const parsed = parseFn(alloc, resp.body) orelse {
        log.warn("bootstrap_fetch_failed path={s} result=invalid_response", .{logger.redactedPath(path)});
        return null;
    };
    log.info("bootstrap_fetch_ok path={s}", .{logger.redactedPath(path)});
    return parsed;
}
