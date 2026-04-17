//! MCP session marker: records which MCP server session is active for a workspace. Written
//! atomically when the MCP server starts, read by the TUI to show active sessions, cleared
//! on shutdown. Stored at {ws_dir}/current_session.json.
const std = @import("std");
const testing = std.testing;

const SessionMarker = struct {
    session_id: []const u8,
    started_at: i64,
};

fn markerPath(allocator: std.mem.Allocator, ws_dir: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ ws_dir, "current_session.json" });
}

/// Write `{ws_dir}/current_session.json` with the current MCP serve session
/// metadata. Atomic temp + rename so a concurrent reader never sees a partial
/// file. Called once at MCP serve startup.
pub fn write(allocator: std.mem.Allocator, ws_dir: []const u8, session_id: []const u8) !void {
    const path = try markerPath(allocator, ws_dir);
    defer allocator.free(path);

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    const started_at = std.time.milliTimestamp();

    {
        const file = try std.fs.createFileAbsolute(tmp_path, .{ .truncate = true });
        defer file.close();
        var buf: [512]u8 = undefined;
        var w = std.fs.File.Writer.init(file, &buf);
        try w.interface.print(
            "{{\"session_id\":\"{s}\",\"started_at\":{d}}}\n",
            .{ session_id, started_at },
        );
        try w.interface.flush();
    }

    try std.fs.renameAbsolute(tmp_path, path);
}

/// Best-effort delete of the current session marker. Called during MCP serve
/// shutdown. Failures are ignored (the next startup will overwrite anyway).
pub fn clear(allocator: std.mem.Allocator, ws_dir: []const u8) void {
    const path = markerPath(allocator, ws_dir) catch return;
    defer allocator.free(path);
    std.fs.deleteFileAbsolute(path) catch {};
}

/// Read the current session marker. Returns null if the file does not exist.
/// Caller owns `session_id` and must free it.
pub fn read(allocator: std.mem.Allocator, ws_dir: []const u8) !?SessionMarker {
    const path = try markerPath(allocator, ws_dir);
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    var read_buf: [1024]u8 = undefined;
    var fr = std.fs.File.Reader.init(file, &read_buf);
    const content = try fr.interface.allocRemaining(allocator, std.io.Limit.limited(8 * 1024));
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return error.InvalidSessionMarker;
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidSessionMarker;
    const obj = parsed.value.object;

    const sid_val = obj.get("session_id") orelse return error.InvalidSessionMarker;
    const sid_str = switch (sid_val) {
        .string => |s| s,
        else => return error.InvalidSessionMarker,
    };

    const started_val = obj.get("started_at") orelse return error.InvalidSessionMarker;
    const started_at: i64 = switch (started_val) {
        .integer => |n| n,
        else => return error.InvalidSessionMarker,
    };

    return .{
        .session_id = try allocator.dupe(u8, sid_str),
        .started_at = started_at,
    };
}

test "write then read roundtrip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmp.dir.realpath(".", &buf) catch unreachable;

    try write(testing.allocator, root, "sess-test123");

    const marker = (try read(testing.allocator, root)).?;
    defer testing.allocator.free(marker.session_id);

    try testing.expectEqualStrings("sess-test123", marker.session_id);
    try testing.expect(marker.started_at > 0);
}

test "read returns null when marker missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmp.dir.realpath(".", &buf) catch unreachable;

    try testing.expect(try read(testing.allocator, root) == null);
}

test "clear removes the file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmp.dir.realpath(".", &buf) catch unreachable;

    try write(testing.allocator, root, "sess-x");
    clear(testing.allocator, root);
    try testing.expect(try read(testing.allocator, root) == null);
}
