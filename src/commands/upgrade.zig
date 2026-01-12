const std = @import("std");
const commands = @import("commands.zig");

const Color = commands.Color;
const P = commands.P;

pub fn run(stdout: anytype, stderr: anytype, _: std.mem.Allocator, current_version: []const u8) !void {
    _ = stderr;
    try stdout.print("\n{s}Current version: {s}\n", .{ P, current_version });
    try stdout.print("{s}To upgrade, run:\n", .{P});
    try stdout.print("{s}  {s}curl -fsSL https://raw.githubusercontent.com/lilhammerfun/clumsies/main/install.sh | sh{s}\n\n", .{ P, Color.cyan, Color.reset });
}
