//! MCP session state. The host session ID is supplied by memory.setup so hook
//! events and MCP tool events are written to the same attestation log.
const std = @import("std");
const attestation = @import("../attestation.zig");
const host_session = @import("../host_session.zig");
const workspace_config = @import("../workspace_config.zig");

pub const Session = struct {
    ws_id: []const u8,
    session_id: ?[]const u8 = null,

    pub fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        allocator.free(self.ws_id);
        if (self.session_id) |session_id| allocator.free(session_id);
    }

    pub fn bind(self: *Session, allocator: std.mem.Allocator, session_id: []const u8) !void {
        if (!host_session.isSafeSessionId(session_id)) return error.InvalidSessionId;
        if (self.session_id) |current| {
            if (std.mem.eql(u8, current, session_id)) return;
            return error.SessionAlreadyBound;
        }

        self.session_id = try allocator.dupe(u8, session_id);
        self.recordEvent(allocator, .setup);
    }

    pub fn recordEvent(
        self: *Session,
        allocator: std.mem.Allocator,
        payload: attestation.AttestationEvent.Payload,
    ) void {
        const session_id = self.session_id orelse {
            std.log.warn(
                "ignored attestation event type='{s}' before memory.setup bound a session",
                .{attestation.payloadTypeTag(payload)},
            );
            return;
        };
        attestation.appendAttestationEvent(allocator, .{
            .ws_id = self.ws_id,
            .session_id = session_id,
            .event_id = attestation.nextEventId(),
            .ts = std.time.milliTimestamp(),
            .payload = payload,
        }) catch |err| {
            std.log.err(
                "failed to append attestation event type='{s}' session_id='{s}': {}",
                .{ attestation.payloadTypeTag(payload), session_id, err },
            );
        };
    }
};

pub fn init(allocator: std.mem.Allocator, workspace_root: []const u8) !Session {
    const binding = try workspace_config.resolveWorkspace(allocator, workspace_root);
    defer allocator.free(binding.name);
    errdefer allocator.free(binding.ws_id);

    return .{
        .ws_id = binding.ws_id,
    };
}
