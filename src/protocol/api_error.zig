//! Shared error response envelope. Every non-2xx response from Hub carries
//! {"error": {"code": "...", "message": "..."}}. Encoder (hub/api_error.zig)
//! and decoders (cli, tui, mcp) import this module so the wire shape stays
//! consistent across artifacts.

pub const ApiError = struct {
    code: []const u8,
    message: []const u8,
};

pub const ApiErrorEnvelope = struct {
    @"error": ApiError,
};
