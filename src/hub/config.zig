//! Hub server configuration from environment variables: database connection parameters, listen
//! address, and runtime settings.
const std = @import("std");

host: []const u8,
port: u16,
db_host: []const u8,
db_port: u16,
db_name: []const u8,
db_user: []const u8,
db_password: []const u8,
token_ttl_seconds: u32,
refresh_token_ttl_seconds: u32,

const Config = @This();

pub fn fromEnv(env_map: *const std.process.EnvMap) Config {
    return .{
        .host = getEnvStr(env_map, "HUB_HOST", "0.0.0.0"),
        .port = getEnvInt(env_map, u16, "HUB_PORT", 8400),
        .db_host = getEnvStr(env_map, "HUB_DB_HOST", "127.0.0.1"),
        .db_port = getEnvInt(env_map, u16, "HUB_DB_PORT", 5432),
        .db_name = getEnvStr(env_map, "HUB_DB_NAME", "clumsies"),
        .db_user = getEnvStr(env_map, "HUB_DB_USER", "clumsies"),
        .db_password = getEnvStr(env_map, "HUB_DB_PASSWORD", "clumsies"),
        .token_ttl_seconds = getEnvInt(env_map, u32, "HUB_TOKEN_TTL", 3600),
        .refresh_token_ttl_seconds = getEnvInt(env_map, u32, "HUB_REFRESH_TOKEN_TTL", 90 * 24 * 60 * 60),
    };
}

fn getEnvStr(env_map: *const std.process.EnvMap, key: []const u8, default: []const u8) []const u8 {
    return env_map.get(key) orelse default;
}

fn getEnvInt(env_map: *const std.process.EnvMap, comptime T: type, key: []const u8, default: T) T {
    const val = env_map.get(key) orelse return default;
    return std.fmt.parseInt(T, val, 10) catch default;
}
