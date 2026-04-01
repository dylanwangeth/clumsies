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
        error.MissingValue, error.OutOfMemory => return error.OutOfMemory,
    };
    defer result.deinit(allocator);

    if (!commands.promptsExist()) {
        try stderr.print("{s}{s}{s}Error:{s} .prompts/ not found\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    }

    const workspace_root = try std.process.getCwdAlloc(allocator);
    defer allocator.free(workspace_root);

    var mpf = workspace_prompt.loadMpf(allocator, workspace_root, null) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to load META_PROMPT.md\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer mpf.deinit(allocator);

    trace.appendTraceEvent(allocator, workspace_root, .{
        .event_type = .setup,
        .mpf_hash = mpf.hash,
    }) catch {};

    if (mpf.content) |content| {
        if (output.detect() == .human) {
            try stdout.print("{s}{s}{s}✓{s} Loaded META_PROMPT.md ({d} bytes)\n", .{ P, Color.bold, Color.green, Color.reset, content.len });
        } else {
            try stdout.writeAll(content);
        }
    } else {
        if (output.detect() == .human) {
            try stderr.print("{s}{s}{s}Warning:{s} No .prompts/META_PROMPT.md found\n", .{ P, Color.bold, Color.orange, Color.reset });
        }
    }
}

fn printHelp(out: *std.Io.Writer) !void {
    try out.print("{s}Usage: {s}clumsies setup{s}\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Load META_PROMPT.md and output its content.\n", .{P});
    try out.print("{s}Used by hooks to bootstrap the protocol.\n", .{P});
}
