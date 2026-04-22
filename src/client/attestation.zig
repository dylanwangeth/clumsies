//! Attestation event recording. Each MCP setup/search/load/refer/submit interaction
//! is serialized as an AttestationEvent and appended to
//! ~/.clumsies/workspaces/{ws_id}/attestation.jsonl. The Hub later ingests these
//! events via POST /api/attestations to compute constraint-level usage statistics.
//!
//! The data model uses a tagged union (Payload) so each event type carries only
//! its own fields. New event types add a union variant without touching existing ones.
const std = @import("std");
const testing = std.testing;
const encoding = @import("clumsies_lib").util.encoding;

fn getBasePath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch
        std.process.getEnvVarOwned(allocator, "USERPROFILE") catch
        return error.HomeNotSet;
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".clumsies" });
}

pub const AttestationEvent = struct {
    ws_id: []const u8,
    session_id: []const u8,
    event_id: i64,
    ts: i64,
    payload: Payload,

    pub const Payload = union(enum) {
        setup,
        user_prompt: UserPromptPayload,
        search,
        load: LoadPayload,
        refer: ReferPayload,
        agent_report: AgentReportPayload,
        reject: RejectPayload,
        context_propose_create: ProposeCreatePayload,
        context_propose_update: ProposeUpdatePayload,
        context_propose_rename: ProposeRenamePayload,
        context_propose_delete: ProposeDeletePayload,
        rule_propose_create: ProposeCreatePayload,
        rule_propose_update: ProposeUpdatePayload,
        rule_propose_rename: ProposeRenamePayload,
        rule_propose_delete: ProposeDeletePayload,
    };

    pub const UserPromptPayload = struct {
        content_hash: []const u8,
        content: ?[]const u8 = null,
    };

    pub const LoadPayload = struct {
        rule_id: []const u8,
        rule_hash: []const u8,
    };

    pub const ReferPayload = struct {
        rule_id: []const u8,
        rule_hash: ?[]const u8 = null,
        constraint_id: []const u8,
        reason: ?[]const u8 = null,
    };

    pub const AgentReportPayload = struct {
        summary: []const u8,
    };

    pub const RejectPayload = struct {
        reason: ?[]const u8 = null,
    };

    pub const ProposeCreatePayload = struct {
        path: []const u8,
    };

    pub const ProposeUpdatePayload = struct {
        id: []const u8,
    };

    pub const ProposeRenamePayload = struct {
        id: []const u8,
        new_path: []const u8,
    };

    pub const ProposeDeletePayload = struct {
        id: []const u8,
    };
};

/// Map Payload tag to the JSON "type" string.
pub fn payloadTypeTag(payload: AttestationEvent.Payload) []const u8 {
    return switch (payload) {
        .setup => "setup",
        .user_prompt => "user_prompt",
        .search => "search",
        .load => "load",
        .refer => "refer",
        .agent_report => "agent_report",
        .reject => "reject",
        .context_propose_create => "context_propose_create",
        .context_propose_update => "context_propose_update",
        .context_propose_rename => "context_propose_rename",
        .context_propose_delete => "context_propose_delete",
        .rule_propose_create => "rule_propose_create",
        .rule_propose_update => "rule_propose_update",
        .rule_propose_rename => "rule_propose_rename",
        .rule_propose_delete => "rule_propose_delete",
    };
}

/// Get the attestation file path: ~/.clumsies/workspaces/{ws_id}/attestation.jsonl
pub fn attestationFilePath(allocator: std.mem.Allocator, ws_id: []const u8) ![]const u8 {
    const base = try getBasePath(allocator);
    defer allocator.free(base);
    return try std.fs.path.join(allocator, &.{ base, "workspaces", ws_id, "attestation.jsonl" });
}

/// Get the attestation cursor file path: ~/.clumsies/workspaces/{ws_id}/attestation.cursor
pub fn cursorFilePath(allocator: std.mem.Allocator, ws_id: []const u8) ![]const u8 {
    const base = try getBasePath(allocator);
    defer allocator.free(base);
    return try std.fs.path.join(allocator, &.{ base, "workspaces", ws_id, "attestation.cursor" });
}

fn ensureWorkspaceDir(allocator: std.mem.Allocator, ws_id: []const u8) !void {
    const base = try getBasePath(allocator);
    defer allocator.free(base);

    std.fs.makeDirAbsolute(base) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const ws_parent = try std.fs.path.join(allocator, &.{ base, "workspaces" });
    defer allocator.free(ws_parent);
    std.fs.makeDirAbsolute(ws_parent) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const ws_dir = try std.fs.path.join(allocator, &.{ ws_parent, ws_id });
    defer allocator.free(ws_dir);
    std.fs.makeDirAbsolute(ws_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn ensureCursorFile(allocator: std.mem.Allocator, ws_id: []const u8) !void {
    const cursor_path = try cursorFilePath(allocator, ws_id);
    defer allocator.free(cursor_path);

    const existing = std.fs.openFileAbsolute(cursor_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            const file = try std.fs.createFileAbsolute(cursor_path, .{});
            defer file.close();
            var buf: [32]u8 = undefined;
            var w = std.fs.File.Writer.init(file, &buf);
            defer w.interface.flush() catch {};
            try w.interface.writeAll("0\n");
            return;
        },
        else => return err,
    };
    existing.close();
}

/// Append an attestation event to ~/.clumsies/workspaces/{ws_id}/attestation.jsonl.
/// The JSON format matches the server `POST /api/attestations` AttestationEventInput shape.
pub fn appendAttestationEvent(allocator: std.mem.Allocator, event: AttestationEvent) !void {
    try ensureWorkspaceDir(allocator, event.ws_id);
    try ensureCursorFile(allocator, event.ws_id);

    const attestation_path = try attestationFilePath(allocator, event.ws_id);
    defer allocator.free(attestation_path);

    var file = try std.fs.createFileAbsolute(attestation_path, .{ .truncate = false });
    defer file.close();
    try file.seekFromEnd(0);

    const line = try serializeAttestationEvent(allocator, event);
    defer allocator.free(line);

    var write_buf: [4096]u8 = undefined;
    var fw = std.fs.File.Writer.initStreaming(file, &write_buf);
    try fw.interface.writeAll(line);
    try fw.interface.flush();
}

fn serializeAttestationEvent(allocator: std.mem.Allocator, event: AttestationEvent) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const esc_ws = try encoding.jsonEscapeAlloc(allocator, event.ws_id);
    defer allocator.free(esc_ws);
    const esc_session = try encoding.jsonEscapeAlloc(allocator, event.session_id);
    defer allocator.free(esc_session);

    const type_tag = payloadTypeTag(event.payload);
    const esc_type = try encoding.jsonEscapeAlloc(allocator, type_tag);
    defer allocator.free(esc_type);

    try buf.writer(allocator).print(
        "{{\"ws_id\":\"{s}\",\"session_id\":\"{s}\",\"event_id\":{d},\"timestamp\":{d},\"type\":\"{s}\"",
        .{ esc_ws, esc_session, event.event_id, event.ts, esc_type },
    );

    switch (event.payload) {
        .setup, .search => {},
        .user_prompt => |p| {
            if (p.content) |c| {
                try writeOptionalString(allocator, &buf, "content", c);
            }
            try writeOptionalString(allocator, &buf, "content_hash", p.content_hash);
        },
        .load => |p| {
            try writeOptionalString(allocator, &buf, "rule_id", p.rule_id);
            try writeOptionalString(allocator, &buf, "rule_hash", p.rule_hash);
        },
        .refer => |p| {
            try writeOptionalString(allocator, &buf, "rule_id", p.rule_id);
            try writeOptionalString(allocator, &buf, "rule_hash", p.rule_hash);
            try writeOptionalString(allocator, &buf, "constraint_id", p.constraint_id);
            try writeOptionalString(allocator, &buf, "reason", p.reason);
        },
        .agent_report => |p| {
            try writeOptionalString(allocator, &buf, "summary", p.summary);
        },
        .reject => |p| {
            if (p.reason) |r| {
                try writeOptionalString(allocator, &buf, "reason", r);
            }
        },
        .context_propose_create => |p| {
            try writeOptionalString(allocator, &buf, "path", p.path);
        },
        .context_propose_update => |p| {
            try writeOptionalString(allocator, &buf, "context_id", p.id);
        },
        .context_propose_rename => |p| {
            try writeOptionalString(allocator, &buf, "context_id", p.id);
            try writeOptionalString(allocator, &buf, "new_path", p.new_path);
        },
        .context_propose_delete => |p| {
            try writeOptionalString(allocator, &buf, "context_id", p.id);
        },
        .rule_propose_create => |p| {
            try writeOptionalString(allocator, &buf, "path", p.path);
        },
        .rule_propose_update => |p| {
            try writeOptionalString(allocator, &buf, "rule_id", p.id);
        },
        .rule_propose_rename => |p| {
            try writeOptionalString(allocator, &buf, "rule_id", p.id);
            try writeOptionalString(allocator, &buf, "new_path", p.new_path);
        },
        .rule_propose_delete => |p| {
            try writeOptionalString(allocator, &buf, "rule_id", p.id);
        },
    }

    try buf.appendSlice(allocator, "}\n");
    return try buf.toOwnedSlice(allocator);
}

fn writeOptionalString(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), key: []const u8, value: ?[]const u8) !void {
    const v = value orelse return;
    const esc = try encoding.jsonEscapeAlloc(allocator, v);
    defer allocator.free(esc);
    try buf.writer(allocator).print(",\"{s}\":\"{s}\"", .{ key, esc });
}

test "attestationFilePath is under ~/.clumsies/workspaces/{ws_id}/" {
    const p = try attestationFilePath(testing.allocator, "ws-test123");
    defer testing.allocator.free(p);
    try testing.expect(std.mem.indexOf(u8, p, "/.clumsies/workspaces/ws-test123/attestation.jsonl") != null);
}

test "serializeAttestationEvent: refer event with all fields" {
    const event: AttestationEvent = .{
        .ws_id = "ws-abc",
        .session_id = "sess-xyz",
        .event_id = 3,
        .ts = 1743753000000,
        .payload = .{
            .refer = .{
                .rule_id = "p-550e8400",
                .constraint_id = "c-2",
                .reason = "applying style",
            },
        },
    };
    const line = try serializeAttestationEvent(testing.allocator, event);
    defer testing.allocator.free(line);
    try testing.expect(std.mem.indexOf(u8, line, "\"ws_id\":\"ws-abc\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"session_id\":\"sess-xyz\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"event_id\":3") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"type\":\"refer\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"timestamp\":1743753000000") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"rule_id\":\"p-550e8400\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"constraint_id\":\"c-2\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"reason\":\"applying style\"") != null);
    try testing.expect(std.mem.endsWith(u8, line, "}\n"));
}

test "serializeAttestationEvent: setup omits payload fields" {
    const event: AttestationEvent = .{
        .ws_id = "ws-1",
        .session_id = "sess-1",
        .event_id = 0,
        .ts = 100,
        .payload = .setup,
    };
    const line = try serializeAttestationEvent(testing.allocator, event);
    defer testing.allocator.free(line);
    try testing.expect(std.mem.indexOf(u8, line, "\"rule_id\"") == null);
    try testing.expect(std.mem.indexOf(u8, line, "\"constraint_id\"") == null);
    try testing.expect(std.mem.indexOf(u8, line, "\"type\":\"setup\"") != null);
}

test "serializeAttestationEvent: user_prompt with content and hash" {
    const event: AttestationEvent = .{
        .ws_id = "ws-1",
        .session_id = "sess-1",
        .event_id = 1,
        .ts = 200,
        .payload = .{
            .user_prompt = .{
                .content_hash = "abc123",
                .content = "hello world",
            },
        },
    };
    const line = try serializeAttestationEvent(testing.allocator, event);
    defer testing.allocator.free(line);
    try testing.expect(std.mem.indexOf(u8, line, "\"type\":\"user_prompt\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"content\":\"hello world\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"content_hash\":\"abc123\"") != null);
}

test "serializeAttestationEvent: agent_report with summary" {
    const event: AttestationEvent = .{
        .ws_id = "ws-1",
        .session_id = "sess-1",
        .event_id = 5,
        .ts = 300,
        .payload = .{
            .agent_report = .{
                .summary = "Applied error-handling constraints",
            },
        },
    };
    const line = try serializeAttestationEvent(testing.allocator, event);
    defer testing.allocator.free(line);
    try testing.expect(std.mem.indexOf(u8, line, "\"type\":\"agent_report\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"summary\":\"Applied error-handling constraints\"") != null);
}
