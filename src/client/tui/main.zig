const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Dashboard = @import("app.zig").Dashboard;
const auth_mod = @import("../auth.zig");
const api = @import("api.zig");

fn recoverPanic(msg: []const u8, ra: ?usize) noreturn {
    vaxis.recover();
    std.debug.defaultPanic(msg, ra);
}

pub const panic = std.debug.FullPanic(recoverPanic);

pub fn run() !void {
    var da: std.heap.DebugAllocator(.{}) = .init;
    defer _ = da.deinit();
    const allocator = da.allocator();

    var api_state = api.state.ApiState.init(allocator);
    api_state.bindAllocator();
    defer api_state.deinit();

    var fetch_thread: ?std.Thread = null;
    defer if (fetch_thread) |t| t.join();
    if (auth_mod.loadAuth(allocator)) |auth_info| {
        defer auth_info.deinit(allocator);
        fetch_thread = api.fetch.startFetch(&api_state, auth_info.hub_url, auth_info.access_token) catch null;
    } else |_| {}

    var app = try vxfw.App.init(allocator);
    defer app.deinit();

    if (builtin.os.tag != .windows) {
        var title_buffer: [64]u8 = undefined;
        var title_writer = std.fs.File.Writer.init(std.fs.File.stdout(), &title_buffer);
        defer title_writer.interface.flush() catch {};
        title_writer.interface.writeAll("\x1b]2;clumsies hub\x07") catch {};
    }

    var dashboard = Dashboard.init(&api_state);
    defer dashboard.deinit();
    try app.run(dashboard.widget(), .{});
}

pub fn main() !void {
    try run();
}
