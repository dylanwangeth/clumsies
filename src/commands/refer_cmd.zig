const std = @import("std");
const lib = @import("clumsies_lib");
const commands = @import("commands.zig");
const flag = @import("../flags.zig");
const output = @import("../output.zig");

const Color = commands.Color;
const P = commands.P;
const trace = lib.trace;

pub fn run(stdout: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const PROMPT = 0;
    const HASH = 1;
    const CONSTRAINT = 2;
    const REASON = 3;
    const SPECS = [_]flag.FlagSpec{
        .{ .short = 'p', .long = "prompt", .kind = .value },
        .{ .short = null, .long = "hash", .kind = .value },
        .{ .short = 'c', .long = "constraint", .kind = .value },
        .{ .short = 'r', .long = "reason", .kind = .value },
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

    const prompt_id = result.value(PROMPT) orelse {
        try stderr.print("{s}{s}{s}Error:{s} --prompt is required\n", .{ P, Color.bold, Color.red, Color.reset });
        try printHelp(stderr);
        return;
    };

    const constraint_id = result.value(CONSTRAINT);

    const workspace_root = try std.process.getCwdAlloc(allocator);
    defer allocator.free(workspace_root);

    trace.appendTraceEvent(allocator, workspace_root, .{
        .event_type = .refer,
        .prompt_id = prompt_id,
        .prompt_hash = result.value(HASH),
        .constraint_id = constraint_id,
        .reason = result.value(REASON),
    }) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to write refer event\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    if (output.detect() == .human) {
        if (constraint_id) |cid| {
            try stdout.print("{s}{s}{s}✓{s} Referred {s} :: {s}\n", .{ P, Color.bold, Color.green, Color.reset, prompt_id, cid });
        } else {
            try stdout.print("{s}{s}{s}✓{s} Referred {s}\n", .{ P, Color.bold, Color.green, Color.reset, prompt_id });
        }
    }
}

fn printHelp(out: *std.Io.Writer) !void {
    try out.print("{s}Usage: {s}clumsies refer -p <prompt-id> [-c <constraint-id>] [--hash <hash>] [-r <reason>]{s}\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Declare a constraint reference. Writes a refer event to trace.\n", .{P});
    try out.print("{s}Options:\n", .{P});
    try out.print("{s}  {s}-p, --prompt{s} <id>         Prompt id (required)\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-c, --constraint{s} <id>     Constraint id\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}--hash{s} <hash>             Prompt hash\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-r, --reason{s} <reason>     Why this constraint was referenced\n", .{ P, Color.cyan, Color.reset });
}
