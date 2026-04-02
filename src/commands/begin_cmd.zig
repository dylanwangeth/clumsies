const std = @import("std");
const lib = @import("clumsies_lib");
const commands = @import("commands.zig");
const flag = @import("../flags.zig");
const output = @import("../output.zig");

const Color = commands.Color;
const P = commands.P;
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

    const workspace_root = try std.process.getCwdAlloc(allocator);
    defer allocator.free(workspace_root);

    // Idempotent: if there's an active task, return it
    if (try trace.getActiveTaskId(allocator, workspace_root)) |existing_id| {
        defer allocator.free(existing_id);
        if (output.detect() == .human) {
            try stdout.print("{s}{s}{s}●{s} Active task: {s}\n", .{ P, Color.bold, Color.cyan, Color.reset, existing_id });
        } else {
            try stdout.print("{s}", .{existing_id});
        }
        return;
    }

    // Collect remaining positionals as goal summary
    const goal = if (result.positionals.items.len > 0) blk: {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        for (result.positionals.items, 0..) |word, i| {
            if (i > 0) try buf.append(allocator, ' ');
            try buf.appendSlice(allocator, word);
        }
        break :blk try buf.toOwnedSlice(allocator);
    } else null;
    defer if (goal) |g| allocator.free(g);

    const task_id = trace.generateTaskId(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to generate task id\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(task_id);

    trace.appendTraceEvent(allocator, workspace_root, .{
        .event_type = .begin,
        .task_id = task_id,
        .goal = goal,
    }) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to write begin event\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    if (output.detect() == .human) {
        try stdout.print("{s}{s}{s}✓{s} Started task: {s}\n", .{ P, Color.bold, Color.green, Color.reset, task_id });
    } else {
        try stdout.print("{s}", .{task_id});
    }
}

fn printHelp(out: *std.Io.Writer) !void {
    try out.print("{s}Usage: {s}clumsies begin [goal...]{s}\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Start a new task. Returns task_id.\n", .{P});
    try out.print("{s}Idempotent: returns existing task_id if one is active.\n", .{P});
}
