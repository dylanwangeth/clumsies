const std = @import("std");
const styles = @import("../styles.zig");

const Color = styles.Color;
const P = styles.P;

pub fn run(stdout: anytype) !void {
    try stdout.print("\n{s}{s}{s}clumsies{s} - CLI for the Clumsies Protocol\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}{s}Manage your .prompts/ directory as an independent git repository{s}\n\n", .{ P, Color.dim, Color.reset });

    try stdout.print("{s}{s}{s}BUNDLE STRUCTURE:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    CLAUDE.md              Meta-prompt file (auto-synced with .prompts/)\n", .{P});
    try stdout.print("{s}    .prompts/conduct/      Behavioral rules (always active)\n", .{P});
    try stdout.print("{s}    .prompts/command/      Executable commands\n\n", .{P});

    try stdout.print("{s}{s}Meta-prompt files (CLAUDE.md, CURSOR.md, AGENTS.md, COPILOT.md) are auto-synced:{s}\n", .{ P, Color.dim, Color.reset });
    try stdout.print("{s}{s}  push: root -> .prompts/    pull/clone: .prompts/ -> root{s}\n\n", .{ P, Color.dim, Color.reset });

    try stdout.print("{s}{s}{s}USAGE:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    clumsies <command> [options]\n\n", .{P});

    try stdout.print("{s}{s}{s}MAIN COMMANDS:{s} (manage .prompts/ directory)\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}init{s} <bundle> <url>  Initialize from bundle with git remote\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}clone{s} <git-url>      Clone remote to .prompts/\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}push{s} [-m \"msg\"]      Commit and push .prompts/ to remote\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}pull{s}                 Pull latest from remote\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}status{s}               Show .prompts/ git status\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}log{s}                  Show .prompts/ commit history\n\n", .{ P, Color.cyan, Color.reset });

    try stdout.print("{s}{s}{s}BUNDLE COMMANDS:{s} (manage bundles in registry)\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}bundle list{s}                                  List bundles\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}bundle register{s} <meta-prompt> <dirs...>      Register bundle\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}bundle update{s} <name> --add/--rm <args...>    Add/remove prompts\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}bundle show{s} <name>                           Show bundle content\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}bundle rm{s} <name>                             Remove bundle\n\n", .{ P, Color.cyan, Color.reset });

    try stdout.print("{s}{s}{s}PROMPT COMMANDS:{s} (manage prompts in registry)\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}prompt list{s}              List prompts\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}prompt register{s} <file>   Register prompt\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}prompt show{s} <hash>       Show prompt content\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}prompt import{s} <hash>     Import to .prompts/\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}prompt rm{s} <hash>         Remove prompt\n\n", .{ P, Color.cyan, Color.reset });

    try stdout.print("{s}{s}{s}CONFIG:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}config set{s} <key> <value>  Set configuration value\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}config get{s} <key>          Get configuration value\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}config list{s}               List all configuration\n\n", .{ P, Color.cyan, Color.reset });

    try stdout.print("{s}{s}{s}OTHER:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}upgrade{s}               Upgrade clumsies to latest version\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}-v, --version{s}         Show version\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}-h, --help{s}            Show this help\n\n", .{ P, Color.cyan, Color.reset });

    try stdout.print("{s}{s}{s}OPTIONS:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}-m, --message{s} <msg>    Commit message (for push)\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}-s, --sync{s}             Sync registry before command (bundle/prompt)\n\n", .{ P, Color.cyan, Color.reset });

    try stdout.print("{s}{s}{s}CONFIG KEYS:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}registry{s}              Registry URL {s}(e.g. git@github.com:org/registry.git){s}\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });
    try stdout.print("{s}    {s}entry_files{s}           Sync files {s}(e.g. CLAUDE.md,CURSOR.md){s}\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });
    try stdout.print("{s}    {s}meta_prompt_file{s}      Init target {s}(default: CLAUDE.md){s}\n\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });
}
