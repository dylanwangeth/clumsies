const std = @import("std");
const build_options = @import("build_options");
const logger = @import("clumsies_lib").logger;
const hub = @import("root.zig");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logger.logFn,
};

const log = std.log.scoped(.hub);

pub fn main() !void {
    var da: std.heap.DebugAllocator(.{}) = .init;
    defer _ = da.deinit();
    const allocator = da.allocator();

    var env_map = try loadEnvMap(allocator);
    defer env_map.deinit();

    initHubLogger(&env_map);
    defer logger.deinit();

    const config = hub.Config.fromEnv(&env_map);

    log.info("clumsies-hub v{s} starting on {s}:{d}", .{ build_options.version, config.host, config.port });

    var pool = hub.db.initPool(allocator, config) catch |err| {
        log.err("database connection failed for user \"{s}\" at {s}:{d}/{s}: {}", .{
            config.db_user,
            config.db_host,
            config.db_port,
            config.db_name,
            err,
        });
        std.process.exit(1);
    };
    defer pool.deinit();

    try hub.db.migrate(pool);
    log.info("database migrations applied", .{});

    try hub.db.bootstrap(pool, &env_map);

    var server = try hub.Server.init(allocator, config, pool);
    defer server.deinit();

    log.info("listening on http://{s}:{d}", .{ config.host, config.port });

    server.listen() catch |err| {
        log.err("server error: {}", .{err});
        return err;
    };
}

fn loadEnvMap(allocator: std.mem.Allocator) !std.process.EnvMap {
    var env_map = try std.process.getEnvMap(allocator);
    errdefer env_map.deinit();

    loadDotEnv(allocator, &env_map);
    return env_map;
}

fn loadDotEnv(allocator: std.mem.Allocator, env_map: *std.process.EnvMap) void {
    const file = std.fs.cwd().openFile(".env", .{}) catch return;
    defer file.close();

    const size = file.getEndPos() catch return;
    if (size == 0) return;
    const alloc_size = std.math.cast(usize, size) orelse return;
    const contents = allocator.alloc(u8, alloc_size) catch return;
    defer allocator.free(contents);

    var buf: [4096]u8 = undefined;
    var reader = std.fs.File.Reader.init(file, &buf);
    reader.interface.readSliceAll(contents) catch return;

    var iter = std.mem.splitSequence(u8, contents, "\n");
    while (iter.next()) |line| {
        applyEnvLine(allocator, env_map, line);
    }
}

fn applyEnvLine(allocator: std.mem.Allocator, env_map: *std.process.EnvMap, line: []const u8) void {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return;
    const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return;
    const key = std.mem.trim(u8, trimmed[0..eq], " \t");
    const raw_value = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
    const value = stripQuotes(raw_value);
    if (env_map.get(key) != null) return;

    const key_owned = allocator.dupe(u8, key) catch return;
    const val_owned = allocator.dupe(u8, value) catch {
        allocator.free(key_owned);
        return;
    };
    env_map.put(key_owned, val_owned) catch {
        allocator.free(key_owned);
        allocator.free(val_owned);
    };
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and ((s[0] == '"' and s[s.len - 1] == '"') or (s[0] == '\'' and s[s.len - 1] == '\''))) {
        return s[1 .. s.len - 1];
    }
    return s;
}

fn initHubLogger(env_map: *const std.process.EnvMap) void {
    var level: std.log.Level = .info;
    var invalid_level: ?[]const u8 = null;
    if (env_map.get("CLUMSIES_LOG_LEVEL")) |raw| {
        if (logger.parseLevel(raw)) |parsed| {
            level = parsed;
        } else {
            invalid_level = raw;
        }
    }
    logger.initBestEffort(.{ .level = level, .sink = .stderr });
    if (invalid_level) |raw| logger.noteInvalidLevel(raw);
}

test {
    _ = @import("root.zig");
}
