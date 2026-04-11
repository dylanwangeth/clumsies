const std = @import("std");
const pg = @import("pg");
const reset = @import("reset.zig");
const pump = @import("pump.zig");

const Config = struct {
    db_host: []const u8,
    db_port: u16,
    db_name: []const u8,
    db_user: []const u8,
    db_password: []const u8,

    fn fromEnv() Config {
        return .{
            .db_host = getEnvStr("HUB_DB_HOST", "127.0.0.1"),
            .db_port = getEnvInt(u16, "HUB_DB_PORT", 5432),
            .db_name = getEnvStr("HUB_DB_NAME", "clumsies"),
            .db_user = getEnvStr("HUB_DB_USER", "clumsies"),
            .db_password = getEnvStr("HUB_DB_PASSWORD", "clumsies"),
        };
    }

    fn getEnvStr(key: []const u8, default: []const u8) []const u8 {
        return std.process.getEnvVarOwned(std.heap.page_allocator, key) catch return default;
    }

    fn getEnvInt(comptime T: type, key: []const u8, default: T) T {
        const val = std.process.getEnvVarOwned(std.heap.page_allocator, key) catch return default;
        return std.fmt.parseInt(T, val, 10) catch default;
    }
};

const log = std.log.scoped(.seed);

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    var do_reset = false;
    var do_pump = false;
    var interval_ms: u64 = 3000;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--reset")) {
            do_reset = true;
        } else if (std.mem.eql(u8, arg, "--pump")) {
            do_pump = true;
        } else if (std.mem.startsWith(u8, arg, "--interval=")) {
            interval_ms = std.fmt.parseInt(u64, arg["--interval=".len..], 10) catch 3000;
            if (interval_ms < 100) {
                log.err("--interval must be at least 100ms", .{});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else {
            log.err("unknown argument: {s}", .{arg});
            printUsage();
            std.process.exit(1);
        }
    }

    if (!do_reset and !do_pump) {
        log.err("specify --reset and/or --pump", .{});
        printUsage();
        std.process.exit(1);
    }

    const config = Config.fromEnv();

    log.info("connecting to {s}:{d}/{s}", .{ config.db_host, config.db_port, config.db_name });

    var pool = pg.Pool.init(std.heap.page_allocator, .{
        .size = 3,
        .connect = .{
            .host = config.db_host,
            .port = config.db_port,
        },
        .auth = .{
            .username = config.db_user,
            .database = config.db_name,
            .password = config.db_password,
            .timeout = 10_000,
        },
    }) catch |err| {
        log.err("failed to connect to database: {}", .{err});
        std.process.exit(1);
    };
    defer pool.deinit();

    if (do_reset) {
        reset.run(pool) catch |err| {
            log.err("reset failed: {}", .{err});
            std.process.exit(1);
        };
    }

    if (do_pump) {
        pump.run(pool, interval_ms) catch |err| {
            log.err("pump failed: {}", .{err});
            std.process.exit(1);
        };
    }

    log.info("done", .{});
}

fn printUsage() void {
    const usage =
        \\Usage: clumsies-seed [options]
        \\
        \\Options:
        \\  --reset          Truncate all tables and seed initial data
        \\  --pump           Continuously inject new data (Ctrl-C to stop)
        \\  --interval=N     Pump interval in milliseconds (default: 3000)
        \\  --help, -h       Show this help
        \\
        \\Examples:
        \\  clumsies-seed --reset              Reset database with seed data
        \\  clumsies-seed --pump               Start continuous data pump
        \\  clumsies-seed --reset --pump       Reset then pump
        \\  clumsies-seed --pump --interval=1000  Pump every second
        \\
        \\Environment variables:
        \\  HUB_DB_HOST      Database host (default: 127.0.0.1)
        \\  HUB_DB_PORT      Database port (default: 5432)
        \\  HUB_DB_NAME      Database name (default: clumsies)
        \\  HUB_DB_USER      Database user (default: clumsies)
        \\  HUB_DB_PASSWORD  Database password (default: clumsies)
        \\
    ;
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.Writer.init(std.fs.File.stderr(), &buf);
    defer w.interface.flush() catch {};
    w.interface.writeAll(usage) catch {};
}
