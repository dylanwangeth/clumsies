const std = @import("std");
const flag = @import("../flags.zig");
const ws_config = @import("../workspace_config.zig");
const trace_upload = @import("../trace_upload.zig");
const styles = @import("../styles.zig");

const Color = styles.Color;
const P = styles.P;

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

    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    const binding = ws_config.resolveWorkspace(allocator, cwd_path) catch {
        try stderr.print("{s}{s}{s}Error:{s} No workspace bound to this directory. Run {s}clumsies init{s} first.\n", .{ P, Color.bold, Color.red, Color.reset, Color.cyan, Color.reset });
        return;
    };
    defer allocator.free(binding.ws_id);
    defer allocator.free(binding.name);

    const outcome = trace_upload.flushWorkspace(allocator, binding.ws_id);
    switch (outcome) {
        .flushed => |flush_result| {
            try stdout.print(
                "{s}Flushed {d} events in {d} batches ({d} read)\n",
                .{ P, flush_result.events_sent, flush_result.batches_sent, flush_result.events_read },
            );
        },
        .not_authenticated => {
            try stderr.print("{s}{s}{s}Error:{s} Not logged in. Run {s}clumsies login{s} first.\n", .{ P, Color.bold, Color.red, Color.reset, Color.cyan, Color.reset });
        },
        .failed => |err| {
            try stderr.print("{s}{s}{s}Error:{s} flush failed: {}\n", .{ P, Color.bold, Color.red, Color.reset, err });
        },
    }
}

fn printHelp(w: *std.Io.Writer) !void {
    try w.print("{s}{s}clumsies flush-trace{s}\n\n", .{ P, Color.bold, Color.reset });
    try w.print("Upload pending trace events from this workspace to the hub.\n\n", .{});
    try w.print("{s}Usage:{s}\n", .{ Color.bold, Color.reset });
    try w.print("  clumsies flush-trace\n", .{});
}
