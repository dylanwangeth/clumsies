// Read per-workspace current_session.json markers written by the MCP
// serve process on startup. Each file advertises the session_id, pid
// and start timestamp for an active MCP on that workspace; the file is
// removed on graceful shutdown. The TUI uses this to show which
// sessions are currently live.

const std = @import("std");

pub const ActiveSession = struct {
    ws_id: []const u8,
    session_id: []const u8,
    pid: i64,
    started_at: i64,
};

pub fn readAllSessions(allocator: std.mem.Allocator) ?[]const ActiveSession {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return null;
    defer allocator.free(home);
    const ws_root = std.fs.path.join(allocator, &.{ home, ".clumsies", "workspaces" }) catch return null;
    defer allocator.free(ws_root);

    var dir = std.fs.openDirAbsolute(ws_root, .{ .iterate = true }) catch return null;
    defer dir.close();

    var list: std.ArrayList(ActiveSession) = .empty;
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        const marker = std.fs.path.join(allocator, &.{ ws_root, entry.name, "current_session.json" }) catch continue;
        defer allocator.free(marker);
        readMarker(allocator, entry.name, marker, &list);
    }

    if (list.items.len == 0) return null;
    return list.items;
}

fn readMarker(allocator: std.mem.Allocator, ws_id: []const u8, path: []const u8, out: *std.ArrayList(ActiveSession)) void {
    const file = std.fs.openFileAbsolute(path, .{}) catch return;
    defer file.close();

    var buf: [2048]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = file.read(buf[total..]) catch return;
        if (n == 0) break;
        total += n;
    }
    if (total == 0) return;

    const Json = struct {
        session_id: []const u8 = "",
        pid: i64 = 0,
        started_at: i64 = 0,
    };
    const parsed = std.json.parseFromSlice(Json, allocator, buf[0..total], .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return;
    defer parsed.deinit();

    if (parsed.value.session_id.len == 0) return;

    // A stale marker from a crashed MCP can linger on disk. Probe the
    // pid with signal 0 (no-op) to verify the process is still alive;
    // if the kill check fails we skip the entry rather than report a
    // ghost session.
    if (parsed.value.pid > 0 and !pidAlive(@intCast(parsed.value.pid))) return;

    out.append(allocator, .{
        .ws_id = allocator.dupe(u8, ws_id) catch return,
        .session_id = allocator.dupe(u8, parsed.value.session_id) catch return,
        .pid = parsed.value.pid,
        .started_at = parsed.value.started_at,
    }) catch return;
}

fn pidAlive(pid: std.c.pid_t) bool {
    const rc = std.c.kill(pid, 0);
    return rc == 0;
}
