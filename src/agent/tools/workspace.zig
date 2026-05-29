//! Workspace access helpers for built-in tools.
//!
//! Built-in tools receive model-provided paths, but the model must not choose
//! the filesystem root. This module centralizes the workspace root, read
//! limits, and path traversal checks used by concrete tool implementations.

const std = @import("std");
const path_util = @import("../../util/path_util.zig");

/// Runtime workspace bounds shared by built-in tools.
pub const Context = struct {
    workspace_path: []const u8 = ".",
    max_read_bytes: usize = 64 * 1024,
    max_matches: usize = 100,
};

/// Opens the configured workspace without letting tool arguments choose a root.
pub fn open(context: Context) !std.fs.Dir {
    if (std.fs.path.isAbsolute(context.workspace_path)) {
        return std.fs.openDirAbsolute(context.workspace_path, .{});
    }
    return std.fs.cwd().openDir(context.workspace_path, .{});
}

/// Rejects absolute paths and traversal before joining with the workspace root.
pub fn ensureSafePath(path: []const u8) !void {
    if (!path_util.isSafeRelative(path)) return error.UnsafePath;
}

/// Reads one workspace-relative file through Zig 0.15's `File.Reader`.
///
/// Built-in tools use this instead of deprecated `File.readToEndAlloc` so the
/// file IO boundary stays aligned with the current standard-library model.
pub fn readFileAlloc(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    path: []const u8,
    max_bytes: usize,
) ![]u8 {
    var file = try dir.openFile(path, .{});
    defer file.close();

    var buffer: [4096]u8 = undefined;
    var reader = std.fs.File.Reader.init(file, &buffer);
    return reader.interface.allocRemaining(
        allocator,
        std.io.Limit.limited(max_bytes),
    ) catch |err| switch (err) {
        error.StreamTooLong => error.FileTooBig,
        else => |e| return e,
    };
}

/// Creates or replaces one workspace-relative file through Zig 0.15's writer.
///
/// `std.fs.Dir.writeFile` is still available, but spelling the writer boundary
/// here keeps mutating tools away from deprecated `File.writeAll` patterns and
/// gives future permission or atomic-write logic one place to attach.
pub fn writeFile(dir: std.fs.Dir, path: []const u8, content: []const u8) !void {
    var file = try dir.createFile(path, .{ .truncate = true });
    defer file.close();

    var buffer: [4096]u8 = undefined;
    var writer = std.fs.File.Writer.init(file, &buffer);
    try writer.interface.writeAll(content);
    try writer.interface.flush();
}
