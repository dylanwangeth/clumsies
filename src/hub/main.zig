const std = @import("std");
const build_options = @import("build_options");
const runtime_logger = @import("clumsies_lib").runtime_logger;
const hub = @import("root.zig");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = runtime_logger.logFn,
};

const log = std.log.scoped(.hub);

pub fn main() !void {
    var da: std.heap.DebugAllocator(.{}) = .init;
    defer _ = da.deinit();
    const allocator = da.allocator();

    initHubLogger(allocator);
    defer runtime_logger.deinit();

    const config = hub.Config.fromEnv();

    log.info("clumsies-hub v{s} starting on :{d}", .{ build_options.version, config.port });

    var pool = try hub.db.initPool(allocator, config);
    defer pool.deinit();

    try hub.db.migrate(pool);
    log.info("database migrations applied", .{});

    try hub.db.bootstrap(pool);

    var server = try hub.Server.init(allocator, config, pool);
    defer server.deinit();

    log.info("listening on http://127.0.0.1:{d}", .{config.port});

    server.listen() catch |err| {
        log.err("server error: {}", .{err});
        return err;
    };
}

fn initHubLogger(allocator: std.mem.Allocator) void {
    var log_level: std.log.Level = .info;
    var invalid_level: ?[]u8 = null;
    defer if (invalid_level) |raw| allocator.free(raw);

    if (std.process.getEnvVarOwned(allocator, "CLUMSIES_LOG_LEVEL")) |raw| {
        if (runtime_logger.parseLevel(raw)) |parsed| {
            log_level = parsed;
            allocator.free(raw);
        } else {
            invalid_level = raw;
        }
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => {},
    }

    runtime_logger.initBestEffort(.{ .level = log_level, .sink = .stderr });
    if (invalid_level) |raw| runtime_logger.noteInvalidLevel(raw);
}

test {
    _ = @import("root.zig");
}
