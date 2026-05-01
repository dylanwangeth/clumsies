const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Shell = @import("shell.zig").Shell;
const auth_mod = @import("../auth.zig");
const api = @import("api.zig");
const tasks = @import("tasks.zig");

pub fn run() !void {
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
        api.fetch.startFetch(&api_state, auth_info.hub_url, auth_info.access_token) catch {};
        tasks.attestation_upload.start(&api_state) catch {};
    } else |_| {}

    var app = try vxfw.App.init(allocator);
    defer app.deinit();

    if (builtin.os.tag != .windows) {
        var title_buffer: [64]u8 = undefined;
        var title_writer = std.fs.File.Writer.init(std.fs.File.stdout(), &title_buffer);
        defer title_writer.interface.flush() catch {};
        title_writer.interface.writeAll("\x1b]2;clumsies hub\x07") catch {};
    }

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    var dashboard = Shell.init(&api_state, &app, &env_map);
    defer dashboard.deinit();
    try app.run(dashboard.widget(), .{});
}

pub fn main() !void {
    try run();
}
