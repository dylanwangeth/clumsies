pub const EventType = enum {
    setup,
    search,
    load,
    refer,
    session_input,
};

pub const TraceEvent = struct {
    event_id: u64,
    session_id: []const u8,
    ws_id: []const u8,
    type: EventType,
    timestamp: u64,
    prompt_id: ?[]const u8 = null,
    prompt_hash: ?[]const u8 = null,
    constraint_id: ?[]const u8 = null,
    override_base_hash: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    content: ?[]const u8 = null,
    content_hash: ?[]const u8 = null,
};
