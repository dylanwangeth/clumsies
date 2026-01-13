const std = @import("std");
const styles = @import("../styles.zig");

const Color = styles.Color;
const P = styles.P;

pub fn run(stdout: anytype) !void {
    try stdout.print("\n{s}{s}{s}clumsies{s} - CLI for the Clumsies Protocol\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}{s}Manage your .prompts/ directory as an independent git repository{s}\n\n", .{ P, Color.dim, Color.reset });

    try stdout.print("{s}{s}{s}BUNDLE STRUCTURE:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    CLAUDE.md              Entry file (auto-synced with .prompts/)\n", .{P});
    try stdout.print("{s}    .prompts/conduct/      Behavioral rules (always active)\n", .{P});
    try stdout.print("{s}    .prompts/command/      Executable commands\n\n", .{P});

    try stdout.print("{s}{s}Entry files (CLAUDE.md, CURSOR.md, AGENTS.md, COPILOT.md) are auto-synced:{s}\n", .{ P, Color.dim, Color.reset });
    try stdout.print("{s}{s}  push: root -> .prompts/    pull/clone: .prompts/ -> root{s}\n\n", .{ P, Color.dim, Color.reset });

    try stdout.print("{s}{s}{s}USAGE:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    clumsies <command> [options]\n\n", .{P});

    try stdout.print("{s}{s}{s}MAIN COMMANDS:{s} (manage .prompts/ directory)\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}init{s} <git-url>       Initialize .prompts/ with git remote\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}init{s} {s}-B{s} <bundle> [url]  Initialize from bundle (optionally with remote)\n", .{ P, Color.cyan, Color.reset, Color.bold, Color.reset });
    try stdout.print("{s}    {s}clone{s} <git-url>      Clone remote to .prompts/\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}push{s} [-m \"msg\"]      Commit and push .prompts/ to remote\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}pull{s}                 Pull latest from remote\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}status{s}               Show .prompts/ git status\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}log{s}                  Show .prompts/ commit history\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}import{s} <hash>        Import prompt from registry to .prompts/\n\n", .{ P, Color.cyan, Color.reset });

    try stdout.print("{s}{s}{s}REGISTRY COMMANDS:{s} (manage prompts/bundles in shared registry)\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}list{s} {s}-P{s}|{s}-B{s}               List prompts or bundles in registry\n", .{ P, Color.cyan, Color.reset, Color.bold, Color.reset, Color.bold, Color.reset });
    try stdout.print("{s}    {s}show{s} {s}-P{s}|{s}-B{s} <hash>        Show prompt or bundle content\n", .{ P, Color.cyan, Color.reset, Color.bold, Color.reset, Color.bold, Color.reset });
    try stdout.print("{s}    {s}create{s} {s}-P{s} <file>         Create prompt in registry\n", .{ P, Color.cyan, Color.reset, Color.bold, Color.reset });
    try stdout.print("{s}    {s}create{s} {s}-B{s} <name> <dirs>   Create bundle in registry\n", .{ P, Color.cyan, Color.reset, Color.bold, Color.reset });
    try stdout.print("{s}    {s}update{s} {s}-B{s} <name> {s}--add{s}|{s}--rm{s} <files>  Update bundle contents\n", .{ P, Color.cyan, Color.reset, Color.bold, Color.reset, Color.bold, Color.reset, Color.bold, Color.reset });
    try stdout.print("{s}    {s}rm{s} {s}-P{s}|{s}-B{s} <hash>          Remove prompt/bundle from registry\n\n", .{ P, Color.cyan, Color.reset, Color.bold, Color.reset, Color.bold, Color.reset });

    try stdout.print("{s}{s}{s}CONFIG:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}config set{s} <key> <value>  Set configuration value\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}config get{s} <key>          Get configuration value\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}config list{s}               List all configuration\n\n", .{ P, Color.cyan, Color.reset });

    try stdout.print("{s}{s}{s}OTHER:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}upgrade{s}               Upgrade clumsies to latest version\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}--version{s}             Show version\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}--help{s}                Show this help\n\n", .{ P, Color.cyan, Color.reset });

    try stdout.print("{s}{s}{s}EXAMPLES:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}# Initialize and sync your prompts{s}\n", .{ P, Color.dim, Color.reset });
    try stdout.print("{s}    clumsies init git@github.com:user/my-prompts.git\n", .{P});
    try stdout.print("{s}    clumsies push -m \"Add review command\"\n\n", .{P});

    try stdout.print("{s}    {s}# Clone existing prompts{s}\n", .{ P, Color.dim, Color.reset });
    try stdout.print("{s}    clumsies clone git@github.com:team/shared-prompts.git\n\n", .{P});

    try stdout.print("{s}    {s}# Use shared registry{s}\n", .{ P, Color.dim, Color.reset });
    try stdout.print("{s}    clumsies config set registry git@github.com:org/registry.git\n", .{P});
    try stdout.print("{s}    clumsies list -P\n", .{P});
    try stdout.print("{s}    clumsies import a1b2c3d4\n\n", .{P});

    try stdout.print("{s}    {s}# Create in registry{s}\n", .{ P, Color.dim, Color.reset });
    try stdout.print("{s}    clumsies create -P my_prompt.md\n", .{P});
    try stdout.print("{s}    clumsies create -B my-bundle conduct command\n", .{P});
    try stdout.print("{s}    clumsies update -B my-bundle --add new_dir\n\n", .{P});

    try stdout.print("{s}    {s}# Initialize from bundle{s}\n", .{ P, Color.dim, Color.reset });
    try stdout.print("{s}    clumsies init -B my-bundle\n", .{P});
    try stdout.print("{s}    clumsies init -B my-bundle git@github.com:user/prompts.git\n\n", .{P});
}
