const std = @import("std");
const styles = @import("../styles.zig");

const Color = styles.Color;
const P = styles.P;

pub fn run(stdout: anytype) !void {
    try stdout.print("{s}{s}{s}clumsies{s} - A semantic layer for AI agent prompts\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}{s}Manage .prompts/ as an independent git repository{s}\n\n", .{ P, Color.dim, Color.reset });

    try stdout.print("{s}{s}{s}STRUCTURE:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    CLAUDE.md                    Meta-prompt (managed via bundle import/register)\n", .{P});
    try stdout.print("{s}    .prompts/conduct/            Behavioral rules (cross-cutting)\n", .{P});
    try stdout.print("{s}    .prompts/conduct/coding/     Code style, testing, dependencies\n", .{P});
    try stdout.print("{s}    .prompts/conduct/git/        Git conventions\n", .{P});
    try stdout.print("{s}    .prompts/conduct/writing/    Writing standards\n", .{P});
    try stdout.print("{s}    .prompts/conduct/teaching/   Teaching methodology\n", .{P});
    try stdout.print("{s}    .prompts/command/            Executable procedures, invoke by name\n", .{P});
    try stdout.print("{s}    .prompts/context/            Project-specific knowledge (local only)\n\n", .{P});

    try stdout.print("{s}{s}Meta-prompt files are managed via the registry (bundle import/register){s}\n\n", .{ P, Color.dim, Color.reset });

    try stdout.print("{s}{s}{s}USAGE:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    clumsies <command> [options]\n\n", .{P});

    try stdout.print("{s}{s}{s}GIT COMMANDS:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}clone{s} <git-url>      Clone remote to .prompts/\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}remote{s} <url>         Set/update remote origin\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}push{s} [-m \"msg\"]      Commit and push to remote\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}pull{s}                 Pull latest from remote\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}status{s}               Show git status\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}log{s}                  Show commit history\n\n", .{ P, Color.cyan, Color.reset });

    try stdout.print("{s}{s}{s}BUNDLE COMMANDS:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}bundle list{s}                                  List bundles\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}bundle import{s} <name> [--remote-url <url>] [--update-meta]  Import bundle\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}bundle register{s} <meta-prompt> <dirs...>      Register bundle\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}bundle update{s} <name> [--add/--rm/--add-prompt/--rm-prompt/--meta]  Modify bundle\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}bundle show{s} <name> [--meta]                   Show bundle content\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}bundle rm{s} <name>...                          Remove bundle(s)\n\n", .{ P, Color.cyan, Color.reset });

    try stdout.print("{s}{s}{s}PROMPT COMMANDS:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}prompt list{s}                            List prompts\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}prompt register{s} <file> [--desc/--cat]  Register prompt\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}prompt update{s} <hash> [--desc/--cat]    Update prompt metadata\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}prompt replace{s} <hash> <file> [--desc/--cat]  Replace prompt content\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}prompt show{s} <hash>                     Show prompt content\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}prompt import{s} <hash>... [--cat <cat>...]  Import to .prompts/\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}prompt rm{s} <hash>...                    Remove prompt(s)\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}prompt rename-cat{s} <old> <new>          Rename category\n\n", .{ P, Color.cyan, Color.reset });

    try stdout.print("{s}{s}{s}CONFIG:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}config set{s} <key> <value>  Set config value\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}config get{s} <key>          Get config value\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}config list{s}               List all config\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}upgrade{s}                   Upgrade to latest version\n\n", .{ P, Color.cyan, Color.reset });

    try stdout.print("{s}{s}{s}OPTIONS:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}-m, --message{s} <msg>    Commit message (for push)\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}-s, --sync{s}             Sync registry before command\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}-v, --version{s}          Show version\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}-h, --help{s}             Show this help\n\n", .{ P, Color.cyan, Color.reset });

    try stdout.print("{s}{s}{s}CONFIG KEYS:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}registry{s}              Registry URL\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}entry_files{s}           Meta-prompt filenames (for bundle import)\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}meta_prompt_file{s}      Default meta-prompt for init\n", .{ P, Color.cyan, Color.reset });
}
