const std = @import("std");
const styles = @import("../styles.zig");
const serve = @import("../serve.zig");

const Color = styles.Color;
const P = styles.P;

pub fn run(
    stdout: *std.io.Writer,
    stderr: *std.io.Writer,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    version: []const u8,
) !void {
    if (args.len == 0) {
        try printHelp(stderr);
        return;
    }

    const subcmd = args[0];
    if (std.mem.eql(u8, subcmd, "-h") or std.mem.eql(u8, subcmd, "--help")) {
        try printHelp(stdout);
        return;
    }

    if (std.mem.eql(u8, subcmd, "serve")) {
        try serve.run(stdout, stderr, allocator, version);
        return;
    }

    try stderr.print("{s}{s}{s}Error:{s} Unknown mcp subcommand: {s}\n", .{ P, Color.bold, Color.red, Color.reset, subcmd });
    try printHelp(stderr);
}

fn printHelp(out: *std.io.Writer) !void {
    try out.print("{s}Usage: {s}clumsies mcp serve{s}\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Commands:\n", .{P});
    try out.print("{s}  {s}serve{s}     Start MCP stdio server for the current workspace\n", .{ P, Color.cyan, Color.reset });
}
