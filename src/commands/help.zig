const commands = @import("commands.zig");
const Color = commands.Color;
const P = commands.P;

pub fn run(stdout: anytype) !void {
    try stdout.print("\n{s}{s}{s}clumsies{s} - AI Agent prompts scaffolding tool\n\n", .{ P, Color.bold, Color.orange, Color.reset });

    try stdout.print("{s}{s}{s}USAGE:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    clumsies <command> [options]\n\n", .{P});

    try stdout.print("{s}{s}{s}COMMANDS:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}search{s} [keyword]    Search templates (default)\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}detail{s} <name>       Show template's meta-prompt file content\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}install{s} <hash>      Install a remote template by hash\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}use{s} <hash>          Apply installed template to current directory\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}add{s} <hash>          Add a single prompt by hash\n", .{ P, Color.cyan, Color.reset });
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

    try stdout.print("{s}{s}{s}ADD OPTIONS:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}--force, -f{s}         Overwrite existing file\n\n", .{ P, Color.cyan, Color.reset });

    try stdout.print("{s}{s}{s}CONFIG OPTIONS:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}set{s} <key> <value>   Set a config value\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}get{s} <key>           Get a config value\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}list{s}                List all config\n\n", .{ P, Color.cyan, Color.reset });

    try stdout.print("{s}{s}{s}EXAMPLES:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}clumsies search{s}                 {s}# List all templates{s}\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });
    try stdout.print("{s}    {s}clumsies search solo{s}            {s}# Search templates by keyword{s}\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });
    try stdout.print("{s}    {s}clumsies search --command{s}       {s}# List command prompts{s}\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });
    try stdout.print("{s}    {s}clumsies search --conduct{s}       {s}# List conduct prompts{s}\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });
    try stdout.print("{s}    {s}clumsies install 4a83ba2c{s}       {s}# Install template by hash{s}\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });
    try stdout.print("{s}    {s}clumsies use 4a83ba2c{s}           {s}# Apply installed template{s}\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });
    try stdout.print("{s}    {s}clumsies use 4a83ba2c -l zh{s}     {s}# Apply in Chinese{s}\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });
    try stdout.print("{s}    {s}clumsies add 36995f0a{s}           {s}# Add a single prompt{s}\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });
    try stdout.print("{s}    {s}clumsies config set lang zh{s}     {s}# Set default language{s}\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });
    try stdout.print("{s}    {s}clumsies install --list{s}         {s}# List installed{s}\n\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });

    try stdout.print("{s}{s}{s}VERSION:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}clumsies --version{s}\n\n", .{ P, Color.cyan, Color.reset });
}
