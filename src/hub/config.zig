//! Hub server configuration from environment variables: database connection parameters, listen
//! address, and runtime settings.
const std = @import("std");

port: u16,
db_host: []const u8,
db_port: u16,
db_name: []const u8,
db_user: []const u8,
db_password: []const u8,
token_ttl_seconds: u32,

const Config = @This();

pub fn fromEnv() Config {
    return .{
        .port = getEnvInt(u16, "HUB_PORT", 8400),
        .db_host = getEnvStr("HUB_DB_HOST", "127.0.0.1"),
        .db_port = getEnvInt(u16, "HUB_DB_PORT", 5432),
        .db_name = getEnvStr("HUB_DB_NAME", "clumsies"),
        .db_user = getEnvStr("HUB_DB_USER", "clumsies"),
        .db_password = getEnvStr("HUB_DB_PASSWORD", "clumsies"),
        .token_ttl_seconds = getEnvInt(u32, "HUB_TOKEN_TTL", 3600),
    };
}

fn getEnvStr(key: []const u8, default: []const u8) []const u8 {
    return std.process.getEnvVarOwned(std.heap.page_allocator, key) catch return default;
}

fn getEnvInt(comptime T: type, key: []const u8, default: T) T {
    const val = std.process.getEnvVarOwned(std.heap.page_allocator, key) catch return default;
    return std.fmt.parseInt(T, val, 10) catch default;
}
