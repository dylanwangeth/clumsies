//! TUI-local preferences. These are client UI state, not Server-synced content.
//! The first preference is the last selected workspace id so the next TUI
//! launch can restore the user's previous workspace when `/api/auth/me`
//! returns a matching workspace in scope.

const std = @import("std");
const auth = @import("../auth.zig");
const model = @import("api/model.zig");

pub const Prefs = struct {
    last_workspace_id: ?[]const u8 = null,
    markdown_viewer_argv: ?[]const []const u8 = null,

    pub fn deinit(self: Prefs, allocator: std.mem.Allocator) void {
        if (self.last_workspace_id) |id| allocator.free(id);
        if (self.markdown_viewer_argv) |argv| {
            for (argv) |arg| allocator.free(arg);
            allocator.free(argv);
        }
    }
};

const PrefsJson = struct {
    last_workspace_id: ?[]const u8 = null,
    markdown_viewer_argv: ?[]const []const u8 = null,
};

pub fn load(allocator: std.mem.Allocator) !Prefs {
    const path = try prefsPath(allocator);
    defer allocator.free(path);

    const file = std.Io.Dir.openFileAbsolute(std.Options.debug_io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer file.close(std.Options.debug_io);

    var read_buf: [4096]u8 = undefined;
    var fr = std.Io.File.Reader.init(file, std.Options.debug_io, &read_buf);
    const body = try fr.interface.allocRemaining(allocator, std.Io.Limit.limited(64 * 1024));
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(PrefsJson, allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    return .{
        .last_workspace_id = if (parsed.value.last_workspace_id) |id| try allocator.dupe(u8, id) else null,
        .markdown_viewer_argv = if (parsed.value.markdown_viewer_argv) |argv| try dupeArgv(allocator, argv) else null,
    };
}

pub fn saveLastWorkspaceId(allocator: std.mem.Allocator, ws_id: []const u8) !void {
    var prefs = load(allocator) catch Prefs{};
    defer prefs.deinit(allocator);
    if (prefs.last_workspace_id) |id| {
        allocator.free(id);
        prefs.last_workspace_id = null;
    }
    prefs.last_workspace_id = try allocator.dupe(u8, ws_id);
    try save(allocator, prefs);
}

pub fn saveMarkdownViewerArgv(allocator: std.mem.Allocator, argv: ?[]const []const u8) !void {
    var prefs = load(allocator) catch Prefs{};
    defer prefs.deinit(allocator);
    if (prefs.markdown_viewer_argv) |old| {
        for (old) |arg| allocator.free(arg);
        allocator.free(old);
        prefs.markdown_viewer_argv = null;
    }
    prefs.markdown_viewer_argv = if (argv) |items| try dupeArgv(allocator, items) else null;
    try save(allocator, prefs);
}

fn save(allocator: std.mem.Allocator, prefs: Prefs) !void {
    const base = try auth.getBasePath(allocator);
    defer allocator.free(base);
    std.Io.Dir.createDirAbsolute(std.Options.debug_io, base, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const path = try prefsPathFromBase(allocator, base);
    defer allocator.free(path);

    const body = try std.json.Stringify.valueAlloc(allocator, PrefsJson{
        .last_workspace_id = prefs.last_workspace_id,
        .markdown_viewer_argv = prefs.markdown_viewer_argv,
    }, .{});
    defer allocator.free(body);

    const file = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, path, .{ .truncate = true, .permissions = @enumFromInt(0o600) });
    defer file.close(std.Options.debug_io);
    var write_buf: [4096]u8 = undefined;
    var writer = std.Io.File.Writer.init(file, std.Options.debug_io, &write_buf);
    try writer.interface.writeAll(body);
    try writer.interface.flush();
}

pub fn parseCommandLineArgv(allocator: std.mem.Allocator, command: []const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (argv.items) |arg| allocator.free(arg);
        argv.deinit(allocator);
    }

    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(allocator);

    var quote: ?u8 = null;
    var escaped = false;
    var saw_arg = false;

    var i: usize = 0;
    while (i < command.len) : (i += 1) {
        const byte = command[i];
        if (escaped) {
            try current.append(allocator, byte);
            saw_arg = true;
            escaped = false;
            continue;
        }
        if (byte == '\\') {
            if (i + 1 < command.len and shouldEscapeCommandByte(command[i + 1])) {
                escaped = true;
            } else {
                try current.append(allocator, byte);
            }
            saw_arg = true;
            continue;
        }
        if (quote) |q| {
            if (byte == q) {
                quote = null;
            } else {
                try current.append(allocator, byte);
            }
            saw_arg = true;
            continue;
        }
        if (byte == '"' or byte == '\'') {
            quote = byte;
            saw_arg = true;
            continue;
        }
        if (byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n') {
            if (saw_arg) {
                try argv.append(allocator, try current.toOwnedSlice(allocator));
                current.clearRetainingCapacity();
                saw_arg = false;
            }
            continue;
        }
        try current.append(allocator, byte);
        saw_arg = true;
    }
    if (escaped or quote != null) return error.InvalidCommandLine;
    if (saw_arg) try argv.append(allocator, try current.toOwnedSlice(allocator));
    if (argv.items.len == 0) return error.EmptyCommand;
    return try argv.toOwnedSlice(allocator);
}

fn shouldEscapeCommandByte(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\r', '\n', '"', '\'', '\\' => true,
        else => false,
    };
}

pub fn commandLineFromArgv(allocator: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (argv, 0..) |arg, idx| {
        if (idx > 0) try out.append(allocator, ' ');
        if (needsQuoting(arg)) {
            try out.append(allocator, '"');
            for (arg) |byte| {
                if (byte == '"' or byte == '\\') try out.append(allocator, '\\');
                try out.append(allocator, byte);
            }
            try out.append(allocator, '"');
        } else {
            try out.appendSlice(allocator, arg);
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn dupeArgv(allocator: std.mem.Allocator, argv: []const []const u8) ![]const []const u8 {
    var out = try allocator.alloc([]const u8, argv.len);
    var copied: usize = 0;
    errdefer {
        for (out[0..copied]) |arg| allocator.free(arg);
        allocator.free(out);
    }
    for (argv, 0..) |arg, idx| {
        out[idx] = try allocator.dupe(u8, arg);
        copied += 1;
    }
    return out;
}

fn needsQuoting(arg: []const u8) bool {
    if (arg.len == 0) return true;
    for (arg) |byte| {
        switch (byte) {
            ' ', '\t', '\r', '\n', '"', '\\' => return true,
            else => {},
        }
    }
    return false;
}

pub fn selectWorkspaceIndex(
    workspaces: []const model.WorkspaceData,
    preferred_id: ?[]const u8,
) usize {
    if (preferred_id) |id| {
        for (workspaces, 0..) |ws, idx| {
            if (std.mem.eql(u8, ws.ws_id, id)) return idx;
        }
    }
    return 0;
}

fn prefsPath(allocator: std.mem.Allocator) ![]const u8 {
    const base = try auth.getBasePath(allocator);
    defer allocator.free(base);
    return prefsPathFromBase(allocator, base);
}

fn prefsPathFromBase(allocator: std.mem.Allocator, base: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ base, "tui_prefs.json" });
}

test "selectWorkspaceIndex matches saved workspace id" {
    const workspaces = [_]model.WorkspaceData{
        .{ .ws_id = "ws-1", .name = "One", .description = "First workspace", .role = "admin", .owner = "user" },
        .{ .ws_id = "ws-2", .name = "Two", .description = "Second workspace", .role = "admin", .owner = "user" },
    };
    try std.testing.expectEqual(@as(usize, 1), selectWorkspaceIndex(&workspaces, "ws-2"));
}

test "selectWorkspaceIndex falls back to first when saved workspace is stale" {
    const workspaces = [_]model.WorkspaceData{
        .{ .ws_id = "ws-1", .name = "One", .description = "First workspace", .role = "admin", .owner = "user" },
        .{ .ws_id = "ws-2", .name = "Two", .description = "Second workspace", .role = "admin", .owner = "user" },
    };
    try std.testing.expectEqual(@as(usize, 0), selectWorkspaceIndex(&workspaces, "ws-gone"));
    try std.testing.expectEqual(@as(usize, 0), selectWorkspaceIndex(&workspaces, null));
}

test "parseCommandLineArgv handles quoted app names" {
    const argv = try parseCommandLineArgv(std.testing.allocator, "open -a \"Typora Beta\"");
    defer {
        for (argv) |arg| std.testing.allocator.free(arg);
        std.testing.allocator.free(argv);
    }
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("open", argv[0]);
    try std.testing.expectEqualStrings("-a", argv[1]);
    try std.testing.expectEqualStrings("Typora Beta", argv[2]);
}

test "commandLineFromArgv quotes whitespace" {
    const rendered = try commandLineFromArgv(std.testing.allocator, &.{ "open", "-a", "Typora Beta" });
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("open -a \"Typora Beta\"", rendered);
}

test "parseCommandLineArgv preserves Windows path backslashes" {
    const argv = try parseCommandLineArgv(std.testing.allocator, "\"C:\\Program Files\\Typora\\Typora.exe\"");
    defer {
        for (argv) |arg| std.testing.allocator.free(arg);
        std.testing.allocator.free(argv);
    }
    try std.testing.expectEqual(@as(usize, 1), argv.len);
    try std.testing.expectEqualStrings("C:\\Program Files\\Typora\\Typora.exe", argv[0]);
}
