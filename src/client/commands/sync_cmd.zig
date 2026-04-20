const std = @import("std");
const flag = @import("../flags.zig");
const library_api = @import("clumsies_lib").protocol.library_api;
const workspace_api = @import("clumsies_lib").protocol.workspace_api;
const path_util = @import("clumsies_lib").util.path_util;
const auth_mod = @import("../auth.zig");
const drafts_mod = @import("../drafts.zig");
const ws_config = @import("../workspace_config.zig");
const HubClient = @import("../hub_client.zig").HubClient;
const styles = @import("../styles.zig");

const Color = styles.Color;
const P = styles.P;

pub fn run(stdout: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const SPECS = [_]flag.FlagSpec{};

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

    // Resolve workspace from config
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    const binding = ws_config.resolveWorkspace(allocator, cwd_path) catch {
        try stderr.print("{s}{s}{s}Error:{s} No workspace bound to this directory. Run {s}clumsies init{s} first.\n", .{ P, Color.bold, Color.red, Color.reset, Color.cyan, Color.reset });
        return;
    };
    defer allocator.free(binding.ws_id);
    defer allocator.free(binding.name);
    const ws_id = binding.ws_id;

    // Load auth
    const auth_info = auth_mod.loadAuth(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Not logged in. Run {s}clumsies login{s} first.\n", .{ P, Color.bold, Color.red, Color.reset, Color.cyan, Color.reset });
        return;
    };
    defer auth_info.deinit(allocator);

    var hub = HubClient.init(allocator, auth_info.hub_url, auth_info.access_token);

    // GET /api/workspaces/{ws_id}/manifest
    const manifest_path = try std.fmt.allocPrint(allocator, "/api/workspaces/{s}/manifest", .{ws_id});
    defer allocator.free(manifest_path);

    const manifest_response = try hub.get(manifest_path);
    defer manifest_response.deinit();
    if (manifest_response.status != .ok) {
        try stderr.print("{s}{s}{s}Error:{s} Failed to fetch manifest (HTTP {d})\n", .{ P, Color.bold, Color.red, Color.reset, @intFromEnum(manifest_response.status) });
        return;
    }

    const manifest_parsed = std.json.parseFromSlice(workspace_api.WorkspaceManifestResponse, allocator, manifest_response.body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to parse manifest\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer manifest_parsed.deinit();
    const manifest = manifest_parsed.value;

    // Set up cache directory
    const cache_dir = try ws_config.getCachePath(allocator, ws_id);
    defer allocator.free(cache_dir);

    // Ensure directory hierarchy
    const base_path = try auth_mod.getBasePath(allocator);
    defer allocator.free(base_path);
    ensureDir(base_path);
    const workspaces_dir = try std.fs.path.join(allocator, &.{ base_path, "workspaces" });
    defer allocator.free(workspaces_dir);
    ensureDir(workspaces_dir);
    const ws_dir = try std.fs.path.join(allocator, &.{ workspaces_dir, ws_id });
    defer allocator.free(ws_dir);
    ensureDir(ws_dir);
    ensureDir(cache_dir);

    var prompt_count: usize = 0;
    for (manifest.prompts.items) |entry| {
        const prompt_id = entry.key;
        const prompt_path = entry.value.path;

        const encoded_prompt_id = try percentEncode(allocator, prompt_id);
        defer allocator.free(encoded_prompt_id);
        const content_api_path = try std.fmt.allocPrint(allocator, "/api/org/library/prompt/content?prompt_id={s}", .{encoded_prompt_id});
        defer allocator.free(content_api_path);

        const content_response = hub.get(content_api_path) catch continue;
        defer content_response.deinit();
        if (content_response.status != .ok) continue;

        const content_parsed = std.json.parseFromSlice(library_api.PromptContentResponse, allocator, content_response.body, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch continue;
        defer content_parsed.deinit();

        writeToCache(allocator, cache_dir, "", prompt_path, content_parsed.value.body) catch continue;
        prompt_count += 1;
    }

    var context_count: usize = 0;
    for (manifest.context.items) |entry| {
        const ctx_path = entry.value.path;

        const encoded_path = try percentEncode(allocator, ctx_path);
        defer allocator.free(encoded_path);
        const api_path = try std.fmt.allocPrint(allocator, "/api/workspaces/{s}/context/file/content?path={s}", .{ ws_id, encoded_path });
        defer allocator.free(api_path);

        const response = hub.get(api_path) catch continue;
        defer response.deinit();
        if (response.status != .ok) continue;

        writeToCache(allocator, cache_dir, "context", ctx_path, response.body) catch continue;
        context_count += 1;
    }

    // Write manifest.json to cache
    {
        const manifest_file_path = try std.fs.path.join(allocator, &.{ ws_dir, "manifest.json" });
        defer allocator.free(manifest_file_path);

        const file = try std.fs.createFileAbsolute(manifest_file_path, .{ .truncate = true });
        defer file.close();

        var buf: [8192]u8 = undefined;
        var w = std.fs.File.Writer.init(file, &buf);
        try w.interface.writeAll(manifest_response.body);
        try w.interface.flush();
    }

    const reconcile = drafts_mod.reconcileDrafts(allocator, ws_dir, cache_dir) catch drafts_mod.ReconcileSummary{};
    if (reconcile.conflicted > 0) {
        try stdout.print("{s}{s}{s}Synced:{s} {d} prompts, {d} context files, {d} drafts flagged conflicted\n", .{ P, Color.bold, Color.green, Color.reset, prompt_count, context_count, reconcile.conflicted });
    } else {
        try stdout.print("{s}{s}{s}Synced:{s} {d} prompts, {d} context files\n", .{ P, Color.bold, Color.green, Color.reset, prompt_count, context_count });
    }
}

fn ensureDir(path: []const u8) void {
    std.fs.makeDirAbsolute(path) catch |err| {
        if (err != error.PathAlreadyExists) {
            std.log.warn("failed to create directory {s}: {}", .{ path, err });
        }
    };
}

fn writeToCache(allocator: std.mem.Allocator, ws_cache_dir: []const u8, sub_dir: []const u8, name: []const u8, content: []const u8) !void {
    if (!path_util.isSafeRelative(name)) return error.UnsafePath;
    const dir_path = try std.fs.path.join(allocator, &.{ ws_cache_dir, sub_dir });
    defer allocator.free(dir_path);
    ensureDir(dir_path);

    // Handle nested paths by creating parent directories
    const file_path = try std.fs.path.join(allocator, &.{ dir_path, name });
    defer allocator.free(file_path);

    // Ensure parent directory exists for nested names like "group/file.md"
    if (std.fs.path.dirname(file_path)) |parent| {
        const parent_owned = try allocator.dupe(u8, parent);
        defer allocator.free(parent_owned);
        std.fs.makeDirAbsolute(parent_owned) catch {};
    }

    const file = try std.fs.createFileAbsolute(file_path, .{ .truncate = true });
    defer file.close();

    var buf: [8192]u8 = undefined;
    var w = std.fs.File.Writer.init(file, &buf);
    try w.interface.writeAll(content);
    try w.interface.flush();
}

fn percentEncode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    const HEX = "0123456789ABCDEF";
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (input) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try buf.append(allocator, byte);
        } else {
            try buf.append(allocator, '%');
            try buf.append(allocator, HEX[byte >> 4]);
            try buf.append(allocator, HEX[byte & 0x0f]);
        }
    }
    return buf.toOwnedSlice(allocator);
}

fn printHelp(out: *std.Io.Writer) !void {
    try out.print("{s}Usage: {s}clumsies sync{s}\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Sync workspace prompts and context files from Hub to local cache.\n", .{P});
    try out.print("{s}Requires workspace binding (run {s}clumsies init{s} first).\n", .{ P, Color.cyan, Color.reset });
}

const testing = std.testing;

test "percentEncode encodes special characters" {
    const allocator = testing.allocator;
    const result = try percentEncode(allocator, "hello world/foo&bar");
    defer allocator.free(result);
    try testing.expectEqualStrings("hello%20world%2Ffoo%26bar", result);
}

test "percentEncode passes unreserved characters" {
    const allocator = testing.allocator;
    const result = try percentEncode(allocator, "hello-world_v1.0~beta");
    defer allocator.free(result);
    try testing.expectEqualStrings("hello-world_v1.0~beta", result);
}
