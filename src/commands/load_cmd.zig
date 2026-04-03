const std = @import("std");
const lib = @import("clumsies_lib");
const commands = @import("commands.zig");
const flag = @import("../flags.zig");
const output = @import("../output.zig");

const Color = commands.Color;
const P = commands.P;
const workspace_prompt = lib.workspace_prompt;
const trace = lib.trace;

pub fn run(stdout: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const SPECS = [_]flag.FlagSpec{};
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

    if (result.positionals.items.len == 0) {
        try stderr.print("{s}{s}{s}Error:{s} Prompt id(s) required\n", .{ P, Color.bold, Color.red, Color.reset });
        try printHelp(stderr);
        return;
    }

    if (!commands.promptsExist()) {
        try stderr.print("{s}{s}{s}Error:{s} .prompts/ not found\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    }

    const workspace_root = try std.process.getCwdAlloc(allocator);
    defer allocator.free(workspace_root);

    var load_result = workspace_prompt.loadPrompts(allocator, workspace_root, result.positionals.items, &.{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to load prompts\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer load_result.deinit(allocator);

    const mode = output.detect();

    for (load_result.items.items) |item| {
        trace.appendTraceEvent(allocator, workspace_root, .{
            .event_type = .load,
            .prompt_id = item.id,
            .prompt_hash = item.hash,
        }) catch {};

        if (item.content) |content| {
            if (mode == .human) {
                try stdout.print("{s}{s}{s}── {s} ──{s}\n", .{ P, Color.bold, Color.cyan, item.id, Color.reset });
                try stdout.writeAll(content);
                try stdout.writeAll("\n");
            } else {
                try stdout.writeAll(content);
            }
        } else {
            if (mode == .human) {
                try stdout.print("{s}{s}{s}!{s} {s} not found\n", .{ P, Color.bold, Color.orange, Color.reset, item.id });
            }
        }
    }
}

fn printHelp(out: *std.Io.Writer) !void {
    try out.print("{s}Usage: {s}clumsies load <id>...{s}\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Load prompt content by id. Output includes refer reminder for rule/workflow.\n", .{P});
    try out.print("{s}Examples:\n", .{P});
    try out.print("{s}  {s}clumsies load rule:zig/00_ZIG_STYLE.md{s}\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}clumsies load workflow:cmd/00_GEN_COMMIT_MSG.md{s}\n", .{ P, Color.cyan, Color.reset });
}
