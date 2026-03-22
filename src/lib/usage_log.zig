const std = @import("std");
const testing = std.testing;
const config = @import("config.zig");
const encoding = @import("encoding.zig");

pub const ActivationRef = struct {
    id: []const u8,
    hash: []const u8,
};

pub fn getActivationLogPath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]const u8 {
    const base_path = try config.getBasePath(allocator);
    defer allocator.free(base_path);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(workspace_root);

    var hash: [32]u8 = undefined;
    hasher.final(&hash);

    var hex: [64]u8 = undefined;
    encoding.hexEncode(&hash, &hex);

    return try std.fs.path.join(allocator, &.{ base_path, "usage", hex[0..16] ++ ".jsonl" });
}

pub fn appendActivation(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    phase: []const u8,
    task_id: ?[]const u8,
    turn_id: ?[]const u8,
    refs: []const ActivationRef,
) !void {
    const log_path = try getActivationLogPath(allocator, workspace_root);
    defer allocator.free(log_path);

    if (std.fs.path.dirname(log_path)) |dir_path| {
        std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    } else {
        return error.InvalidLogPath;
    }

    var file = try std.fs.createFileAbsolute(log_path, .{
        .truncate = false,
    });
    defer file.close();
    try file.seekFromEnd(0);

    const line = try buildActivationLine(allocator, workspace_root, phase, task_id, turn_id, refs);
    defer allocator.free(line);
    try file.writeAll(line);
}

fn buildActivationLine(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    phase: []const u8,
    task_id: ?[]const u8,
    turn_id: ?[]const u8,
    refs: []const ActivationRef,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    const esc_workspace = try encoding.jsonEscapeAlloc(allocator, workspace_root);
    defer allocator.free(esc_workspace);
    const esc_phase = try encoding.jsonEscapeAlloc(allocator, phase);
    defer allocator.free(esc_phase);
    const esc_task = if (task_id) |id| try encoding.jsonEscapeAlloc(allocator, id) else null;
    defer if (esc_task) |task| allocator.free(task);
    const esc_turn = if (turn_id) |id| try encoding.jsonEscapeAlloc(allocator, id) else null;
    defer if (esc_turn) |turn| allocator.free(turn);

    try buf.writer(allocator).print(
        "{{\"timestamp\":{d},\"workspace\":\"{s}\",\"phase\":\"{s}\",\"task_id\":",
        .{ std.time.timestamp(), esc_workspace, esc_phase },
    );

    if (esc_task) |task| {
        try buf.writer(allocator).print("\"{s}\"", .{task});
    } else {
        try buf.appendSlice(allocator, "null");
    }

    try buf.appendSlice(allocator, ",\"turn_id\":");
    if (esc_turn) |turn| {
        try buf.writer(allocator).print("\"{s}\"", .{turn});
    } else {
        try buf.appendSlice(allocator, "null");
    }

    try buf.appendSlice(allocator, ",\"activated\":[");
    for (refs, 0..) |ref, idx| {
        if (idx > 0) try buf.append(allocator, ',');
        const esc_id = try encoding.jsonEscapeAlloc(allocator, ref.id);
        defer allocator.free(esc_id);
        try buf.writer(allocator).print("{{\"id\":\"{s}\",\"hash\":\"{s}\"}}", .{ esc_id, ref.hash });
    }
    try buf.appendSlice(allocator, "]}\n");

    return try buf.toOwnedSlice(allocator);
}

test "getActivationLogPath: stable per workspace" {
    const path_a = try getActivationLogPath(testing.allocator, "/tmp/workspace-a");
    defer testing.allocator.free(path_a);
    const path_b = try getActivationLogPath(testing.allocator, "/tmp/workspace-a");
    defer testing.allocator.free(path_b);
    const path_c = try getActivationLogPath(testing.allocator, "/tmp/workspace-b");
    defer testing.allocator.free(path_c);

    try testing.expectEqualStrings(path_a, path_b);
    try testing.expect(!std.mem.eql(u8, path_a, path_c));
}

test "buildActivationLine: renders refs and nullable ids" {
    const line = try buildActivationLine(testing.allocator, "/tmp/ws", "activate", null, "turn-1", &.{
        .{ .id = "pin:PIN.md", .hash = "abcd" },
        .{ .id = "mpf:AGENTS.md", .hash = "efgh" },
    });
    defer testing.allocator.free(line);

    try testing.expect(std.mem.indexOf(u8, line, "\"workspace\":\"/tmp/ws\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"task_id\":null") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"turn_id\":\"turn-1\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"id\":\"pin:PIN.md\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"hash\":\"efgh\"") != null);
}
