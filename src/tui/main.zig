const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Dashboard = @import("app.zig").Dashboard;

pub fn main() !void {
    var da: std.heap.DebugAllocator(.{}) = .init;
    defer _ = da.deinit();
    const allocator = da.allocator();

    var app = try vxfw.App.init(allocator);
    defer app.deinit();

    // Set terminal title (OSC 2)
    const stdout = std.posix.STDOUT_FILENO;
    _ = std.posix.write(stdout, "\x1b]2;clumsies hub\x07") catch {};

    var dashboard = Dashboard.init();
    try app.run(dashboard.widget(), .{});
}
