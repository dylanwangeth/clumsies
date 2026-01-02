const commands = @import("commands.zig");
const Color = commands.Color;
const P = commands.P;

pub fn run(stdout: anytype) !void {
    try stdout.print("\n{s}{s}{s}clumsies{s} - AI Agent prompts scaffolding tool\n\n", .{ P, Color.bold, Color.orange, Color.reset });

    try stdout.print("{s}{s}{s}USAGE:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    clumsies <command> [options]\n\n", .{P});

    try stdout.print("{s}{s}{s}COMMANDS:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}search{s}              Search available templates (remote)\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}detail{s} <name>       Show template's meta-prompt file content\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}use{s} <name>          Apply template to current directory\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}install{s} <name>      Install a remote template\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}upgrade{s}             Upgrade clumsies to latest version\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}zen{s}                 Show clumsies design philosophy\n\n", .{ P, Color.cyan, Color.reset });

    try stdout.print("{s}{s}{s}SEARCH OPTIONS:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}--task, -t{s} <type>   Filter by task type\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}--kw, -k{s} <keyword>  Filter by keyword\n\n", .{ P, Color.cyan, Color.reset });

    try stdout.print("{s}{s}{s}USE OPTIONS:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}--lang, -l{s} <lang>   Language: 'en' or 'zh' (default: en)\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}--name, -n{s} <file>   Meta-prompt file name (default: CLAUDE.md)\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}--force, -f{s}         Overwrite existing files\n\n", .{ P, Color.cyan, Color.reset });

    try stdout.print("{s}{s}{s}INSTALL OPTIONS:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}--force, -f{s}         Overwrite existing template\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}--list{s}              List installed templates\n\n", .{ P, Color.cyan, Color.reset });

    try stdout.print("{s}{s}{s}EXAMPLES:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}clumsies search{s}                      {s}# List all templates{s}\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });
    try stdout.print("{s}    {s}clumsies search --task code{s}          {s}# Filter by task type{s}\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });
    try stdout.print("{s}    {s}clumsies search --kw react{s}           {s}# Filter by keyword{s}\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });
    try stdout.print("{s}    {s}clumsies install solocc{s}              {s}# Install a template{s}\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });
    try stdout.print("{s}    {s}clumsies detail solocc{s}               {s}# Preview meta-prompt{s}\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });
    try stdout.print("{s}    {s}clumsies use solocc{s}                  {s}# Apply template{s}\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });
    try stdout.print("{s}    {s}clumsies use solocc -l zh -n CURSOR.md{s}\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}clumsies install --list{s}              {s}# List installed{s}\n\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });

    try stdout.print("{s}{s}{s}VERSION:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}clumsies --version{s}\n\n", .{ P, Color.cyan, Color.reset });
}
