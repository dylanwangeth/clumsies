//! Attestation event recording. Each MCP setup/discover/load/refer/submit interaction
//! is serialized as an AttestationEvent and appended to
//! ~/.clumsies/workspaces/{ws_id}/attestation/{session_id}.jsonl. The Hub later
//! ingests these events via POST /api/attestations to compute constraint-level usage statistics.
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
        setup: SetupPayload,
        user_prompt: UserPromptPayload,
        discover: DiscoverPayload,
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
        mpf_propose_create: ProposeCreatePayload,
        mpf_propose_update: ProposeUpdatePayload,
        mpf_propose_delete: ProposeDeletePayload,
        draft_discard: DraftDiscardPayload,
    };

    pub const SetupPayload = struct {
        mpf_hash: ?[]const u8 = null,
        mpf_content: ?[]const u8 = null,
        mpf_changed: ?bool = null,
    };

    pub const UserPromptPayload = struct {
        content_hash: []const u8,
        content: ?[]const u8 = null,
        model: ?[]const u8 = null,
    };

    pub const DiscoverPayload = struct {
        kind: ?[]const u8 = null,
        group: ?[]const u8 = null,
        query: ?[]const u8 = null,
        result_count: ?u32 = null,
        result_names: ?[]const u8 = null,
    };

    pub const LoadPayload = struct {
        rule_id: []const u8,
        rule_hash: []const u8,
    };

    pub const ReferPayload = struct {
        rule_id: []const u8,
        rule_hash: ?[]const u8 = null,
        constraint_id: []const u8,
        constraint_name: ?[]const u8 = null,
        constraint_text: ?[]const u8 = null,
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
        path: []const u8,
    };

    pub const ProposeRenamePayload = struct {
        id: []const u8,
        path: []const u8,
        new_path: []const u8,
    };

    pub const ProposeDeletePayload = struct {
        id: []const u8,
        path: []const u8,
    };

    pub const DraftDiscardPayload = struct {
        resource: []const u8,
        id: []const u8,
        path: []const u8,
    };
};

/// Generate an opaque idempotency key for local attestation uploads.
/// Ordering must use `timestamp`; `event_id` only backs Hub de-duplication.
pub fn nextEventId() i64 {
    const raw = std.crypto.random.int(u64) & @as(u64, @intCast(std.math.maxInt(i64)));
    return @intCast(raw);
}

/// Map Payload tag to the JSON "type" string.
pub fn payloadTypeTag(payload: AttestationEvent.Payload) []const u8 {
    return switch (payload) {
        .setup => "setup",
        .user_prompt => "user_prompt",
        .discover => "discover",
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
        .mpf_propose_create => "mpf_propose_create",
        .mpf_propose_update => "mpf_propose_update",
        .mpf_propose_delete => "mpf_propose_delete",
        .draft_discard => "draft_discard",
    };
}

/// Get the per-session attestation log path: ~/.clumsies/workspaces/{ws_id}/attestation/{session_id}.jsonl
pub fn sessionAttestationFilePath(allocator: std.mem.Allocator, ws_id: []const u8, session_id: []const u8) ![]const u8 {
    const dir = try attestationLogDirPath(allocator, ws_id);
    defer allocator.free(dir);
    const file_name = try std.fmt.allocPrint(allocator, "{s}.jsonl", .{session_id});
    defer allocator.free(file_name);
    return try std.fs.path.join(allocator, &.{ dir, file_name });
}

/// Get the per-session upload cursor path for an attestation log.
pub fn sessionCursorFilePath(allocator: std.mem.Allocator, ws_id: []const u8, session_id: []const u8) ![]const u8 {
    const dir = try attestationLogDirPath(allocator, ws_id);
    defer allocator.free(dir);
    const file_name = try std.fmt.allocPrint(allocator, "{s}.cursor", .{session_id});
    defer allocator.free(file_name);
    return try std.fs.path.join(allocator, &.{ dir, file_name });
}

pub fn attestationLogDirPath(allocator: std.mem.Allocator, ws_id: []const u8) ![]const u8 {
    const base = try getBasePath(allocator);
    defer allocator.free(base);
    return try std.fs.path.join(allocator, &.{ base, "workspaces", ws_id, "attestation" });
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

    const attestation_dir = try std.fs.path.join(allocator, &.{ ws_dir, "attestation" });
    defer allocator.free(attestation_dir);
    std.fs.makeDirAbsolute(attestation_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

/// Append an attestation event to the workspace's per-session attestation log.
/// The JSON format matches the server `POST /api/attestations` AttestationEventInput shape.
pub fn appendAttestationEvent(allocator: std.mem.Allocator, event: AttestationEvent) !void {
    try ensureWorkspaceDir(allocator, event.ws_id);

    const attestation_path = try sessionAttestationFilePath(allocator, event.ws_id, event.session_id);
    defer allocator.free(attestation_path);

    var file = try std.fs.createFileAbsolute(attestation_path, .{ .truncate = false });
    defer file.close();
    const end_pos = try file.getEndPos();

    const line = try serializeAttestationEvent(allocator, event);
    defer allocator.free(line);

    var write_buf: [4096]u8 = undefined;
    var fw = std.fs.File.Writer.init(file, &write_buf);
    try fw.seekTo(end_pos);
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
        .setup => |p| {
            try writeOptionalString(allocator, &buf, "mpf_hash", p.mpf_hash);
            try writeOptionalString(allocator, &buf, "mpf_content", p.mpf_content);
            try writeOptionalBool(allocator, &buf, "mpf_changed", p.mpf_changed);
        },
        .discover => |p| {
            try writeOptionalString(allocator, &buf, "kind", p.kind);
            try writeOptionalString(allocator, &buf, "group", p.group);
            try writeOptionalString(allocator, &buf, "query", p.query);
            try writeOptionalU32(allocator, &buf, "result_count", p.result_count);
            try writeOptionalString(allocator, &buf, "result_names", p.result_names);
        },
        .user_prompt => |p| {
            if (p.content) |c| {
                try writeOptionalString(allocator, &buf, "content", c);
            }
            try writeOptionalString(allocator, &buf, "content_hash", p.content_hash);
            try writeOptionalString(allocator, &buf, "model", p.model);
        },
        .load => |p| {
            try writeOptionalString(allocator, &buf, "rule_id", p.rule_id);
            try writeOptionalString(allocator, &buf, "rule_hash", p.rule_hash);
        },
        .refer => |p| {
            try writeOptionalString(allocator, &buf, "rule_id", p.rule_id);
            try writeOptionalString(allocator, &buf, "rule_hash", p.rule_hash);
            try writeOptionalString(allocator, &buf, "constraint_id", p.constraint_id);
            try writeOptionalString(allocator, &buf, "constraint_name", p.constraint_name);
            try writeOptionalString(allocator, &buf, "constraint_text", p.constraint_text);
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
            try writeOptionalString(allocator, &buf, "path", p.path);
        },
        .context_propose_rename => |p| {
            try writeOptionalString(allocator, &buf, "context_id", p.id);
            try writeOptionalString(allocator, &buf, "path", p.path);
            try writeOptionalString(allocator, &buf, "new_path", p.new_path);
        },
        .context_propose_delete => |p| {
            try writeOptionalString(allocator, &buf, "context_id", p.id);
            try writeOptionalString(allocator, &buf, "path", p.path);
        },
        .rule_propose_create => |p| {
            try writeOptionalString(allocator, &buf, "path", p.path);
        },
        .rule_propose_update => |p| {
            try writeOptionalString(allocator, &buf, "rule_id", p.id);
            try writeOptionalString(allocator, &buf, "path", p.path);
        },
        .rule_propose_rename => |p| {
            try writeOptionalString(allocator, &buf, "rule_id", p.id);
            try writeOptionalString(allocator, &buf, "path", p.path);
            try writeOptionalString(allocator, &buf, "new_path", p.new_path);
        },
        .rule_propose_delete => |p| {
            try writeOptionalString(allocator, &buf, "rule_id", p.id);
            try writeOptionalString(allocator, &buf, "path", p.path);
        },
        .mpf_propose_create => |p| {
            try writeOptionalString(allocator, &buf, "path", p.path);
        },
        .mpf_propose_update => |p| {
            try writeOptionalString(allocator, &buf, "mpf_id", p.id);
            try writeOptionalString(allocator, &buf, "path", p.path);
        },
        .mpf_propose_delete => |p| {
            try writeOptionalString(allocator, &buf, "mpf_id", p.id);
            try writeOptionalString(allocator, &buf, "path", p.path);
        },
        .draft_discard => |p| {
            try writeOptionalString(allocator, &buf, "resource", p.resource);
            try writeOptionalString(allocator, &buf, "id", p.id);
            try writeOptionalString(allocator, &buf, "path", p.path);
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

fn writeOptionalBool(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), key: []const u8, value: ?bool) !void {
    const v = value orelse return;
    try buf.writer(allocator).print(",\"{s}\":{s}", .{ key, if (v) "true" else "false" });
}

fn writeOptionalU32(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), key: []const u8, value: ?u32) !void {
    const v = value orelse return;
    try buf.writer(allocator).print(",\"{s}\":{d}", .{ key, v });
}

test "sessionAttestationFilePath is under workspace attestation directory" {
    const p = try sessionAttestationFilePath(testing.allocator, "ws-test123", "sess-abc");
    defer testing.allocator.free(p);
    try testing.expect(std.mem.indexOf(u8, p, "/.clumsies/workspaces/ws-test123/attestation/sess-abc.jsonl") != null);
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
                .constraint_name = "Use final-form comments",
                .constraint_text = "Write final-form comments only.",
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
    try testing.expect(std.mem.indexOf(u8, line, "\"constraint_name\":\"Use final-form comments\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"constraint_text\":\"Write final-form comments only.\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"reason\":\"applying style\"") != null);
    try testing.expect(std.mem.endsWith(u8, line, "}\n"));
}

test "serializeAttestationEvent: setup omits payload fields" {
    const event: AttestationEvent = .{
        .ws_id = "ws-1",
        .session_id = "sess-1",
        .event_id = 0,
        .ts = 100,
        .payload = .{ .setup = .{} },
    };
    const line = try serializeAttestationEvent(testing.allocator, event);
    defer testing.allocator.free(line);
    try testing.expect(std.mem.indexOf(u8, line, "\"rule_id\"") == null);
    try testing.expect(std.mem.indexOf(u8, line, "\"constraint_id\"") == null);
    try testing.expect(std.mem.indexOf(u8, line, "\"type\":\"setup\"") != null);
}

test "serializeAttestationEvent: setup includes bootstrap metadata" {
    const event: AttestationEvent = .{
        .ws_id = "ws-1",
        .session_id = "sess-1",
        .event_id = 0,
        .ts = 100,
        .payload = .{ .setup = .{
            .mpf_hash = "sha256:abc",
            .mpf_content = "META_PROMPT",
            .mpf_changed = true,
        } },
    };
    const line = try serializeAttestationEvent(testing.allocator, event);
    defer testing.allocator.free(line);
    try testing.expect(std.mem.indexOf(u8, line, "\"mpf_hash\":\"sha256:abc\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"mpf_content\":\"META_PROMPT\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"mpf_changed\":true") != null);
}

test "serializeAttestationEvent: discover includes query metadata" {
    const event: AttestationEvent = .{
        .ws_id = "ws-1",
        .session_id = "sess-1",
        .event_id = 1,
        .ts = 101,
        .payload = .{ .discover = .{
            .kind = "rule",
            .group = "zig",
            .query = "style",
            .result_count = 7,
            .result_names = "ZIG_STYLE, ZIG_TOOLCHAIN",
        } },
    };
    const line = try serializeAttestationEvent(testing.allocator, event);
    defer testing.allocator.free(line);
    try testing.expect(std.mem.indexOf(u8, line, "\"type\":\"discover\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"kind\":\"rule\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"group\":\"zig\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"query\":\"style\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"result_count\":7") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"result_names\":\"ZIG_STYLE, ZIG_TOOLCHAIN\"") != null);
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
                .model = "gpt-5.5",
            },
        },
    };
    const line = try serializeAttestationEvent(testing.allocator, event);
    defer testing.allocator.free(line);
    try testing.expect(std.mem.indexOf(u8, line, "\"type\":\"user_prompt\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"content\":\"hello world\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"content_hash\":\"abc123\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"model\":\"gpt-5.5\"") != null);
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

test "serializeAttestationEvent: propose draft includes path metadata" {
    const event: AttestationEvent = .{
        .ws_id = "ws-1",
        .session_id = "sess-1",
        .event_id = 6,
        .ts = 301,
        .payload = .{ .rule_propose_rename = .{
            .id = "p-1",
            .path = "coding/OLD.md",
            .new_path = "coding/NEW.md",
        } },
    };
    const line = try serializeAttestationEvent(testing.allocator, event);
    defer testing.allocator.free(line);
    try testing.expect(std.mem.indexOf(u8, line, "\"type\":\"rule_propose_rename\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"rule_id\":\"p-1\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"path\":\"coding/OLD.md\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"new_path\":\"coding/NEW.md\"") != null);
}
