const std = @import("std");
const build_options = @import("build_options");
const logger = @import("clumsies_lib").logger;
const hub = @import("root.zig");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logger.logFn,
};

const log = std.log.scoped(.hub);

const StartupError = error{HubStartupFailed};

pub fn main() void {
    var da: std.heap.DebugAllocator(.{}) = .init;
    defer _ = da.deinit();

    run(da.allocator()) catch |err| {
        var stderr_buffer: [4096]u8 = undefined;
        var stderr_file_writer = std.fs.File.Writer.init(std.fs.File.stderr(), &stderr_buffer);
        defer stderr_file_writer.interface.flush() catch {};
        stderr_file_writer.interface.print("Error: {s}\n", .{@errorName(err)}) catch {};
        std.process.exit(1);
    };
}

pub fn run(allocator: std.mem.Allocator) !void {
    var env_map = try loadEnvMap(allocator);
    defer env_map.deinit();

    initHubLogger(&env_map);
    defer logger.deinit();

    const config = hub.Config.fromEnv(&env_map);

    log.info("clumsies hub v{s} starting on {s}:{d}", .{ build_options.version, config.host, config.port });

    var pool = hub.db.initPool(allocator, config) catch |err| {
        log.err("database connection failed for user \"{s}\" at {s}:{d}/{s}: {}", .{
            config.db_user,
            config.db_host,
            config.db_port,
            config.db_name,
            err,
        });
        return StartupError.HubStartupFailed;
    };
    defer pool.deinit();

    try hub.db.migrate(pool);
    log.info("database migrations applied", .{});

    try hub.db.bootstrap(pool, &env_map);

    var server = try hub.Server.init(allocator, config, pool);
    defer server.deinit();

    log.info("listening on http://{s}:{d}", .{ config.host, config.port });

    server.listen() catch |err| {
        switch (err) {
            error.AddressInUse => log.err(
                "failed to listen on {s}:{d}: address already in use",
                .{ config.host, config.port },
            ),
            else => log.err("server error: {}", .{err}),
        }
        return StartupError.HubStartupFailed;
    };
}

fn loadEnvMap(allocator: std.mem.Allocator) !std.process.EnvMap {
    return logger.loadEnvMap(allocator);
}

fn initHubLogger(env_map: *const std.process.EnvMap) void {
    const config = logger.configFromEnvMap(env_map);
    logger.initBestEffort(.{ .level = config.level, .sink = .stderr });
    if (config.invalid_level) |raw| logger.noteInvalidLevel(raw);
}

test {
    _ = @import("root.zig");
}
