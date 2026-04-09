const std = @import("std");
const testing = std.testing;
const protocol = @import("protocol.zig");
const handlers = @import("handlers.zig");

pub const State = struct {
    workspace_root: []const u8,
    initialized: bool = false,
    initialize_seen: bool = false,
};

pub fn run(stdout: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator, version: []const u8) !void {
    const workspace_root = try std.process.getCwdAlloc(allocator);
    defer allocator.free(workspace_root);
    try runWithRoot(stdout, stderr, allocator, version, workspace_root);
}

pub fn runWithRoot(stdout: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator, version: []const u8, workspace_root: []const u8) !void {
    _ = stderr;

    var state: State = .{
        .workspace_root = workspace_root,
    };

    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.fs.File.Reader.init(std.fs.File.stdin(), &stdin_buffer);
    const reader = &stdin_reader.interface;

    while (true) {
        const raw_line = reader.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        const response = processLine(allocator, &state, version, line) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => try protocol.buildErrorAlloc(allocator, null, .internal_error, @errorName(err)),
        };
        defer if (response) |owned| allocator.free(owned);

        if (response) |owned| {
            try stdout.writeAll(owned);
            try stdout.flush();
        }
    }
}

pub fn processLine(allocator: std.mem.Allocator, state: *State, version: []const u8, line: []const u8) !?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
        return try protocol.buildErrorAlloc(allocator, null, .parse_error, "Invalid JSON");
    };
    defer parsed.deinit();

    return processMessage(allocator, state, version, parsed.value);
}

fn processMessage(allocator: std.mem.Allocator, state: *State, version: []const u8, message: std.json.Value) !?[]u8 {
    const object = switch (message) {
        .object => |obj| obj,
        .array => return try protocol.buildErrorAlloc(allocator, null, .invalid_request, "Batch requests are not supported"),
        else => return try protocol.buildErrorAlloc(allocator, null, .invalid_request, "Expected JSON object"),
    };

    const method = if (object.get("method")) |value| switch (value) {
        .string => |s| s,
        else => return try protocol.buildErrorAlloc(allocator, null, .invalid_request, "Method must be a string"),
    } else return try protocol.buildErrorAlloc(allocator, null, .invalid_request, "Missing method");

    const id = object.get("id");
    const params = object.get("params") orelse std.json.Value{ .null = {} };

    if (id == null) {
        return handleNotification(state, method);
    }

    if (std.mem.eql(u8, method, "initialize")) {
        state.initialize_seen = true;
        const result = try handlers.buildInitializeResult(allocator, version);
        defer allocator.free(result);
        return try protocol.buildResultAlloc(allocator, id.?, result);
    }

    if (std.mem.eql(u8, method, "ping")) {
        return try protocol.buildResultAlloc(allocator, id.?, "{}");
    }

    if (!state.initialized) {
        return try protocol.buildErrorAlloc(allocator, id.?, .server_not_initialized, "Server not initialized");
    }

    if (std.mem.eql(u8, method, "tools/list")) {
        const result = try handlers.buildToolsListResult(allocator);
        defer allocator.free(result);
        return try protocol.buildResultAlloc(allocator, id.?, result);
    }

    if (std.mem.eql(u8, method, "tools/call")) {
        const result = handlers.handleToolCall(allocator, state.workspace_root, params) catch |err| switch (err) {
            error.InvalidParams => return try protocol.buildErrorAlloc(allocator, id.?, .invalid_params, "Invalid tool arguments"),
            else => return err,
        };
        defer allocator.free(result);
        return try protocol.buildResultAlloc(allocator, id.?, result);
    }

    return try protocol.buildErrorAlloc(allocator, id.?, .method_not_found, "Unknown method");
}

fn handleNotification(state: *State, method: []const u8) ?[]u8 {
    if (std.mem.eql(u8, method, "notifications/initialized")) {
        state.initialized = true;
        return null;
    }
    return null;
}

test "processLine: initialize then tools list" {
    var state: State = .{ .workspace_root = "/tmp/workspace" };

    const init_response = (try processLine(
        testing.allocator,
        &state,
        "0.16.3",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1.0\"}}}",
    )).?;
    defer testing.allocator.free(init_response);
    try testing.expect(std.mem.indexOf(u8, init_response, "\"protocolVersion\":\"2025-06-18\"") != null);

    const initialized_response = try processLine(
        testing.allocator,
        &state,
        "0.16.3",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
    );
    try testing.expect(initialized_response == null);

    const tools_response = (try processLine(
        testing.allocator,
        &state,
        "0.16.3",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}",
    )).?;
    defer testing.allocator.free(tools_response);
    try testing.expect(std.mem.indexOf(u8, tools_response, "\"memory.setup\"") != null);
    try testing.expect(std.mem.indexOf(u8, tools_response, "\"memory.search\"") != null);
    try testing.expect(std.mem.indexOf(u8, tools_response, "\"memory.load\"") != null);
    try testing.expect(std.mem.indexOf(u8, tools_response, "\"memory.refer\"") != null);
}
