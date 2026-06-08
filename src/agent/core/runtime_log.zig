//! Agent runtime event log for provider-level observability.
//!
//! Unlike session.jsonl (which captures durable conversation facts for
//! playback and memory recall), runtime.jsonl records timestamped
//! provider request/response details that help debug LLM behavior,
//! measure latency, and verify UI correctness against ground truth.
//!
//! The file lives alongside session.jsonl as `<hash>_runtime.jsonl`.

const std = @import("std");

const RuntimeLog = @This();

/// Small tool-call record embedded in provider response events.
pub const ToolCallDetail = struct { id: []const u8, name: []const u8, arguments: []const u8 };

/// Timestamp-granularity model response detail.
pub const ProviderDetail = struct {
    turn: usize,
    model: []const u8,
    content: []const u8,
    tool_calls: []const ToolCallDetail,
    latency_ms: u64,
};

/// Transport-level or provider-level error during a turn.
pub const ProviderErrorEvent = struct {
    turn: usize,
    message: []const u8,
};

/// Request-level metadata logged before the provider call.
pub const ProviderRequestInfo = struct {
    turn: usize,
    msg_count: usize,
    tool_count: usize,
    model: []const u8,
};
allocator: std.mem.Allocator,
file: ?std.fs.File = null,
path: []const u8 = "",

/// Opens the runtime log file for append.
pub fn init(allocator: std.mem.Allocator, path: []const u8) !RuntimeLog {
    const file = try std.fs.cwd().createFile(path, .{ .truncate = false, .read = true });
    errdefer file.close();
    _ = try file.seekFromEnd(0);
    return .{
        .allocator = allocator,
        .file = file,
        .path = try allocator.dupe(u8, path),
    };
}

/// Closes the file and releases owned state.
pub fn deinit(self: *RuntimeLog) void {
    if (self.file) |file| {
        file.close();
        self.file = null;
    }
    if (self.path.len > 0) {
        self.allocator.free(self.path);
        self.path = "";
    }
}

/// Appends one JSON line with a millisecond-granularity timestamp.
pub fn append(self: *RuntimeLog, event: anytype) !void {
    if (self.file) |file| {
        const ts: i64 = @intCast(std.time.milliTimestamp());
        const line = try std.json.Stringify.valueAlloc(self.allocator, .{
            .ts = ts,
            .event = event,
        }, .{});
        defer self.allocator.free(line);
        try file.writeAll(line);
        try file.writeAll("\n");
    }
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "runtime log appends timestamped events" {
    const testing = std.testing;
    const a = testing.allocator;
    const path = "test_runtime_log.jsonl";
    defer std.fs.cwd().deleteFile(path) catch {};

    var log = try RuntimeLog.init(a, path);
    defer log.deinit();

    try log.append(.{ .type = "provider_request", .turn = 0, .model = "test" });
    try log.append(.{ .type = "provider_response", .turn = 0, .latency_ms = 1234 });

    const content = try std.fs.cwd().readFileAlloc(a, path, 4096);
    defer a.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "provider_request") != null);
    try testing.expect(std.mem.indexOf(u8, content, "provider_response") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"ts\":") != null);

    // Verify two lines
    var count: usize = 0;
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        if (line.len > 0) count += 1;
    }
    try testing.expectEqual(@as(usize, 2), count);
}
