const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Shell = @import("shell.zig").Shell;
const auth_mod = @import("../auth.zig");
const api = @import("api.zig");
const tasks = @import("tasks.zig");
const env_util = @import("clumsies_lib").util.env_util;

pub fn run(
    io: std.Io,
    environ: std.process.Environ,
    env_map: *std.process.Environ.Map,
) !void {
    env_util.init(environ);

    var da: std.heap.DebugAllocator(.{}) = .init;
    defer _ = da.deinit();
    const allocator = da.allocator();

    var api_state = api.state.ApiState.init(allocator);
    api_state.bindAllocator();
    defer api_state.deinit();
    // Wait for every dispatcher-spawned worker to finish before tearing
    // down the allocator; otherwise a late worker would write through
    // freed memory. Runs before api_state.deinit thanks to reverse-defer
    // order.
    defer api_state.thread_registry.joinAll(allocator);

    // startFetch registers its spawned bootstrap thread into
    // api_state.thread_registry, so joinAll above catches it on exit.
    if (auth_mod.loadAuth(allocator)) |auth_info| {
        defer auth_info.deinit(allocator);
        api.fetch.startFetch(&api_state, auth_info.server_url, auth_info.username, auth_info.access_token, auth_info.refresh_token) catch {};
        tasks.attestation_upload.start(&api_state) catch {};
    } else |_| {}

    var tty_buffer: [4096]u8 = undefined;
    var app = try vxfw.App.init(io, allocator, env_map, &tty_buffer);
    defer app.deinit();

    if (builtin.os.tag != .windows) {
        var title_buffer: [64]u8 = undefined;
        var title_writer = std.Io.File.Writer.init(std.Io.File.stdout(), io, &title_buffer);
        defer title_writer.interface.flush() catch {};
        title_writer.interface.writeAll("\x1b]2;clumsies\x07") catch {};
    }

    var dashboard = Shell.init(&api_state, &app, env_map, environ, io);
    defer dashboard.deinit();
    try app.run(dashboard.widget(), .{});
}

pub fn main(init: std.process.Init) !void {
    try run(init.io, init.minimal.environ, init.environ_map);
}
