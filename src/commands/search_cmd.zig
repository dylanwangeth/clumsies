const std = @import("std");
const lib = @import("clumsies_lib");
const commands = @import("commands.zig");
const flag = @import("../flags.zig");
const output = @import("../output.zig");

const Color = commands.Color;
const P = commands.P;
const workspace_prompt = lib.workspace_prompt;

pub fn run(stdout: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const K = 0;
    const G = 1;
    const SPECS = [_]flag.FlagSpec{
        .{ .short = 'k', .long = "kind", .kind = .value },
        .{ .short = 'g', .long = "group", .kind = .value },
    };
    var err_ctx: flag.ErrorContext = .{};
    var result = flag.parse(&SPECS, allocator, args, &err_ctx) catch |err| switch (err) {
        error.HelpRequested => {
            try printHelp(stdout);
            return;
        },
        error.UnknownFlag => {
            try stderr.print("{s}{s}{s}Error:{s} Unknown flag: {s}\n", .{ P, Color.bold, Color.red, Color.reset, err_ctx.flag.? });
            try printHelp(stderr);
            return;
        },
        error.MissingValue => {
            try stderr.print("{s}{s}{s}Error:{s} {s} requires a value\n", .{ P, Color.bold, Color.red, Color.reset, err_ctx.flag.? });
            return;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer result.deinit(allocator);

    if (!commands.promptsExist()) {
        try stderr.print("{s}{s}{s}Error:{s} .prompts/ not found\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    }

    const workspace_root = try std.process.getCwdAlloc(allocator);
    defer allocator.free(workspace_root);

    const kind_filter: ?workspace_prompt.PromptKind = if (result.value(K)) |k| blk: {
        if (std.mem.eql(u8, k, "rule")) break :blk .rule;
        if (std.mem.eql(u8, k, "workflow")) break :blk .workflow;
        if (std.mem.eql(u8, k, "context")) break :blk .context;
        try stderr.print("{s}{s}{s}Error:{s} Unknown kind: {s}. Use: rule, workflow, context\n", .{ P, Color.bold, Color.red, Color.reset, k });
        return;
    } else null;

    const group_filter = result.value(G);

    var items = workspace_prompt.discoverSearchable(allocator, workspace_root, kind_filter, group_filter) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to scan .prompts/\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer workspace_prompt.deinitPromptItems(allocator, &items);

    if (items.items.len == 0) {
        try stdout.print("{s}No prompts found\n", .{P});
        return;
    }

    const mode = output.detect();
    for (items.items) |item| {
        const kind_str = workspace_prompt.kindToString(item.kind);
        const group_str = item.group orelse "";
        if (mode == .human) {
            try stdout.print("{s}  {s}{s}{s}  {s}{s: <10}{s}{s}\n", .{
                P,
                Color.cyan,
                item.id,
                Color.reset,
                Color.dim,
                kind_str,
                group_str,
                Color.reset,
            });
        } else {
            try stdout.print("{s}  {s}  {s}\n", .{ item.id, kind_str, group_str });
        }
    }
}

fn printHelp(out: *std.Io.Writer) !void {
    try out.print("{s}Usage: {s}clumsies search [-k <kind>] [-g <group>]{s}\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Discover available prompts in .prompts/.\n", .{P});
    try out.print("{s}Options:\n", .{P});
    try out.print("{s}  {s}-k, --kind{s} <kind>    Filter by kind: rule, workflow, context\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-g, --group{s} <group>  Filter by group\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-h, --help{s}           Show this help\n", .{ P, Color.cyan, Color.reset });
}
