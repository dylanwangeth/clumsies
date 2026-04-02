const std = @import("std");
const lib = @import("clumsies_lib");
const commands = @import("commands.zig");
const flag = @import("../flags.zig");

const Color = commands.Color;
const P = commands.P;
const stats = lib.stats;

pub fn run(stdout: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const SCOPE = 0;
    const PROMPT = 1;
    const OLD_HASH = 2;
    const NEW_HASH = 3;
    const TIME = 4;
    const SPECS = [_]flag.FlagSpec{
        .{ .short = null, .long = "scope", .kind = .value },
        .{ .short = 'p', .long = "prompt", .kind = .value },
        .{ .short = null, .long = "old-hash", .kind = .value },
        .{ .short = null, .long = "new-hash", .kind = .value },
        .{ .short = null, .long = "time", .kind = .value },
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

    const scope = result.value(SCOPE) orelse "workspace";
    const prompt_id = result.value(PROMPT);
    const time_buckets = result.value(TIME);

    if (std.mem.eql(u8, scope, "workspace")) {
        var ws_result = stats.computeWorkspace(allocator, workspace_root) catch {
            try stderr.print("{s}{s}{s}Error:{s} Failed to compute workspace stats\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };
        defer ws_result.deinit(allocator);

        const view = stats.renderWorkspaceView(allocator, &ws_result) catch {
            try stderr.print("{s}{s}{s}Error:{s} Failed to render stats\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };
        defer allocator.free(view);
        try stdout.print("{s}{s}", .{ P, view });
        return;
    }

    if (std.mem.eql(u8, scope, "prompt")) {
        const pid = prompt_id orelse {
            try stderr.print("{s}{s}{s}Error:{s} --prompt is required for prompt scope\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };

        if (time_buckets) |tb| {
            const is_daily = std.mem.eql(u8, tb, "daily");
            const is_weekly = std.mem.eql(u8, tb, "weekly");
            if (!is_daily and !is_weekly) {
                try stderr.print("{s}{s}{s}Error:{s} --time must be 'daily' or 'weekly'\n", .{ P, Color.bold, Color.red, Color.reset });
                return;
            }

            var tb_result = stats.computeTimeBuckets(allocator, workspace_root, pid, tb) catch {
                try stderr.print("{s}{s}{s}Error:{s} Failed to compute time bucket stats\n", .{ P, Color.bold, Color.red, Color.reset });
                return;
            };
            defer tb_result.deinit(allocator);

            const view = stats.renderTimeBucketsView(allocator, &tb_result) catch {
                try stderr.print("{s}{s}{s}Error:{s} Failed to render stats\n", .{ P, Color.bold, Color.red, Color.reset });
                return;
            };
            defer allocator.free(view);
            try stdout.print("{s}{s}", .{ P, view });
            return;
        }

        var p_result = stats.computePrompt(allocator, workspace_root, pid) catch {
            try stderr.print("{s}{s}{s}Error:{s} Failed to compute prompt stats\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };
        defer p_result.deinit(allocator);

        const view = stats.renderPromptView(allocator, &p_result) catch {
            try stderr.print("{s}{s}{s}Error:{s} Failed to render stats\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };
        defer allocator.free(view);
        try stdout.print("{s}{s}", .{ P, view });
        return;
    }

    if (std.mem.eql(u8, scope, "diff")) {
        const pid = prompt_id orelse {
            try stderr.print("{s}{s}{s}Error:{s} --prompt is required for diff scope\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };
        const old_hash = result.value(OLD_HASH) orelse {
            try stderr.print("{s}{s}{s}Error:{s} --old-hash is required for diff scope\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };
        const new_hash = result.value(NEW_HASH) orelse {
            try stderr.print("{s}{s}{s}Error:{s} --new-hash is required for diff scope\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };

        var d_result = stats.computeDiff(allocator, workspace_root, pid, old_hash, new_hash) catch {
            try stderr.print("{s}{s}{s}Error:{s} Failed to compute diff stats\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };
        defer d_result.deinit(allocator);

        const view = stats.renderDiffView(allocator, &d_result) catch {
            try stderr.print("{s}{s}{s}Error:{s} Failed to render stats\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };
        defer allocator.free(view);
        try stdout.print("{s}{s}", .{ P, view });
        return;
    }

    try stderr.print("{s}{s}{s}Error:{s} Unknown scope: {s}. Use: workspace, prompt, or diff\n", .{ P, Color.bold, Color.red, Color.reset, scope });
}

fn printHelp(out: *std.Io.Writer) !void {
    try out.print("{s}Usage: {s}clumsies stats [options]{s}\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Show aggregated stats from trace data.\n", .{P});
    try out.print("{s}{s}{s}Scopes:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try out.print("{s}  {s}workspace{s} (default)   Overview of all prompts\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}prompt{s}               Per-constraint heatmap\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}diff{s}                 Compare two prompt versions\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}{s}{s}Options:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try out.print("{s}  {s}--scope{s} <scope>       Scope: workspace, prompt, diff\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-p, --prompt{s} <id>     Prompt id (required for prompt/diff)\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}--old-hash{s} <hash>     Old hash (required for diff)\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}--new-hash{s} <hash>     New hash (required for diff)\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}--time{s} <daily|weekly>  Time-series view\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-h, --help{s}            Show this help\n", .{ P, Color.cyan, Color.reset });
}
