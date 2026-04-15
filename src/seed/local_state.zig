const std = @import("std");
const clumsies_lib = @import("clumsies_lib");
const local_trace = clumsies_lib.trace;

pub fn ensureWorkspaceFiles(ws_id: []const u8) !void {
    if (!isSafeWorkspaceId(ws_id)) return error.InvalidWorkspaceId;

    const alloc = std.heap.page_allocator;
    const ws_dir = try workspaceDirPath(alloc, ws_id);
    defer alloc.free(ws_dir);
    try ensureWorkspaceDirTree(ws_dir);

    const trace_path = try local_trace.traceFilePath(alloc, ws_id);
    defer alloc.free(trace_path);
    try ensureFileExists(trace_path);

    const cursor_path = try local_trace.cursorFilePath(alloc, ws_id);
    defer alloc.free(cursor_path);
    try ensureCursorFile(cursor_path);
}

pub fn deleteWorkspaceFiles(ws_id: []const u8) void {
    if (!isSafeWorkspaceId(ws_id)) return;

    const alloc = std.heap.page_allocator;
    const ws_dir = workspaceDirPath(alloc, ws_id) catch return;
    defer alloc.free(ws_dir);

    std.fs.deleteTreeAbsolute(ws_dir) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {},
    };
}

fn workspaceDirPath(allocator: std.mem.Allocator, ws_id: []const u8) ![]const u8 {
    const trace_path = try local_trace.traceFilePath(allocator, ws_id);
    defer allocator.free(trace_path);

    const ws_dir = std.fs.path.dirname(trace_path) orelse return error.InvalidTracePath;
    return try allocator.dupe(u8, ws_dir);
}

fn ensureWorkspaceDirTree(ws_dir: []const u8) !void {
    const ws_parent = std.fs.path.dirname(ws_dir) orelse return error.InvalidWorkspacePath;
    const base = std.fs.path.dirname(ws_parent) orelse return error.InvalidWorkspacePath;

    std.fs.makeDirAbsolute(base) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute(ws_parent) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute(ws_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn ensureFileExists(path: []const u8) !void {
    const existing = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            const file = try std.fs.createFileAbsolute(path, .{});
            defer file.close();
            return;
        },
        else => return err,
    };
    existing.close();
}

fn ensureCursorFile(path: []const u8) !void {
    const existing = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            const file = try std.fs.createFileAbsolute(path, .{});
            defer file.close();
            var buf: [32]u8 = undefined;
            var writer = std.fs.File.Writer.init(file, &buf);
            defer writer.interface.flush() catch {};
            try writer.interface.writeAll("0\n");
            return;
        },
        else => return err,
    };
    existing.close();
}

fn isSafeWorkspaceId(ws_id: []const u8) bool {
    if (std.mem.indexOfScalar(u8, ws_id, '/')) |_| return false;
    if (std.mem.indexOfScalar(u8, ws_id, '\\')) |_| return false;
    if (std.mem.indexOf(u8, ws_id, "..")) |_| return false;
    return true;
}

test "isSafeWorkspaceId rejects traversal markers" {
    try std.testing.expect(isSafeWorkspaceId("ws-seed-sandbox"));
    try std.testing.expect(!isSafeWorkspaceId("../escape"));
    try std.testing.expect(!isSafeWorkspaceId("nested/ws"));
    try std.testing.expect(!isSafeWorkspaceId("nested\\ws"));
}
