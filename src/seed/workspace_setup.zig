//! Creates workspace directory structure under ~/.clumsies/workspaces/{name}/ for seed workspaces.
const std = @import("std");

pub fn ensureWorkspaceFiles(ws_id: []const u8, name: []const u8) !void {
    const alloc = std.heap.page_allocator;
    const ws_dir = try workspaceDirPath(alloc, ws_id, name);
    defer alloc.free(ws_dir);
    try ensureWorkspaceDirTree(ws_dir);

    const logs_dir = try std.fs.path.join(alloc, &.{ ws_dir, "logs" });
    defer alloc.free(logs_dir);
    try ensureDir(logs_dir);

    const attestation_dir = try std.fs.path.join(alloc, &.{ ws_dir, "attestation" });
    defer alloc.free(attestation_dir);
    try ensureDir(attestation_dir);
}

pub fn deleteWorkspaceFiles(ws_id: []const u8, name: []const u8) void {
    const alloc = std.heap.page_allocator;
    const ws_dir = workspaceDirPath(alloc, ws_id, name) catch return;
    defer alloc.free(ws_dir);

    std.fs.deleteTreeAbsolute(ws_dir) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {},
    };
}

fn workspaceDirPath(allocator: std.mem.Allocator, _: []const u8, name: []const u8) ![]const u8 {
    if (!isSafeWorkspaceDirName(name)) return error.InvalidWorkspaceName;

    const home = std.process.getEnvVarOwned(allocator, "HOME") catch
        std.process.getEnvVarOwned(allocator, "USERPROFILE") catch
        return error.HomeNotSet;
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, ".clumsies", "workspaces", name });
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

fn ensureDir(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn isSafeWorkspaceId(ws_id: []const u8) bool {
    if (std.mem.indexOfScalar(u8, ws_id, '/')) |_| return false;
    if (std.mem.indexOfScalar(u8, ws_id, '\\')) |_| return false;
    if (std.mem.indexOf(u8, ws_id, "..")) |_| return false;
    return true;
}

fn isSafeWorkspaceDirName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    if (std.mem.indexOfScalar(u8, name, '/')) |_| return false;
    if (std.mem.indexOfScalar(u8, name, '\\')) |_| return false;
    return true;
}

test "isSafeWorkspaceId rejects traversal markers" {
    try std.testing.expect(isSafeWorkspaceId("ws-seed-sandbox"));
    try std.testing.expect(!isSafeWorkspaceId("../escape"));
    try std.testing.expect(!isSafeWorkspaceId("nested/ws"));
    try std.testing.expect(!isSafeWorkspaceId("nested\\ws"));
}
