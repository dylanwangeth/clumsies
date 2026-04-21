const std = @import("std");
const flag = @import("../flags.zig");
const auth_mod = @import("../auth.zig");
const ws_config = @import("../workspace_config.zig");
const HubClient = @import("../hub_client.zig").HubClient;
const styles = @import("../styles.zig");
const workspace_api = @import("clumsies_lib").protocol.workspace_api;
const api_error = @import("clumsies_lib").protocol.api_error;

const Color = styles.Color;
const P = styles.P;

pub fn run(stdout: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const SPECS = [_]flag.FlagSpec{
        .{ .short = 'c', .long = "create", .kind = .value },
        .{ .short = 'w', .long = "ws-id", .kind = .value },
        .{ .short = 'b', .long = "bundle", .kind = .value },
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
    const bundle_id = result.value(2);

    if (create_name == null and ws_id_flag == null) {
        try stderr.print("{s}{s}{s}Error:{s} Either --create <name> or --ws-id <id> is required\n", .{ P, Color.bold, Color.red, Color.reset });
        try printHelp(stderr);
        return;
    }

    // Load auth (must be logged in)
    const auth_info = auth_mod.loadAuthAndRefresh(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Not logged in. Run {s}clumsies login{s} first.\n", .{ P, Color.bold, Color.red, Color.reset, Color.cyan, Color.reset });
        return;
    };
    defer auth_info.deinit(allocator);

    var hub = HubClient.init(allocator, auth_info.hub_url, auth_info.access_token);
    defer hub.deinit();

    var ws_id_owned: ?[]const u8 = null;
    defer if (ws_id_owned) |o| allocator.free(o);
    var ws_name_owned: ?[]const u8 = null;
    defer if (ws_name_owned) |o| allocator.free(o);

    var ws_id: []const u8 = undefined;
    var ws_name: []const u8 = undefined;

    if (create_name) |name| {
        // POST /api/workspaces to create a new workspace
        const request = workspace_api.CreateWorkspaceRequest{ .name = name, .bundle_id = bundle_id };
        const body = std.json.Stringify.valueAlloc(
            allocator,
            request,
            .{ .emit_null_optional_fields = false },
        ) catch return error.OutOfMemory;
        defer allocator.free(body);

        const response = try hub.post("/api/workspaces", body);
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

        const response = try hub.get(path);
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
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    ws_config.addWorkspace(allocator, auth_info.hub_url, ws_name, ws_id, cwd_path) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to save workspace config\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    // Create cache directory
    const cache_path = try ws_config.getCachePath(allocator, ws_id);
    defer allocator.free(cache_path);

    std.fs.makeDirAbsolute(cache_path) catch |err| {
        if (err != error.PathAlreadyExists) {
            // Create parent dirs
            const base_path = try auth_mod.getBasePath(allocator);
            defer allocator.free(base_path);
            std.fs.makeDirAbsolute(base_path) catch {};
            const ws_dir = try std.fs.path.join(allocator, &.{ base_path, "workspaces" });
            defer allocator.free(ws_dir);
            std.fs.makeDirAbsolute(ws_dir) catch {};
            const ws_id_dir = try std.fs.path.join(allocator, &.{ ws_dir, ws_id });
            defer allocator.free(ws_id_dir);
            std.fs.makeDirAbsolute(ws_id_dir) catch {};
            std.fs.makeDirAbsolute(cache_path) catch {};
        }
    };

    try stdout.print("{s}{s}{s}Workspace {s} bound to current directory (ws_id: {s}){s}\n", .{ P, Color.bold, Color.green, ws_name, ws_id, Color.reset });
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
    try out.print("{s}Usage: {s}clumsies init [--create <name> | --ws-id <id>] [--bundle <bundle_id>]{s}\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Initialize a workspace binding in the current directory.\n", .{P});
    try out.print("{s}Flags:\n", .{P});
    try out.print("{s}  {s}--create <name>{s}     Create a new workspace with this name\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}--ws-id <id>{s}        Bind to an existing workspace by ID\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}--bundle <bundle_id>{s} Associate a bundle (with --create)\n", .{ P, Color.cyan, Color.reset });
}

test "parseCreatedWorkspace ignores added fields from hub responses" {
    const body =
        \\{"ws_id":"ws-123","name":"clumsiesws","revision":4}
    ;

    const parsed = try parseCreatedWorkspace(std.testing.allocator, body);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("ws-123", parsed.value.ws_id);
    try std.testing.expectEqualStrings("clumsiesws", parsed.value.name);
    try std.testing.expectEqual(@as(i32, 4), parsed.value.revision);
}
