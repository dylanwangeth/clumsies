const std = @import("std");
const lib = @import("clumsies_lib");
const commands = @import("commands.zig");
const flag = @import("../flags.zig");
const output = @import("../output.zig");

const Color = commands.Color;
const P = commands.P;
const workspace_prompt = lib.workspace_prompt;

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

    if (result.positionals.items.len == 0) {
        try stderr.print("{s}{s}{s}Error:{s} Prompt id required\n", .{ P, Color.bold, Color.red, Color.reset });
        try printHelp(stderr);
        return;
    }

    if (!commands.promptsExist()) {
        try stderr.print("{s}{s}{s}Error:{s} .prompts/ not found\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    }

    const workspace_root = try std.process.getCwdAlloc(allocator);
    defer allocator.free(workspace_root);

    const mode = output.detect();

    for (result.positionals.items) |prompt_id| {
        var validate_result = workspace_prompt.validatePrompt(allocator, workspace_root, prompt_id) catch {
            try stderr.print("{s}{s}{s}Error:{s} Failed to validate: {s}\n", .{ P, Color.bold, Color.red, Color.reset, prompt_id });
            continue;
        };
        defer validate_result.deinit(allocator);

        if (mode == .human) {
            if (validate_result.valid) {
                try stdout.print("{s}{s}{s}✓{s} {s}  {d} constraints\n", .{ P, Color.bold, Color.green, Color.reset, prompt_id, validate_result.constraints.items.len });
            } else {
                try stdout.print("{s}{s}{s}✗{s} {s}\n", .{ P, Color.bold, Color.red, Color.reset, prompt_id });
            }

            for (validate_result.constraints.items) |c| {
                try stdout.print("{s}    {s}{s}{s}\n", .{ P, Color.cyan, c.id, Color.reset });
            }

            for (validate_result.issues.items) |issue| {
                try stdout.print("{s}    {s}{s}{s}\n", .{ P, Color.orange, issue, Color.reset });
            }
        } else {
            for (validate_result.constraints.items) |c| {
                try stdout.print("{s}\n", .{c.id});
            }

            for (validate_result.issues.items) |issue| {
                try stderr.print("issue: {s}\n", .{issue});
            }
        }
    }
}

fn printHelp(out: *std.Io.Writer) !void {
    try out.print("{s}Usage: {s}clumsies validate <prompt-id>...{s}\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Validate prompt files and list parsed constraints.\n", .{P});
    try out.print("{s}Examples:\n", .{P});
    try out.print("{s}  {s}clumsies validate rule:zig/00_ZIG_STYLE.md{s}\n", .{ P, Color.cyan, Color.reset });
}
