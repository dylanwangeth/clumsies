const commands = @import("commands.zig");
const Color = commands.Color;
const P = commands.P;

pub fn run(stdout: anytype) !void {
    try stdout.print("\n{s}{s}{s}clumsies{s} - AI Agent prompts scaffolding tool\n\n", .{ P, Color.bold, Color.orange, Color.reset });

    try stdout.print("{s}{s}{s}USAGE:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    clumsies <command> [options]\n\n", .{P});

    try stdout.print("{s}{s}{s}COMMANDS:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}search{s} [keyword]    Search templates or prompts\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}detail{s} <name>       Show template's meta-prompt file content\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}use{s} <name>          Apply template to current directory\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}install{s} <name>      Install a remote template\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}config{s}              Manage configuration\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}upgrade{s}             Upgrade clumsies to latest version\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}zen{s}                 Show clumsies design philosophy\n\n", .{ P, Color.cyan, Color.reset });

    try stdout.print("{s}{s}{s}SEARCH OPTIONS:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}--command{s}           Search command prompts\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}--conduct{s}           Search conduct prompts\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}--lang, -l{s} <code>   Language filter (ISO 639-1, default: from config)\n\n", .{ P, Color.cyan, Color.reset });

    try stdout.print("{s}{s}{s}USE/DETAIL OPTIONS:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}--lang, -l{s} <code>   Language (ISO 639-1, default: from config)\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}--name, -n{s} <file>   Meta-prompt file name (default: CLAUDE.md)\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}--force, -f{s}         Overwrite existing files\n\n", .{ P, Color.cyan, Color.reset });

    try stdout.print("{s}{s}{s}INSTALL OPTIONS:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}--force, -f{s}         Overwrite existing template\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}--list{s}              List installed templates\n\n", .{ P, Color.cyan, Color.reset });

    try stdout.print("{s}{s}{s}CONFIG OPTIONS:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}set{s} <key> <value>   Set a config value\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}get{s} <key>           Get a config value\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}list{s}                List all config\n\n", .{ P, Color.cyan, Color.reset });

    try stdout.print("{s}{s}{s}EXAMPLES:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}clumsies search{s}                      {s}# List all templates{s}\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });
    try stdout.print("{s}    {s}clumsies search solo{s}                 {s}# Search templates by keyword{s}\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });
    try stdout.print("{s}    {s}clumsies search --command{s}            {s}# List command prompts{s}\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });
    try stdout.print("{s}    {s}clumsies search --conduct --lang zh{s}  {s}# Conduct in Chinese{s}\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });
    try stdout.print("{s}    {s}clumsies install solocc{s}              {s}# Install a template{s}\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });
    try stdout.print("{s}    {s}clumsies use solocc{s}                  {s}# Apply template{s}\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });
    try stdout.print("{s}    {s}clumsies use solocc -l zh{s}            {s}# Apply in Chinese{s}\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });
    try stdout.print("{s}    {s}clumsies config set lang zh{s}          {s}# Set default language{s}\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });
    try stdout.print("{s}    {s}clumsies install --list{s}              {s}# List installed{s}\n\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });

    try stdout.print("{s}{s}{s}VERSION:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}clumsies --version{s}\n\n", .{ P, Color.cyan, Color.reset });
}
