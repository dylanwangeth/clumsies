//! Creates workspace directory structure under ~/.clumsies/workspaces/{ws_id}/ with initial
//! attestation.jsonl and cursor files for seed workspaces.
const std = @import("std");
const local_attestation = @import("clumsies_client").attestation;

pub fn ensureWorkspaceFiles(ws_id: []const u8) !void {
    if (!isSafeWorkspaceId(ws_id)) return error.InvalidWorkspaceId;

    const alloc = std.heap.page_allocator;
    const ws_dir = try workspaceDirPath(alloc, ws_id);
    defer alloc.free(ws_dir);
    try ensureWorkspaceDirTree(ws_dir);

    const attestation_path = try local_attestation.attestationFilePath(alloc, ws_id);
    defer alloc.free(attestation_path);
    try ensureFileExists(attestation_path);

    const cursor_path = try local_attestation.cursorFilePath(alloc, ws_id);
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
    const attestation_path = try local_attestation.attestationFilePath(allocator, ws_id);
    defer allocator.free(attestation_path);

    const ws_dir = std.fs.path.dirname(attestation_path) orelse return error.InvalidAttestationPath;
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
