const std = @import("std");
const styles = @import("../styles.zig");

const Color = styles.Color;
const P = styles.P;

pub fn run(stdout: *std.Io.Writer) !void {
    try stdout.print("{s}{s}{s}clumsies{s} - User-controlled memory for AI agents\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}{s}{s}Registry:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}ls{s}        List prompts or bundles\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}add{s}       Register prompt(s)\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}rm{s}        Remove prompt(s) or bundle(s)\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}show{s}      Show content (auto-detects type)\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}set{s}       Update metadata or composition\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}get{s}       Import to local .prompts/\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}pub{s}       Publish bundle to registry\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}{s}{s}Workspace:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}clone{s}     Clone remote to .prompts/\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}remote{s}    Set/update remote origin\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}push{s}      Commit and push\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}pull{s}      Pull latest\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}status{s}    Show git status\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}log{s}       Show commit history\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}{s}{s}Task:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}setup{s}     Load META_PROMPT.md\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}begin{s}     Start a task (idempotent)\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}complete{s}  Mark task as done\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}search{s}    Discover available prompts\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}load{s}      Load prompt content by id\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}refer{s}     Declare constraint reference\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}validate{s}  Check prompt format\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}{s}{s}Other:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}stats{s}     Show prompt usage stats\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}config{s}    Manage configuration\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}mcp{s}       Start MCP stdio server\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}upgrade{s}   Upgrade to latest version\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}{s}Run {s}clumsies <command> -h{s}{s} for details.{s}\n", .{ P, Color.dim, Color.reset, Color.dim, Color.dim, Color.reset });
}
