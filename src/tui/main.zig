const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Dashboard = @import("app.zig").Dashboard;
const auth_mod = @import("auth.zig");
const api = @import("api.zig");

pub fn main() !void {
    var da: std.heap.DebugAllocator(.{}) = .init;
    defer _ = da.deinit();
    const allocator = da.allocator();

    var api_state = api.ApiState.init(allocator);
    defer api_state.deinit();

    var fetch_thread: ?std.Thread = null;
    if (auth_mod.loadAuth(allocator)) |auth_info| {
        defer auth_info.deinit(allocator);
        fetch_thread = api.startFetch(&api_state, auth_info.hub_url, auth_info.access_token) catch null;
    } else |_| {}

    var app = try vxfw.App.init(allocator);
    defer app.deinit();

    const stdout = std.posix.STDOUT_FILENO;
    _ = std.posix.write(stdout, "\x1b]2;clumsies hub\x07") catch {};

    var dashboard = Dashboard.init(&api_state);
    try app.run(dashboard.widget(), .{});

    if (fetch_thread) |t| t.join();
}
