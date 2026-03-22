const std = @import("std");
const commands = @import("commands.zig");

const Color = commands.Color;
const P = commands.P;

pub fn run(stdout: *std.Io.Writer, stderr: *std.Io.Writer, _: std.mem.Allocator, current_version: []const u8) !void {
    _ = stderr;
    try stdout.print("{s}Current version: {s}\n", .{ P, current_version });
    try stdout.print("{s}To upgrade, run:\n", .{P});
    try stdout.print("{s}  {s}curl -fsSL https://raw.githubusercontent.com/lilhammerfun/clumsies/main/install.sh | sh{s}\n", .{ P, Color.cyan, Color.reset });
}
