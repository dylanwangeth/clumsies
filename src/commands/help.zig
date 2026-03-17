const std = @import("std");
const styles = @import("../styles.zig");

const Color = styles.Color;
const P = styles.P;

pub fn run(stdout: *std.io.Writer) !void {
    try stdout.print("{s}{s}{s}clumsies{s} - User-controlled memory for AI agents\n\n", .{ P, Color.bold, Color.orange, Color.reset });

    try stdout.print("{s}{s}{s}Registry:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}ls{s}        List prompts or bundles\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}add{s}       Register prompt(s)\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}rm{s}        Remove prompt(s) or bundle(s)\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}show{s}      Show content (auto-detects type)\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}set{s}       Update metadata or composition\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}get{s}       Import to local .prompts/\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}pub{s}       Publish bundle to registry\n\n", .{ P, Color.cyan, Color.reset });

    try stdout.print("{s}{s}{s}Workspace:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}clone{s}     Clone remote to .prompts/\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}remote{s}    Set/update remote origin\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}push{s}      Commit and push\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}pull{s}      Pull latest\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}status{s}    Show git status\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}log{s}       Show commit history\n\n", .{ P, Color.cyan, Color.reset });

    try stdout.print("{s}{s}{s}Other:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}config{s}    Manage configuration\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}upgrade{s}   Upgrade to latest version\n\n", .{ P, Color.cyan, Color.reset });

    try stdout.print("{s}{s}Run {s}clumsies <command> -h{s}{s} for details.{s}\n", .{ P, Color.dim, Color.reset, Color.dim, Color.dim, Color.reset });
}
