const std = @import("std");
const flag = @import("../flags.zig");
const ws_config = @import("../workspace_config.zig");
const lib = @import("clumsies_lib");
const styles = @import("../styles.zig");

const Color = styles.Color;
const P = styles.P;

const ALLOWED_TYPES = [_][]const u8{ "session_input", "setup", "search", "load", "refer" };

const FLAG_TYPE: usize = 0;
const FLAG_CONTENT: usize = 1;

/// `clumsies trace append --type <type> [--content <text>]`
///
/// Append a single trace event to the current workspace's trace.jsonl. The
/// session_id comes from current_session.json, written by the active MCP
/// serve process. The event_id uses microseconds-since-epoch so it never
/// collides with the in-process counter MCP uses for its own events.
///
/// Best-effort: silent failure on missing binding, missing session marker,
/// or trace write errors. Designed to be called from adapter hook scripts
/// where blocking the user is unacceptable.
pub fn run(stdout: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator, args: []const []const u8) !void {
    _ = stdout;

    const SPECS = [_]flag.FlagSpec{
        .{ .short = 't', .long = "type", .kind = .value },
        .{ .short = 'c', .long = "content", .kind = .value },
    };

    var err_ctx: flag.ErrorContext = .{};
    var result = flag.parse(&SPECS, allocator, args, &err_ctx) catch |err| switch (err) {
        error.HelpRequested => {
            try printHelp(stderr);
            return;
        },
        error.UnknownFlag => {
            try stderr.print("Error: unknown flag {s}\n", .{err_ctx.flag.?});
            return;
        },
        error.MissingValue => {
            try stderr.print("Error: {s} requires a value\n", .{err_ctx.flag.?});
            return;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer result.deinit(allocator);

    const event_type = result.value(FLAG_TYPE) orelse {
        try stderr.writeAll("Error: --type is required\n");
        return;
    };

    var allowed = false;
    for (ALLOWED_TYPES) |t| {
        if (std.mem.eql(u8, t, event_type)) {
            allowed = true;
            break;
        }
    }
    if (!allowed) {
        try stderr.writeAll("Error: --type must be one of session_input/setup/search/load/refer\n");
        return;
    }

    const cwd = std.fs.cwd().realpathAlloc(allocator, ".") catch return;
    defer allocator.free(cwd);

    const binding = ws_config.resolveWorkspace(allocator, cwd) catch return;
    defer allocator.free(binding.ws_id);
    defer allocator.free(binding.name);

    const ws_dir = ws_config.getWsDir(allocator, binding.ws_id) catch return;
    defer allocator.free(ws_dir);

    const marker_opt = lib.session_marker.read(allocator, ws_dir) catch null;
    if (marker_opt == null) return;
    const marker = marker_opt.?;
    defer allocator.free(marker.session_id);

    const content_opt = result.value(FLAG_CONTENT);
    var content_hash_owned: ?[]const u8 = null;
    defer if (content_hash_owned) |h| allocator.free(h);
    if (content_opt) |c| {
        content_hash_owned = try lib.prompt.hashContentHexAlloc(allocator, c);
    }

    const event_id = std.time.microTimestamp();

    lib.trace.appendTraceEvent(allocator, .{
        .ws_id = binding.ws_id,
        .session_id = marker.session_id,
        .event_id = event_id,
        .type = event_type,
        .timestamp = std.time.milliTimestamp(),
        .content = content_opt,
        .content_hash = content_hash_owned,
    }) catch |err| {
        std.log.warn("trace append failed: {}", .{err});
        return;
    };
}

fn printHelp(out: *std.Io.Writer) !void {
    try out.print("{s}{s}clumsies trace append{s}\n\n", .{ P, Color.bold, Color.reset });
    try out.print("Append a single trace event to the current workspace's trace.jsonl.\n", .{});
    try out.print("Intended for adapter hooks (UserPromptSubmit, etc).\n\n", .{});
    try out.print("{s}Usage:{s}\n", .{ Color.bold, Color.reset });
    try out.print("  clumsies trace append --type session_input --content \"hello\"\n", .{});
}
