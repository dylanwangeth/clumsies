const commands = @import("commands.zig");
const Color = commands.Color;
const P = commands.P;

pub fn run(stdout: anytype) !void {
    try stdout.writeAll("\n");
    try stdout.print("{s}{s}{s}The Zen of clumsies{s}\n\n", .{ P, Color.bold, Color.orange, Color.reset });

    try stdout.print("{s}clumsies turns a single prompts file into a structured system:\n", .{P});
    try stdout.print("{s}  {s}meta-prompt file{s} + {s}.prompts/{s} directory\n\n", .{ P, Color.bold, Color.reset, Color.bold, Color.reset });

    try stdout.print("{s}{s}Meta-prompt{s} (CLAUDE.md / CURSOR.md / GEMINI.md):\n", .{ P, Color.orange, Color.reset });
    try stdout.print("{s}  Tells AI how to understand and navigate your .prompts/ directory.\n", .{P});
    try stdout.print("{s}  It's not the rules itself, but the guide to your rules.\n\n", .{P});

    try stdout.print("{s}{s}.prompts/{s} directory:\n", .{ P, Color.orange, Color.reset });
    try stdout.print("{s}  Organize your prompts however you need. No fixed structure required.\n\n", .{P});

    try stdout.print("{s}{s}{s}Best practices:{s}\n\n", .{ P, Color.bold, Color.orange, Color.reset });

    try stdout.print("{s}  If you want to store reusable development standards (like code style,\n", .{P});
    try stdout.print("{s}  git commit conventions, testing requirements), we suggest:\n", .{P});
    try stdout.print("{s}    {s}.prompts/conduct/{s}\n\n", .{ P, Color.cyan, Color.reset });

    try stdout.print("{s}  If you want to prepare quick instructions (like \"always read git diff\n", .{P});
    try stdout.print("{s}  and generate commit messages\"), we suggest:\n", .{P});
    try stdout.print("{s}    {s}.prompts/command/{s} with numbered prefixes for easy reference:\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}      - \"run command 0\" {s}→{s} executes {s}00_*.md{s}\n", .{ P, Color.orange, Color.reset, Color.cyan, Color.reset });
    try stdout.print("{s}      - \"run command 1\" {s}→{s} executes {s}01_*.md{s}\n\n", .{ P, Color.orange, Color.reset, Color.cyan, Color.reset });

    try stdout.print("{s}{s}{s}Example:{s}\n\n", .{ P, Color.bold, Color.orange, Color.reset });

    try stdout.print("{s}  {s}my-project/{s}\n", .{ P, Color.dim, Color.reset });
    try stdout.print("{s}  ├── {s}CLAUDE.md{s}                 {s}← meta-prompt file{s}\n", .{ P, Color.bold, Color.reset, Color.dim, Color.reset });
    try stdout.print("{s}  └── {s}.prompts/{s}\n", .{ P, Color.bold, Color.reset });
    try stdout.print("{s}      ├── {s}conduct/{s}\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}      │   └── GIT_COMMIT.md       {s}← \"use conventional commits\"{s}\n", .{ P, Color.dim, Color.reset });
    try stdout.print("{s}      └── {s}command/{s}\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}          └── 00_REVIEW_COMMIT.md {s}← \"run command 0\" triggers this{s}\n\n", .{ P, Color.dim, Color.reset });

    try stdout.print("{s}{s}CLAUDE.md:{s}\n", .{ P, Color.orange, Color.reset });
    try stdout.print("{s}  {s}# Project Instructions{s}\n", .{ P, Color.dim, Color.reset });
    try stdout.print("{s}  {s}All development guidelines are in `.prompts/`{s}\n", .{ P, Color.dim, Color.reset });
    try stdout.print("{s}  {s}Read `conduct/` for coding standards.{s}\n", .{ P, Color.dim, Color.reset });
    try stdout.print("{s}  {s}Run `command/00_*.md` when asked \"run command 0\".{s}\n\n", .{ P, Color.dim, Color.reset });

    try stdout.print("{s}{s}GIT_COMMIT.md:{s}\n", .{ P, Color.orange, Color.reset });
    try stdout.print("{s}  {s}Use conventional commits: feat:, fix:, docs:, refactor:{s}\n\n", .{ P, Color.dim, Color.reset });

    try stdout.print("{s}{s}00_REVIEW_COMMIT.md:{s}\n", .{ P, Color.orange, Color.reset });
    try stdout.print("{s}  {s}1. Run `git diff` to see changes{s}\n", .{ P, Color.dim, Color.reset });
    try stdout.print("{s}  {s}2. Generate commit message following conduct/GIT_COMMIT.md{s}\n", .{ P, Color.dim, Color.reset });
    try stdout.print("{s}  {s}3. Ask user to confirm before committing{s}\n\n", .{ P, Color.dim, Color.reset });
}
