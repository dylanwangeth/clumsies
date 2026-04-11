const std = @import("std");
const build_options = @import("build_options");
const hub = @import("hub/root.zig");

pub fn main() !void {
    var da: std.heap.DebugAllocator(.{}) = .init;
    defer _ = da.deinit();
    const allocator = da.allocator();

    var buf: [4096]u8 = undefined;
    var stderr = std.fs.File.Writer.init(std.fs.File.stderr(), &buf);
    defer stderr.interface.flush() catch {};
    const log = &stderr.interface;

    const config = hub.Config.fromEnv();

    try log.print("clumsies-hub v{s} starting on :{d}\n", .{ build_options.version, config.port });

    var pool = try hub.db.initPool(allocator, config);
    defer pool.deinit();

    try hub.db.migrate(pool);
    try log.print("database migrations applied\n", .{});

    try hub.db.bootstrap(pool);

    var server = try hub.Server.init(allocator, config, pool);
    defer server.deinit();

    try log.print("listening on http://127.0.0.1:{d}\n", .{config.port});
    stderr.interface.flush() catch {};

    server.listen() catch |err| {
        try log.print("server error: {}\n", .{err});
        return err;
    };
}

test {
    _ = @import("hub/root.zig");
}
