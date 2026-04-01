const std = @import("std");
const lib = @import("clumsies_lib");
const commands = @import("commands.zig");
const flag = @import("../flags.zig");
const output = @import("../output.zig");

const Color = commands.Color;
const P = commands.P;
const trace = lib.trace;

pub fn run(stdout: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const A = 0;
    const SPECS = [_]flag.FlagSpec{
        .{ .short = null, .long = "abandon", .kind = .boolean },
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
        error.MissingValue, error.OutOfMemory => return error.OutOfMemory,
    };
    defer result.deinit(allocator);

    const workspace_root = try std.process.getCwdAlloc(allocator);
    defer allocator.free(workspace_root);

    const task_id = try trace.getActiveTaskId(allocator, workspace_root);
    if (task_id == null) {
        try stderr.print("{s}{s}{s}Error:{s} No active task to complete\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    }
    defer allocator.free(task_id.?);

    const status: []const u8 = if (result.boolean(A)) "abandoned" else "completed";

    trace.appendTraceEvent(allocator, workspace_root, .{
        .event_type = .complete,
        .task_id = task_id.?,
        .status = status,
    }) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to write complete event\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    if (output.detect() == .human) {
        try stdout.print("{s}{s}{s}✓{s} Task {s}: {s}\n", .{ P, Color.bold, Color.green, Color.reset, status, task_id.? });
    } else {
        try stdout.print("{s}", .{task_id.?});
    }
}

fn printHelp(out: *std.Io.Writer) !void {
    try out.print("{s}Usage: {s}clumsies complete [--abandon]{s}\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Mark the current active task as completed.\n", .{P});
    try out.print("{s}Options:\n", .{P});
    try out.print("{s}  {s}--abandon{s}  Mark as abandoned instead of completed\n", .{ P, Color.cyan, Color.reset });
}
