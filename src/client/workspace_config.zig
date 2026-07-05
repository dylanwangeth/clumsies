//! Workspace binding resolution. Reads ~/.clumsies/config.toml to find which workspace owns a
//! given filesystem path. The MCP server uses this at startup to determine which workspace's
//! rules and context to serve.
const std = @import("std");
const toml = @import("toml");
const auth = @import("auth.zig");

pub const WorkspaceBinding = struct {
    ws_id: []const u8,
    name: []const u8,
};

pub const WorkspaceListEntry = struct {
    ws_id: []const u8,
    name: []const u8,
};

pub const WorkspacePaths = struct {
    paths: []const []const u8,

    pub fn deinit(self: WorkspacePaths, allocator: std.mem.Allocator) void {
        for (self.paths) |path| allocator.free(path);
        allocator.free(self.paths);
    }
};

const WorkspaceMatch = struct {
    ws: *const WorkspaceEntry,
    path: []const u8,
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
    var parsed = try loadConfig(allocator);
    defer parsed.deinit();

    const match = findBestWorkspaceMatch(parsed.value.workspaces, cwd) orelse return error.NoWorkspaceFound;

    return .{
        .ws_id = try allocator.dupe(u8, match.ws.ws_id),
        .name = try allocator.dupe(u8, match.ws.name),
    };
}

/// Return every workspace bound in ~/.clumsies/config.toml.
///
/// Caller owns the returned slice and each entry's `ws_id` and `name`.
/// Use `deinitWorkspaceList` when the allocator is not an arena with a
/// bounded lifetime.
pub fn listWorkspaces(allocator: std.mem.Allocator) ![]WorkspaceListEntry {
    var parsed = try loadConfig(allocator);
    defer parsed.deinit();

    var list: std.ArrayList(WorkspaceListEntry) = .empty;
    errdefer {
        for (list.items) |entry| {
            allocator.free(entry.ws_id);
            allocator.free(entry.name);
        }
        list.deinit(allocator);
    }

    for (parsed.value.workspaces) |ws| {
        {
            const ws_id = try allocator.dupe(u8, ws.ws_id);
            errdefer allocator.free(ws_id);
            const name = try allocator.dupe(u8, ws.name);
            errdefer allocator.free(name);
            try list.append(allocator, .{
                .ws_id = ws_id,
                .name = name,
            });
        }
    }

    return try list.toOwnedSlice(allocator);
}

pub fn loadServerUrl(allocator: std.mem.Allocator) ![]const u8 {
    var parsed = try loadConfig(allocator);
    defer parsed.deinit();

    return try allocator.dupe(u8, parsed.value.server.url);
}

pub fn deinitWorkspaceList(allocator: std.mem.Allocator, list: []WorkspaceListEntry) void {
    for (list) |entry| {
        allocator.free(entry.ws_id);
        allocator.free(entry.name);
    }
    allocator.free(list);
}

pub fn listWorkspacePaths(allocator: std.mem.Allocator, ws_id: []const u8) !WorkspacePaths {
    var parsed = try loadConfig(allocator);
    defer parsed.deinit();

    for (parsed.value.workspaces) |ws| {
        if (!std.mem.eql(u8, ws.ws_id, ws_id)) continue;
        var paths: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (paths.items) |path| allocator.free(path);
            paths.deinit(allocator);
        }
        for (ws.paths) |path| {
            try paths.append(allocator, try allocator.dupe(u8, path));
        }
        return .{ .paths = try paths.toOwnedSlice(allocator) };
    }

    return .{ .paths = try allocator.alloc([]const u8, 0) };
}

/// Resolve the current workspace root for local client operations.
///
/// Returns the matched bound workspace path when the current directory is
/// inside a Clumsies workspace, otherwise null.
pub fn resolveWorkspaceRoot(allocator: std.mem.Allocator, cwd: []const u8) !?[]const u8 {
    var parsed = loadConfig(allocator) catch return null;
    defer parsed.deinit();

    const match = findBestWorkspaceMatch(parsed.value.workspaces, cwd) orelse return null;
    const workspace_root = try allocator.dupe(u8, match.path);
    return workspace_root;
}

/// Resolve the current workspace root for the current process working directory.
pub fn resolveCurrentWorkspaceRoot(allocator: std.mem.Allocator) !?[]const u8 {
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(cwd);

    return try resolveWorkspaceRoot(allocator, cwd);
}

/// Get the workspace directory for a workspace: ~/.clumsies/workspaces/{name}
pub fn getWsDir(allocator: std.mem.Allocator, ws_id: []const u8) ![]const u8 {
    const base = try auth.getBasePath(allocator);
    defer allocator.free(base);
    const parent = try std.fs.path.join(allocator, &.{ base, "workspaces" });
    defer allocator.free(parent);
    const dir_name = try workspaceDirName(allocator, ws_id);
    defer allocator.free(dir_name);
    const ws_dir = try std.fs.path.join(allocator, &.{ parent, dir_name });
    errdefer allocator.free(ws_dir);
    try migrateWorkspaceDir(allocator, parent, ws_id, ws_dir);
    return ws_dir;
}

/// Get the cache directory for a workspace: ~/.clumsies/workspaces/{name}/cache
pub fn getCachePath(allocator: std.mem.Allocator, ws_id: []const u8) ![]const u8 {
    const ws_dir = try getWsDir(allocator, ws_id);
    defer allocator.free(ws_dir);
    return std.fs.path.join(allocator, &.{ ws_dir, "cache" });
}

/// Add a workspace binding to config.toml.
pub fn addWorkspace(allocator: std.mem.Allocator, server_url: []const u8, name: []const u8, ws_id: []const u8, path: []const u8) !void {
    const base = try auth.getBasePath(allocator);
    defer allocator.free(base);
    const config_path = try std.fs.path.join(allocator, &.{ base, "config.toml" });
    defer allocator.free(config_path);

    std.Io.Dir.createDirAbsolute(std.Options.debug_io, base, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Read existing config to preserve other workspaces and append to this
    // workspace's path list without duplicating the same directory. A local
    // path can only resolve to one workspace, so binding it to this workspace
    // removes it from any previous owner.
    var existing_workspaces: std.ArrayList(TomlWorkspaceOut) = .empty;
    defer existing_workspaces.deinit(allocator);
    var existing_server_url: []const u8 = server_url;
    var merged_paths: std.ArrayList([]const u8) = .empty;
    defer merged_paths.deinit(allocator);
    var owned_path_slices: std.ArrayList([]const []const u8) = .empty;
    defer {
        for (owned_path_slices.items) |paths| allocator.free(paths);
        owned_path_slices.deinit(allocator);
    }

    var parsed_config: ?ParsedConfig = null;
    defer if (parsed_config) |*pc| pc.deinit();

    if (loadConfig(allocator)) |parsed| {
        parsed_config = parsed;
        existing_server_url = parsed_config.?.value.server.url;
        for (parsed_config.?.value.workspaces) |ws| {
            if (std.mem.eql(u8, ws.ws_id, ws_id)) {
                for (ws.paths) |existing_path| {
                    if (!containsPath(merged_paths.items, existing_path)) {
                        try merged_paths.append(allocator, existing_path);
                    }
                }
                continue;
            }
            var filtered_paths: std.ArrayList([]const u8) = .empty;
            defer filtered_paths.deinit(allocator);
            for (ws.paths) |existing_path| {
                if (std.mem.eql(u8, existing_path, path)) continue;
                try filtered_paths.append(allocator, existing_path);
            }
            if (filtered_paths.items.len == 0) continue;
            const filtered_owned = try filtered_paths.toOwnedSlice(allocator);
            try owned_path_slices.append(allocator, filtered_owned);
            try existing_workspaces.append(allocator, .{
                .name = ws.name,
                .ws_id = ws.ws_id,
                .paths = filtered_owned,
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

    if (!containsPath(merged_paths.items, path)) {
        try merged_paths.append(allocator, path);
    }

    try writeWorkspaceBlock(allocator, &buf, name, ws_id, merged_paths.items);

    const file = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, config_path, .{ .truncate = true });
    defer file.close(std.Options.debug_io);
    var write_buf: [4096]u8 = undefined;
    var writer = std.Io.File.Writer.init(file, std.Options.debug_io, &write_buf);
    try writer.interface.writeAll(buf.items);
    try writer.interface.flush();
}

/// Remove a workspace binding from ~/.clumsies/config.toml.
///
/// Hub owns the workspace record; this only cleans local path bindings so stale
/// deleted workspaces cannot keep resolving MCP/CLI calls from the current dir.
pub fn removeWorkspace(allocator: std.mem.Allocator, ws_id: []const u8) !void {
    const base = try auth.getBasePath(allocator);
    defer allocator.free(base);
    const config_path = try std.fs.path.join(allocator, &.{ base, "config.toml" });
    defer allocator.free(config_path);
    const local_ws_dir = getWsDir(allocator, ws_id) catch null;
    defer if (local_ws_dir) |path| allocator.free(path);

    var existing_workspaces: std.ArrayList(TomlWorkspaceOut) = .empty;
    defer existing_workspaces.deinit(allocator);
    var existing_server_url: []const u8 = "";

    var parsed_config: ?ParsedConfig = null;
    defer if (parsed_config) |*pc| pc.deinit();

    if (loadConfig(allocator)) |parsed| {
        parsed_config = parsed;
        existing_server_url = parsed_config.?.value.server.url;
        for (parsed_config.?.value.workspaces) |ws| {
            if (std.mem.eql(u8, ws.ws_id, ws_id)) continue;
            try existing_workspaces.append(allocator, .{
                .name = ws.name,
                .ws_id = ws.ws_id,
                .paths = ws.paths,
            });
        }
    } else |_| return;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try appendLine(allocator, &buf, "[server]");
    try appendKv(allocator, &buf, "url", existing_server_url);
    try appendLine(allocator, &buf, "");

    for (existing_workspaces.items) |ws| {
        try writeWorkspaceBlock(allocator, &buf, ws.name, ws.ws_id, ws.paths);
    }

    const file = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, config_path, .{ .truncate = true });
    defer file.close(std.Options.debug_io);
    var write_buf: [4096]u8 = undefined;
    var writer = std.Io.File.Writer.init(file, std.Options.debug_io, &write_buf);
    try writer.interface.writeAll(buf.items);
    try writer.interface.flush();

    if (local_ws_dir) |path| {
        try std.Io.Dir.cwd().deleteTree(std.Options.debug_io, path);
    }
}

const ParsedConfig = struct {
    value: Config,
    parsed_result: toml.Parsed(Config),

    pub fn deinit(self: *ParsedConfig) void {
        self.parsed_result.deinit();
    }
};

fn loadConfig(allocator: std.mem.Allocator) !ParsedConfig {
    const base = try auth.getBasePath(allocator);
    defer allocator.free(base);
    const config_path = try std.fs.path.join(allocator, &.{ base, "config.toml" });
    defer allocator.free(config_path);

    const file = std.Io.Dir.openFileAbsolute(std.Options.debug_io, config_path, .{}) catch {
        return error.NoConfigFound;
    };
    defer file.close(std.Options.debug_io);

    var buf: [64 * 1024]u8 = undefined;
    var read_buf: [4096]u8 = undefined;
    var reader = std.Io.File.Reader.init(file, std.Options.debug_io, &read_buf);
    var total: usize = 0;
    while (total < buf.len) {
        const n = reader.interface.readSliceShort(buf[total..]) catch return error.NoConfigFound;
        if (n == 0) break;
        total += n;
    }
    if (total == 0) return error.NoConfigFound;
    const n = total;

    var parser = toml.Parser(Config).init(allocator);
    defer parser.deinit();

    const result = parser.parseString(buf[0..n]) catch return error.NoConfigFound;
    return .{ .value = result.value, .parsed_result = result };
}

const TomlWorkspaceOut = struct {
    name: []const u8,
    ws_id: []const u8,
    paths: []const []const u8,
};

fn findBestWorkspaceMatch(workspaces: []const WorkspaceEntry, cwd: []const u8) ?WorkspaceMatch {
    var best_match: ?WorkspaceMatch = null;
    var best_len: usize = 0;

    for (workspaces) |*ws| {
        for (ws.paths) |path| {
            if (!pathContains(cwd, path)) continue;
            if (path.len <= best_len) continue;

            best_match = .{
                .ws = ws,
                .path = path,
            };
            best_len = path.len;
        }
    }

    return best_match;
}

fn pathContains(cwd: []const u8, path: []const u8) bool {
    return std.mem.startsWith(u8, cwd, path) and (cwd.len == path.len or cwd[path.len] == std.fs.path.sep);
}

fn containsPath(paths: []const []const u8, needle: []const u8) bool {
    for (paths) |path| {
        if (std.mem.eql(u8, path, needle)) return true;
    }
    return false;
}

fn workspaceDirName(allocator: std.mem.Allocator, ws_id: []const u8) ![]const u8 {
    var parsed = loadConfig(allocator) catch return try allocator.dupe(u8, ws_id);
    defer parsed.deinit();

    for (parsed.value.workspaces) |ws| {
        if (!std.mem.eql(u8, ws.ws_id, ws_id)) continue;
        return try pathSafeWorkspaceName(allocator, ws.name, ws_id);
    }

    return try allocator.dupe(u8, ws_id);
}

fn pathSafeWorkspaceName(allocator: std.mem.Allocator, name: []const u8, fallback: []const u8) ![]const u8 {
    if (name.len == 0) return try allocator.dupe(u8, fallback);

    var out = try allocator.alloc(u8, name.len);
    defer allocator.free(out);
    for (name, 0..) |byte, idx| {
        out[idx] = switch (byte) {
            0...31, 127, '/', '\\', ':', '*', '?', '"', '<', '>', '|' => '-',
            else => byte,
        };
    }

    var out_len = out.len;
    while (out_len > 0 and (out[out_len - 1] == ' ' or out[out_len - 1] == '.')) {
        out_len -= 1;
    }

    const trimmed = out[0..out_len];
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, ".") or std.mem.eql(u8, trimmed, "..")) {
        return try allocator.dupe(u8, fallback);
    }
    return try allocator.dupe(u8, trimmed);
}

fn migrateWorkspaceDir(allocator: std.mem.Allocator, parent: []const u8, ws_id: []const u8, target: []const u8) !void {
    const old = try std.fs.path.join(allocator, &.{ parent, ws_id });
    defer allocator.free(old);
    if (std.mem.eql(u8, old, target)) return;

    std.Io.Dir.accessAbsolute(std.Options.debug_io, old, .{}) catch return;
    std.Io.Dir.accessAbsolute(std.Options.debug_io, target, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.Io.Dir.renameAbsolute(old, target, std.Options.debug_io) catch |rename_err| switch (rename_err) {
                error.FileNotFound => {},
                else => return rename_err,
            };
            return;
        },
        else => return,
    };
}

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

test "pathSafeWorkspaceName preserves readable names" {
    const dir_name = try pathSafeWorkspaceName(testing.allocator, "Clumsies Lab", "ws-1");
    defer testing.allocator.free(dir_name);
    try testing.expectEqualStrings("Clumsies Lab", dir_name);
}

test "pathSafeWorkspaceName replaces separators" {
    const dir_name = try pathSafeWorkspaceName(testing.allocator, "team/demo\\app", "ws-1");
    defer testing.allocator.free(dir_name);
    try testing.expectEqualStrings("team-demo-app", dir_name);
}

test "pathSafeWorkspaceName replaces Windows reserved characters" {
    const dir_name = try pathSafeWorkspaceName(testing.allocator, "team:demo*app?name\"<>|", "ws-1");
    defer testing.allocator.free(dir_name);
    try testing.expectEqualStrings("team-demo-app-name----", dir_name);
}

test "pathSafeWorkspaceName trims trailing dots and spaces" {
    const dir_name = try pathSafeWorkspaceName(testing.allocator, "demo. ", "ws-1");
    defer testing.allocator.free(dir_name);
    try testing.expectEqualStrings("demo", dir_name);
}

test "pathSafeWorkspaceName falls back for dot names" {
    const dir_name = try pathSafeWorkspaceName(testing.allocator, "..", "ws-1");
    defer testing.allocator.free(dir_name);
    try testing.expectEqualStrings("ws-1", dir_name);
}

test "pathMatchBoundary" {
    try testing.expect(pathContains("/home/me/ws", "/home/me/ws"));
    try testing.expect(pathContains("/home/me/ws/sub", "/home/me/ws"));
    try testing.expect(!pathContains("/home/me/ws2", "/home/me/ws"));
    try testing.expect(!pathContains("/home/me/ws2/sub", "/home/me/ws"));
}

test "findBestWorkspaceMatch prefers the longest matching path" {
    const workspaces = [_]WorkspaceEntry{
        .{
            .name = "root",
            .ws_id = "ws-root",
            .paths = &.{"/home/me/project"},
        },
        .{
            .name = "nested",
            .ws_id = "ws-nested",
            .paths = &.{"/home/me/project/packages/app"},
        },
    };

    const match = findBestWorkspaceMatch(&workspaces, "/home/me/project/packages/app/src") orelse unreachable;
    try testing.expectEqualStrings("ws-nested", match.ws.ws_id);
    try testing.expectEqualStrings("/home/me/project/packages/app", match.path);
}

test "findBestWorkspaceMatch keeps first workspace for duplicate paths" {
    const workspaces = [_]WorkspaceEntry{
        .{
            .name = "first",
            .ws_id = "ws-first",
            .paths = &.{"/home/me/project"},
        },
        .{
            .name = "second",
            .ws_id = "ws-second",
            .paths = &.{"/home/me/project"},
        },
    };

    const match = findBestWorkspaceMatch(&workspaces, "/home/me/project") orelse unreachable;
    try testing.expectEqualStrings("ws-first", match.ws.ws_id);
}
