const std = @import("std");
const toml = @import("toml");
const auth = @import("auth.zig");

pub const WorkspaceBinding = struct {
    ws_id: []const u8,
    name: []const u8,
};

const Config = struct {
    server: struct { url: []const u8 },
    workspaces: []const WorkspaceEntry,
};

const WorkspaceEntry = struct {
    name: []const u8,
    ws_id: []const u8,
    paths: []const []const u8,
};

/// Find the workspace that contains the given directory path.
pub fn resolveWorkspace(allocator: std.mem.Allocator, cwd: []const u8) !WorkspaceBinding {
    const cfg = try loadConfig(allocator);

    for (cfg.workspaces) |ws| {
        for (ws.paths) |p| {
            if (std.mem.startsWith(u8, cwd, p) and (cwd.len == p.len or cwd[p.len] == std.fs.path.sep)) {
                return .{
                    .ws_id = ws.ws_id,
                    .name = ws.name,
                };
            }
        }
    }

    return error.NoWorkspaceFound;
}

/// Get the cache directory for a workspace.
pub fn getCachePath(allocator: std.mem.Allocator, ws_id: []const u8) ![]const u8 {
    const base = try auth.getBasePath(allocator);
    defer allocator.free(base);
    return std.fs.path.join(allocator, &.{ base, "workspaces", ws_id, "cache" });
}

/// Add a workspace binding to config.toml.
pub fn addWorkspace(allocator: std.mem.Allocator, server_url: []const u8, name: []const u8, ws_id: []const u8, path: []const u8) !void {
    const base = try auth.getBasePath(allocator);
    defer allocator.free(base);
    const config_path = try std.fs.path.join(allocator, &.{ base, "config.toml" });
    defer allocator.free(config_path);

    std.fs.makeDirAbsolute(base) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Read existing config to preserve other workspaces
    var existing_workspaces: std.ArrayList(TomlWorkspaceOut) = .empty;
    defer existing_workspaces.deinit(allocator);
    var existing_server_url: []const u8 = server_url;

    if (loadConfig(allocator)) |cfg| {
        existing_server_url = cfg.server.url;
        for (cfg.workspaces) |ws| {
            if (std.mem.eql(u8, ws.ws_id, ws_id)) continue;
            try existing_workspaces.append(allocator, .{
                .name = ws.name,
                .ws_id = ws.ws_id,
                .paths = ws.paths,
            });
        }
    } else |_| {}

    // Write config.toml
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try appendLine(allocator, &buf, "[server]");
    try appendKv(allocator, &buf, "url", existing_server_url);
    try appendLine(allocator, &buf, "");

    // Write existing workspaces
    for (existing_workspaces.items) |ws| {
        try writeWorkspaceBlock(allocator, &buf, ws.name, ws.ws_id, ws.paths);
    }

    // Write new workspace
    const path_arr = [_][]const u8{path};
    try writeWorkspaceBlock(allocator, &buf, name, ws_id, &path_arr);

    const file = try std.fs.createFileAbsolute(config_path, .{ .truncate = true });
    defer file.close();
    _ = try file.write(buf.items);
}

fn loadConfig(allocator: std.mem.Allocator) !Config {
    const base = try auth.getBasePath(allocator);
    defer allocator.free(base);
    const config_path = try std.fs.path.join(allocator, &.{ base, "config.toml" });
    defer allocator.free(config_path);

    const file = std.fs.openFileAbsolute(config_path, .{}) catch {
        return error.NoConfigFound;
    };
    defer file.close();

    var buf: [64 * 1024]u8 = undefined;
    const n = file.read(&buf) catch return error.NoConfigFound;

    var parser = toml.Parser(Config).init(allocator);
    defer parser.deinit();

    const result = parser.parseString(buf[0..n]) catch return error.NoConfigFound;
    return result.value;
}

const TomlWorkspaceOut = struct {
    name: []const u8,
    ws_id: []const u8,
    paths: []const []const u8,
};

fn writeWorkspaceBlock(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), name: []const u8, ws_id: []const u8, paths: []const []const u8) !void {
    try appendLine(allocator, buf, "[[workspaces]]");
    try appendKv(allocator, buf, "name", name);
    try appendKv(allocator, buf, "ws_id", ws_id);

    try buf.appendSlice(allocator, "paths = [\n");
    for (paths) |p| {
        try buf.appendSlice(allocator, "  \"");
        try appendTomlEscaped(allocator, buf, p);
        try buf.appendSlice(allocator, "\",\n");
    }
    try buf.appendSlice(allocator, "]\n\n");
}

fn appendLine(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), line: []const u8) !void {
    try buf.appendSlice(allocator, line);
    try buf.append(allocator, '\n');
}

fn appendTomlEscaped(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), value: []const u8) !void {
    for (value) |byte| {
        switch (byte) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, byte),
        }
    }
}

fn appendKv(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), key: []const u8, value: []const u8) !void {
    try buf.appendSlice(allocator, key);
    try buf.appendSlice(allocator, " = \"");
    try appendTomlEscaped(allocator, buf, value);
    try buf.appendSlice(allocator, "\"\n");
}

const testing = std.testing;

test "appendTomlEscaped handles special characters" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try appendTomlEscaped(testing.allocator, &buf, "hello \"world\" \\ \n");
    try testing.expectEqualStrings("hello \\\"world\\\" \\\\ \\n", buf.items);
}

test "appendTomlEscaped passes plain text" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try appendTomlEscaped(testing.allocator, &buf, "/home/user/workspace");
    try testing.expectEqualStrings("/home/user/workspace", buf.items);
}

test "pathMatchBoundary" {
    // Simulate the path matching logic from resolveWorkspace
    const match = struct {
        fn check(cwd: []const u8, p: []const u8) bool {
            return std.mem.startsWith(u8, cwd, p) and (cwd.len == p.len or cwd[p.len] == std.fs.path.sep);
        }
    }.check;

    try testing.expect(match("/home/me/ws", "/home/me/ws"));
    try testing.expect(match("/home/me/ws/sub", "/home/me/ws"));
    try testing.expect(!match("/home/me/ws2", "/home/me/ws"));
    try testing.expect(!match("/home/me/ws2/sub", "/home/me/ws"));
}
