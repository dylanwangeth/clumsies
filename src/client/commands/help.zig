const std = @import("std");
const styles = @import("../styles.zig");

const Color = styles.Color;
const P = styles.P;

pub fn run(stdout: *std.Io.Writer) !void {
    try stdout.print("{s}{s}{s}clumsies{s} - Rule + context management for AI agents\n\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}{s}{s}Usage:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}clumsies{s}            Launch TUI Dashboard\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}clumsies login{s}      Authenticate with Hub\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}clumsies init{s}       Bind workspace to current directory\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}clumsies sync{s}         Sync local cache from Hub\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}clumsies adapt{s}        Install, update, remove, or list agent adapters\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}clumsies flush{s}         Upload pending attestation events to Hub\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}clumsies mcp serve{s}    Start MCP server for AI agents\n\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}{s}Run {s}clumsies <command> -h{s}{s} for details.{s}\n", .{ P, Color.dim, Color.reset, Color.dim, Color.dim, Color.reset });
}
