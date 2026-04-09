const std = @import("std");
const flag = @import("../flags.zig");
const auth_mod = @import("../auth.zig");
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
        error.MissingValue => {
            try stderr.print("{s}{s}{s}Error:{s} {s} requires a value\n", .{ P, Color.bold, Color.red, Color.reset, err_ctx.flag.? });
            return;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer result.deinit(allocator);

    // Resolve workspace from config
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    const binding = ws_config.resolveWorkspace(allocator, cwd_path) catch {
        try stderr.print("{s}{s}{s}Error:{s} No workspace bound to this directory. Run {s}clumsies init{s} first.\n", .{ P, Color.bold, Color.red, Color.reset, Color.cyan, Color.reset });
        return;
    };
    const ws_id = binding.ws_id;

    // Load auth
    const auth_info = auth_mod.loadAuth(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Not logged in. Run {s}clumsies login{s} first.\n", .{ P, Color.bold, Color.red, Color.reset, Color.cyan, Color.reset });
        return;
    };

    var client = HubClient.init(allocator, auth_info.hub_url, auth_info.access_token);

    // GET /api/workspaces/{ws_id}/manifest
    const manifest_path = try std.fmt.allocPrint(allocator, "/api/workspaces/{s}/manifest", .{ws_id});
    defer allocator.free(manifest_path);

    const manifest_response = try client.get(manifest_path);
    if (manifest_response.status != .ok) {
        try stderr.print("{s}{s}{s}Error:{s} Failed to fetch manifest (HTTP {d})\n", .{ P, Color.bold, Color.red, Color.reset, @intFromEnum(manifest_response.status) });
        return;
    }

    // Parse manifest as dynamic JSON
    const manifest_parsed = std.json.parseFromSlice(std.json.Value, allocator, manifest_response.body, .{}) catch {
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

    // Sync prompts — write to rule/ and workflow/ subdirectories
    // Manifest prompts are keyed by prompt_id, but canonical_name determines the path
    var prompt_count: usize = 0;
    if (manifest.object.get("prompts")) |prompts_val| {
        if (prompts_val == .object) {
            var iter = prompts_val.object.iterator();
            while (iter.next()) |entry| {
                const prompt_id = entry.key_ptr.*;
                // Fetch prompt content by ID
                const api_path = try std.fmt.allocPrint(allocator, "/api/org/library/prompt?name={s}", .{prompt_id});
                defer allocator.free(api_path);

                const response = client.get(api_path) catch continue;
                if (response.status != .ok) continue;

                // Parse to get canonical_name and kind for directory placement
                const prompt_parsed = std.json.parseFromSlice(std.json.Value, allocator, response.body, .{}) catch continue;
                defer prompt_parsed.deinit();

                const prompt_obj = prompt_parsed.value;
                const canonical_name = if (prompt_obj.object.get("canonical_name")) |v| switch (v) {
                    .string => |s| s,
                    else => continue,
                } else continue;

                // Fetch actual content
                const content_path = try std.fmt.allocPrint(allocator, "/api/org/library/prompt/content?name={s}", .{canonical_name});
                defer allocator.free(content_path);

                const content_response = client.get(content_path) catch continue;
                if (content_response.status != .ok) continue;

                // canonical_name is like "rule/coding/STYLE" or "workflow/cmd/COMMIT"
                // Write directly to cache using canonical_name as the path
                const file_name = try std.fmt.allocPrint(allocator, "{s}.md", .{canonical_name});
                defer allocator.free(file_name);
                writeToCache(allocator, cache_dir, "", file_name, content_response.body) catch continue;
                prompt_count += 1;
            }
        }
    }

    // Sync context files — write to context/ subdirectory
    var context_count: usize = 0;
    if (manifest.object.get("context")) |context_val| {
        if (context_val == .object) {
            var iter = context_val.object.iterator();
            while (iter.next()) |entry| {
                const path = entry.key_ptr.*;
                const api_path = try std.fmt.allocPrint(allocator, "/api/workspaces/{s}/context/file/content?path={s}", .{ ws_id, path });
                defer allocator.free(api_path);

                const response = client.get(api_path) catch continue;
                if (response.status != .ok) continue;

                writeToCache(allocator, cache_dir, "context", path, response.body) catch continue;
                context_count += 1;
            }
        }
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

    try stdout.print("{s}{s}{s}Synced:{s} {d} prompts, {d} context files\n", .{ P, Color.bold, Color.green, Color.reset, prompt_count, context_count });
}

fn ensureDir(path: []const u8) void {
    std.fs.makeDirAbsolute(path) catch {};
}

fn writeToCache(allocator: std.mem.Allocator, ws_cache_dir: []const u8, sub_dir: []const u8, name: []const u8, content: []const u8) !void {
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

fn printHelp(out: *std.Io.Writer) !void {
    try out.print("{s}Usage: {s}clumsies sync{s}\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Sync workspace prompts and context files from Hub to local cache.\n", .{P});
    try out.print("{s}Requires workspace binding (run {s}clumsies init{s} first).\n", .{ P, Color.cyan, Color.reset });
}
