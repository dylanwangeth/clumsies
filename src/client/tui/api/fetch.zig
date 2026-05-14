//! Bootstrap and warmup fetch loop for the TUI. This module owns the
//! coarse-grained authenticated fetch that seeds `/api/auth/me` first,
//! then fills slower module metadata such as members, rules, bundles,
//! and org stats without blocking workspace selection.

const std = @import("std");
const HubClient = @import("../../hub_client.zig").HubClient;
const logger = @import("clumsies_lib").logger;
const model = @import("model.zig");
const parse = @import("parse.zig");
const state = @import("state.zig");

const log = std.log.scoped(.tui_api);

const AuthSnapshot = struct {
    hub_url: []const u8,
    access_token: []const u8,

    fn deinit(self: AuthSnapshot, alloc: std.mem.Allocator) void {
        alloc.free(self.hub_url);
        alloc.free(self.access_token);
    }
};

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
    const worker_auth = try dupeAuthSnapshot(token_alloc, hub_url, access_token);
    errdefer worker_auth.deinit(token_alloc);

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

    const thread = std.Thread.spawn(.{}, fetchAll, .{ api_state, worker_auth }) catch |err| {
        log.warn("bootstrap_spawn_failed error={s}", .{@errorName(err)});
        api_state.mutex.lock();
        api_state.bootstrap_inflight = false;
        api_state.mutex.unlock();
        return err;
    };
    try api_state.thread_registry.register(thread, api_state.backing_allocator);
}

pub fn refetchAllAsync(api_state: *state.ApiState) void {
    const auth = beginRefetch(api_state) catch |err| {
        log.warn("bootstrap_refetch_prepare_failed error={s}", .{@errorName(err)});
        return;
    } orelse return;

    const thread = std.Thread.spawn(.{}, fetchAll, .{ api_state, auth }) catch {
        auth.deinit(api_state.backing_allocator);
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
    auth: AuthSnapshot,
) void {
    const hub_url = auth.hub_url;
    const access_token = auth.access_token;
    defer auth.deinit(api_state.backing_allocator);
    defer {
        if (takeQueuedRefetch(api_state)) |next_auth| {
            if (std.Thread.spawn(.{}, fetchAll, .{ api_state, next_auth })) |thread| {
                api_state.thread_registry.register(thread, api_state.backing_allocator) catch {};
            } else |_| {
                next_auth.deinit(api_state.backing_allocator);
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
    client.client_id = api_state.clientIdHex();
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
        defer tokens.deinit(alloc);
        me_resp.deinit();
        me_resp_active = false;

        var retry_client = HubClient.init(alloc, hub_url, tokens.access_token);
        retry_client.client_id = api_state.clientIdHex();
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

    const members = doFetchParse(
        &client,
        alloc,
        "/api/members",
        model.OrgMembersData,
        parse.parseMembers,
    );
    const rules_list = doFetchParse(
        &client,
        alloc,
        "/api/artifact/rules",
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
        "/api/bundles",
        []const model.BundleData,
        parse.parseBundles,
    );

    api_state.mutex.lock();
    if (members) |value| api_state.members = value;
    if (rules_list) |value| api_state.rules = value;
    if (bundles) |value| api_state.bundles = value;
    if (org_stats) |value| api_state.org_stats = value;
    api_state.mutex.unlock();
    log.info("bootstrap_complete members={} rules={} bundles={} org_stats={}", .{
        members != null,
        rules_list != null,
        bundles != null,
        org_stats != null,
    });
}

fn dupeAuthSnapshot(
    alloc: std.mem.Allocator,
    hub_url: []const u8,
    access_token: []const u8,
) !AuthSnapshot {
    const hub_url_copy = try alloc.dupe(u8, hub_url);
    errdefer alloc.free(hub_url_copy);
    const access_copy = try alloc.dupe(u8, access_token);
    return .{
        .hub_url = hub_url_copy,
        .access_token = access_copy,
    };
}

fn beginRefetch(api_state: *state.ApiState) !?AuthSnapshot {
    const alloc = api_state.backing_allocator;
    api_state.mutex.lock();
    defer api_state.mutex.unlock();

    if (api_state.hub_url == null or api_state.username == null or api_state.access_token == null or api_state.refresh_token == null) {
        return null;
    }
    if (api_state.bootstrap_inflight) {
        log.info("bootstrap_refetch_queued", .{});
        api_state.bootstrap_refetch_requested = true;
        return null;
    }

    const auth = try dupeAuthSnapshot(
        alloc,
        api_state.hub_url.?,
        api_state.access_token.?,
    );
    api_state.bootstrap_inflight = true;
    return auth;
}

fn takeQueuedRefetch(api_state: *state.ApiState) ?AuthSnapshot {
    const alloc = api_state.backing_allocator;
    api_state.mutex.lock();
    defer api_state.mutex.unlock();

    if (!api_state.bootstrap_refetch_requested) {
        api_state.bootstrap_inflight = false;
        return null;
    }
    if (api_state.hub_url == null or api_state.username == null or api_state.access_token == null or api_state.refresh_token == null) {
        api_state.bootstrap_refetch_requested = false;
        api_state.bootstrap_inflight = false;
        return null;
    }

    const auth = dupeAuthSnapshot(
        alloc,
        api_state.hub_url.?,
        api_state.access_token.?,
    ) catch {
        api_state.bootstrap_refetch_requested = false;
        api_state.bootstrap_inflight = false;
        return null;
    };
    api_state.bootstrap_refetch_requested = false;
    return auth;
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
