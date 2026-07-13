const std = @import("std");
const flag = @import("../flags.zig");
const auth_mod = @import("../auth.zig");
const ws_config = @import("../workspace_config.zig");
const ServerClient = @import("../server_client.zig").ServerClient;
const styles = @import("../styles.zig");
const workspace_api = @import("clumsies_lib").protocol.workspace_api;
const api_error = @import("clumsies_lib").protocol.api_error;
const sync_cmd = @import("sync_cmd.zig");

const Color = styles.Color;
const P = styles.P;

pub fn run(stdout: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const SPECS = [_]flag.FlagSpec{
        .{ .short = 'c', .long = "create", .kind = .value },
        .{ .short = 'w', .long = "ws-id", .kind = .value },
        .{ .short = 'b', .long = "bundles", .kind = .value },
        .{ .short = 'd', .long = "description", .kind = .value },
    };

    var err_ctx: flag.ErrorContext = .{};
    var result = flag.parse(&SPECS, allocator, args, &err_ctx) catch |err| switch (err) {
        error.HelpRequested => {
            try printHelp(stdout);
            return;
        },
        error.UnknownFlag => {
            try stderr.print("{s}{s}{s}Error:{s} Unknown flag: {s}\n", .{ P, Color.bold, Color.red, Color.reset, err_ctx.flag.? });
            try printHelp(stderr);
            return;
        },
        error.UnexpectedArgument => {
            try stderr.print("{s}{s}{s}Error:{s} Unexpected argument: {s}\n", .{ P, Color.bold, Color.red, Color.reset, err_ctx.flag.? });
            try printHelp(stderr);
            return;
        },
        error.MissingValue => {
            try stderr.print("{s}{s}{s}Error:{s} {s} requires a value\n", .{ P, Color.bold, Color.red, Color.reset, err_ctx.flag.? });
            return;
        },
    };
    defer result.deinit(allocator);

    const create_name = result.value(0);
    const ws_id_flag = result.value(1);
    const bundle_ids = parseBundleIdsFlag(allocator, result.value(2)) catch {
        try stderr.print("{s}{s}{s}Error:{s} --bundles must contain one or more comma-separated bundle ids\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(bundle_ids);
    const description = result.value(3);

    if (create_name == null and ws_id_flag == null) {
        try stderr.print("{s}{s}{s}Error:{s} Either --create <name> or --ws-id <id> is required\n", .{ P, Color.bold, Color.red, Color.reset });
        try printHelp(stderr);
        return;
    }
    if (create_name != null and description == null) {
        try stderr.print("{s}{s}{s}Error:{s} --description is required with --create\n", .{ P, Color.bold, Color.red, Color.reset });
        try printHelp(stderr);
        return;
    }
    if (ws_id_flag != null and bundle_ids.len > 0) {
        try stderr.print("{s}{s}{s}Error:{s} --bundles can only be used with --create\n", .{ P, Color.bold, Color.red, Color.reset });
        try printHelp(stderr);
        return;
    }

    // Load auth (must be logged in)
    const auth_info = auth_mod.loadAuth(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Not logged in. Run {s}clumsies login{s} first.\n", .{ P, Color.bold, Color.red, Color.reset, Color.cyan, Color.reset });
        return;
    };
    defer auth_info.deinit(allocator);

    var server = ServerClient.init(allocator, auth_info.server_url, auth_info.access_token);
    defer server.deinit();
    try server.enableRefresh(auth_info.refresh_token, auth_info.username, auth_mod.persistRotatedTokens);

    var ws_id_owned: ?[]const u8 = null;
    defer if (ws_id_owned) |o| allocator.free(o);
    var ws_name_owned: ?[]const u8 = null;
    defer if (ws_name_owned) |o| allocator.free(o);

    var ws_id: []const u8 = undefined;
    var ws_name: []const u8 = undefined;

    if (create_name) |name| {
        // POST /api/workspaces to create a new workspace
        const request = workspace_api.CreateWorkspaceRequest{ .name = name, .description = description.?, .bundle_ids = bundle_ids };
        const body = std.json.Stringify.valueAlloc(
            allocator,
            request,
            .{ .emit_null_optional_fields = false },
        ) catch return error.OutOfMemory;
        defer allocator.free(body);

        const response = try server.post("/api/workspaces", body);
        defer response.deinit();
        if (response.status != .ok and response.status != .created) {
            try reportApiError(stderr, allocator, "Failed to create workspace", response.status, response.body);
            return;
        }

        const parsed = parseCreatedWorkspace(allocator, response.body) catch {
            try stderr.print("{s}{s}{s}Error:{s} Failed to parse workspace response\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };
        defer parsed.deinit();

        ws_id_owned = try allocator.dupe(u8, parsed.value.ws_id);
        ws_id = ws_id_owned.?;
        ws_name_owned = try allocator.dupe(u8, parsed.value.name);
        ws_name = ws_name_owned.?;
    } else if (ws_id_flag) |id| {
        // GET /api/workspaces/{ws_id} to verify access
        const path = try std.fmt.allocPrint(allocator, "/api/workspaces/{s}", .{id});
        defer allocator.free(path);

        const response = try server.get(path);
        defer response.deinit();
        if (response.status != .ok) {
            try reportApiError(stderr, allocator, "Cannot access workspace", response.status, response.body);
            return;
        }

        const parsed = parseCreatedWorkspace(allocator, response.body) catch {
            try stderr.print("{s}{s}{s}Error:{s} Failed to parse workspace response\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };
        defer parsed.deinit();

        ws_id = id;
        ws_name_owned = try allocator.dupe(u8, parsed.value.name);
        ws_name = ws_name_owned.?;
    }

    // Add workspace binding to ~/.clumsies/config.toml
    const cwd_path = try std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(cwd_path);

    ws_config.addWorkspace(allocator, auth_info.server_url, ws_name, ws_id, cwd_path) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to save workspace config\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    // Create cache directory
    const cache_path = try ws_config.getCachePath(allocator, ws_id);
    defer allocator.free(cache_path);

    std.Io.Dir.createDirAbsolute(std.Options.debug_io, cache_path, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) {
            // Create parent dirs
            const base_path = try auth_mod.getBasePath(allocator);
            defer allocator.free(base_path);
            std.Io.Dir.createDirAbsolute(std.Options.debug_io, base_path, .default_dir) catch {};
            const ws_dir = try std.fs.path.join(allocator, &.{ base_path, "workspaces" });
            defer allocator.free(ws_dir);
            std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws_dir, .default_dir) catch {};
            const local_ws_dir = try ws_config.getWsDir(allocator, ws_id);
            defer allocator.free(local_ws_dir);
            std.Io.Dir.createDirAbsolute(std.Options.debug_io, local_ws_dir, .default_dir) catch {};
            std.Io.Dir.createDirAbsolute(std.Options.debug_io, cache_path, .default_dir) catch {};
        }
    };

    try stdout.print("{s}{s}{s}Workspace {s} bound to current directory (ws_id: {s}){s}\n", .{ P, Color.bold, Color.green, ws_name, ws_id, Color.reset });
    const summary = sync_cmd.materializeWorkspace(allocator, &server, ws_id, .{ .errors = stderr }) catch |err| {
        try stderr.print("{s}{s}{s}Warning:{s} Initial sync failed: {s}. Run {s}clumsies sync{s} after Server/auth is fixed.\n", .{ P, Color.bold, Color.orange, Color.reset, @errorName(err), Color.cyan, Color.reset });
        return;
    };
    try stdout.print("{s}{s}{s}Synced:{s} {d} rules, {d} context files into local cache\n", .{ P, Color.bold, Color.green, Color.reset, summary.rules_total, summary.context_total });
}

fn parseCreatedWorkspace(
    allocator: std.mem.Allocator,
    body: []const u8,
) !std.json.Parsed(workspace_api.CreateWorkspaceResponse) {
    return std.json.parseFromSlice(
        workspace_api.CreateWorkspaceResponse,
        allocator,
        body,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    );
}

fn reportApiError(
    stderr: *std.Io.Writer,
    allocator: std.mem.Allocator,
    context: []const u8,
    status: std.http.Status,
    body: []const u8,
) !void {
    const parsed = std.json.parseFromSlice(
        api_error.ApiErrorEnvelope,
        allocator,
        body,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch {
        try stderr.print("{s}{s}{s}Error:{s} {s} (HTTP {d})\n", .{
            P, Color.bold, Color.red, Color.reset, context, @intFromEnum(status),
        });
        if (body.len > 0) {
            try stderr.print("{s}{s}\n", .{ P, body });
        }
        return;
    };
    defer parsed.deinit();
    try stderr.print("{s}{s}{s}Error:{s} {s}: {s} ({s})\n", .{
        P,
        Color.bold,
        Color.red,
        Color.reset,
        context,
        parsed.value.@"error".message,
        parsed.value.@"error".code,
    });
}

fn printHelp(out: *std.Io.Writer) !void {
    try out.print("{s}Usage: {s}clumsies init [--create <name> --description <text> | --ws-id <id>] [--bundles <id[,id...]>]{s}\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Initialize a workspace binding in the current directory.\n", .{P});
    try out.print("{s}Flags:\n", .{P});
    try out.print("{s}  {s}--create <name>{s}     Create a new workspace with this name\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}--description <text>{s} Workspace description (with --create)\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}--ws-id <id>{s}        Bind to an existing workspace by ID\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}--bundles <ids>{s}      Import bundle ids when creating a workspace\n", .{ P, Color.cyan, Color.reset });
}

fn parseBundleIdsFlag(allocator: std.mem.Allocator, raw_opt: ?[]const u8) ![]const []const u8 {
    const raw = raw_opt orelse return allocator.alloc([]const u8, 0);
    var ids: std.ArrayList([]const u8) = .empty;
    errdefer ids.deinit(allocator);

    var iter = std.mem.splitScalar(u8, raw, ',');
    while (iter.next()) |part| {
        const id = std.mem.trim(u8, part, " \t\r\n");
        if (id.len == 0) return error.InvalidBundleIds;
        try ids.append(allocator, id);
    }
    if (ids.items.len == 0) return error.InvalidBundleIds;
    return ids.toOwnedSlice(allocator);
}

test "parseCreatedWorkspace reads workspace description" {
    const body =
        \\{"ws_id":"ws-123","name":"clumsiesws","description":"Primary workspace","revision":4}
    ;

    const parsed = try parseCreatedWorkspace(std.testing.allocator, body);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("ws-123", parsed.value.ws_id);
    try std.testing.expectEqualStrings("clumsiesws", parsed.value.name);
    try std.testing.expectEqualStrings("Primary workspace", parsed.value.description);
    try std.testing.expectEqual(@as(i32, 4), parsed.value.revision);
}
