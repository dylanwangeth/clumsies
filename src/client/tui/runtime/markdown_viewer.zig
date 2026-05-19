//! Open materialized Markdown previews in an external viewer.

const std = @import("std");
const builtin = @import("builtin");
const util_hash = @import("clumsies_lib").util.hash;

pub const Result = enum {
    opened,
    viewer_not_found,
    spawn_failed,
    failed,
};

pub fn systemOpenLabel() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "$ open <preview.md>",
        .windows => "$ cmd /C start \"\" <preview.md>",
        else => "$ xdg-open <preview.md>",
    };
}

pub fn materialize(
    allocator: std.mem.Allocator,
    ws_dir: []const u8,
    source_path: []const u8,
    content: []const u8,
) ![]const u8 {
    const dir_path = try std.fs.path.join(allocator, &.{ ws_dir, "viewer" });
    defer allocator.free(dir_path);
    std.fs.makeDirAbsolute(dir_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const name = try previewFileName(allocator, source_path, content);
    defer allocator.free(name);
    const path = try std.fs.path.join(allocator, &.{ dir_path, name });
    errdefer allocator.free(path);

    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.Writer.init(file, &buf);
    try writer.interface.writeAll(content);
    try writer.interface.flush();
    return path;
}

pub fn open(
    allocator: std.mem.Allocator,
    configured_argv: ?[]const []const u8,
    file_path: []const u8,
) !Result {
    const argv = if (configured_argv) |configured|
        try argvWithFile(allocator, configured, file_path)
    else
        try systemOpenArgv(allocator, file_path);
    defer allocator.free(argv);

    if (argv.len < 2) return .spawn_failed;
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    child.spawn() catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.InvalidExe => return .viewer_not_found,
        else => return .spawn_failed,
    };
    const term = child.wait() catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.InvalidExe => return .viewer_not_found,
        else => return .spawn_failed,
    };
    return switch (term) {
        .Exited => |code| if (code == 0) .opened else .failed,
        else => .failed,
    };
}

pub fn previewFileName(allocator: std.mem.Allocator, source_path: []const u8, content: []const u8) ![]const u8 {
    const hash = util_hash.contentHash(content);
    var safe: std.ArrayList(u8) = .empty;
    defer safe.deinit(allocator);
    for (source_path) |byte| {
        switch (byte) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => try safe.append(allocator, byte),
            else => try safe.append(allocator, '_'),
        }
    }
    if (!std.mem.endsWith(u8, safe.items, ".md")) {
        try safe.appendSlice(allocator, ".md");
    }
    const stem = if (safe.items.len == 0) "preview.md" else safe.items;
    return std.fmt.allocPrint(allocator, "{s}.{s}.md", .{ stem[0..stem.len -| 3], hash[7..15] });
}

fn argvWithFile(allocator: std.mem.Allocator, argv: []const []const u8, file_path: []const u8) ![]const []const u8 {
    var out = try allocator.alloc([]const u8, argv.len + 1);
    @memcpy(out[0..argv.len], argv);
    out[argv.len] = file_path;
    return out;
}

fn systemOpenArgv(allocator: std.mem.Allocator, file_path: []const u8) ![]const []const u8 {
    return switch (builtin.os.tag) {
        .macos => blk: {
            const out = try allocator.alloc([]const u8, 2);
            out[0] = "open";
            out[1] = file_path;
            break :blk out;
        },
        .windows => blk: {
            const out = try allocator.alloc([]const u8, 5);
            out[0] = "cmd";
            out[1] = "/C";
            out[2] = "start";
            out[3] = "";
            out[4] = file_path;
            break :blk out;
        },
        else => blk: {
            const out = try allocator.alloc([]const u8, 2);
            out[0] = "xdg-open";
            out[1] = file_path;
            break :blk out;
        },
    };
}

test "previewFileName keeps markdown extension and adds hash" {
    const name = try previewFileName(std.testing.allocator, "studies/TUI_EXTERNAL_MARKDOWN_VIEWER.md", "# Title\n");
    defer std.testing.allocator.free(name);
    try std.testing.expect(std.mem.startsWith(u8, name, "studies_TUI_EXTERNAL_MARKDOWN_VIEWER."));
    try std.testing.expect(std.mem.endsWith(u8, name, ".md"));
}

test "open appends file path to configured argv" {
    const result = try open(std.testing.allocator, &.{"/usr/bin/true"}, "/tmp/ignored.md");
    try std.testing.expectEqual(Result.opened, result);
}
