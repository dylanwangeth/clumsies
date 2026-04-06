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

    var dashboard = Dashboard.init();
    try app.run(dashboard.widget(), .{});
}
