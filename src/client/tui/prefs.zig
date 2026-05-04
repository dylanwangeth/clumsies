//! TUI-local preferences. These are client UI state, not Hub-synced content.
//! The first preference is the last selected workspace id so the next TUI
//! launch can restore the user's previous workspace when `/api/auth/me`
//! returns a matching workspace in scope.

const std = @import("std");
const auth = @import("../auth.zig");
const model = @import("api/model.zig");

pub const Prefs = struct {
    last_workspace_id: ?[]const u8 = null,

    pub fn deinit(self: Prefs, allocator: std.mem.Allocator) void {
        if (self.last_workspace_id) |id| allocator.free(id);
    }
};

const PrefsJson = struct {
    last_workspace_id: ?[]const u8 = null,
};

pub fn load(allocator: std.mem.Allocator) !Prefs {
    const path = try prefsPath(allocator);
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer file.close();

    var read_buf: [4096]u8 = undefined;
    var fr = std.fs.File.Reader.init(file, &read_buf);
    const body = try fr.interface.allocRemaining(allocator, std.io.Limit.limited(64 * 1024));
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(PrefsJson, allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    return .{
        .last_workspace_id = if (parsed.value.last_workspace_id) |id| try allocator.dupe(u8, id) else null,
    };
}

pub fn saveLastWorkspaceId(allocator: std.mem.Allocator, ws_id: []const u8) !void {
    const base = try auth.getBasePath(allocator);
    defer allocator.free(base);
    std.fs.makeDirAbsolute(base) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const path = try prefsPathFromBase(allocator, base);
    defer allocator.free(path);

    const body = try std.json.Stringify.valueAlloc(allocator, PrefsJson{ .last_workspace_id = ws_id }, .{});
    defer allocator.free(body);

    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    var write_buf: [4096]u8 = undefined;
    var writer = std.fs.File.Writer.init(file, &write_buf);
    try writer.interface.writeAll(body);
    try writer.interface.flush();
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
        .{ .ws_id = "ws-1", .name = "One" },
        .{ .ws_id = "ws-2", .name = "Two" },
    };
    try std.testing.expectEqual(@as(usize, 1), selectWorkspaceIndex(&workspaces, "ws-2"));
}

test "selectWorkspaceIndex falls back to first when saved workspace is stale" {
    const workspaces = [_]model.WorkspaceData{
        .{ .ws_id = "ws-1", .name = "One" },
        .{ .ws_id = "ws-2", .name = "Two" },
    };
    try std.testing.expectEqual(@as(usize, 0), selectWorkspaceIndex(&workspaces, "ws-gone"));
    try std.testing.expectEqual(@as(usize, 0), selectWorkspaceIndex(&workspaces, null));
}
