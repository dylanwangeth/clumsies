//! MCP session state. Holds the workspace ID and session ID for the current agent interaction.
//! Provides recordEvent() to append attestation events — the session ID links all attestation
//! events from one agent run together for aggregation.
const std = @import("std");
const attestation = @import("../attestation.zig");
const host_session = @import("../host_session.zig");
const workspace_config = @import("../workspace_config.zig");

pub const Session = struct {
    ws_id: []const u8,
    session_id: [32]u8,
    event_counter: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    pub fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        allocator.free(self.ws_id);
    }

    pub fn nextEventId(self: *Session) i64 {
        return self.event_counter.fetchAdd(1, .monotonic);
    }

    pub fn recordEvent(
        self: *Session,
        allocator: std.mem.Allocator,
        payload: attestation.AttestationEvent.Payload,
    ) void {
        const event_id = self.nextEventId();
        attestation.appendAttestationEvent(allocator, .{
            .ws_id = self.ws_id,
            .session_id = self.session_id[0..],
            .event_id = event_id,
            .ts = std.time.milliTimestamp(),
            .payload = payload,
        }) catch |err| {
            std.log.err(
                "failed to append attestation event type='{s}' session_id='{s}': {}",
                .{ attestation.payloadTypeTag(payload), self.session_id[0..], err },
            );
        };
    }
};

pub fn init(allocator: std.mem.Allocator, workspace_root: []const u8) !Session {
    const binding = try workspace_config.resolveWorkspace(allocator, workspace_root);
    defer allocator.free(binding.name);

    const session_id = host_session.resolveSessionId(allocator) orelse randomSessionId();

    var session: Session = .{
        .ws_id = binding.ws_id,
        .session_id = session_id,
        .event_counter = std.atomic.Value(i64).init(0),
    };

    session.recordEvent(allocator, .setup);
    return session;
}

fn randomSessionId() [32]u8 {
    var rand_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);

    var session_id: [32]u8 = undefined;
    const hex = "0123456789abcdef";
    for (rand_bytes, 0..) |byte, i| {
        session_id[i * 2] = hex[byte >> 4];
        session_id[i * 2 + 1] = hex[byte & 0x0f];
    }
    return session_id;
}
