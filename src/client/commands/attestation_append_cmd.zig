const std = @import("std");
const flag = @import("../flags.zig");
const host_session = @import("../host_session.zig");
const util_hash = @import("clumsies_lib").util.hash;
const attestation = @import("../attestation.zig");
const ws_config = @import("../workspace_config.zig");
const styles = @import("../styles.zig");

const Color = styles.Color;
const P = styles.P;

const ALLOWED_TYPES = [_][]const u8{ "setup", "user_prompt", "discover", "agent_report" };

const FLAG_TYPE: usize = 0;
const FLAG_CONTENT: usize = 1;

/// `clumsies _agent attestation-append --type <type> [--content <text>]`
///
/// Append a single attestation event to the current workspace's
/// attestation log. The session_id is the host CLI session id supplied by the
/// adapter hook. The event_id is an opaque idempotency key; event ordering
/// uses timestamp.
///
/// Best-effort: silent failure on missing binding, missing hook session,
/// or attestation write errors. Designed to be called from adapter hook scripts
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
        error.UnexpectedArgument => {
            try stderr.print("Error: unexpected argument {s}\n", .{err_ctx.flag.?});
            return;
        },
        error.MissingValue => {
            try stderr.print("Error: {s} requires a value\n", .{err_ctx.flag.?});
            return;
        },
    };
    defer result.deinit(allocator);

    const event_type = result.value(FLAG_TYPE) orelse {
        try stderr.writeAll("Error: --type is required\n");
        return;
    };

    if (!isAllowedType(event_type)) {
        try stderr.writeAll("Error: --type must be one of setup/user_prompt/discover/agent_report\n");
        return;
    }

    const cwd = std.fs.cwd().realpathAlloc(allocator, ".") catch return;
    defer allocator.free(cwd);

    const binding = ws_config.resolveWorkspace(allocator, cwd) catch return;
    defer allocator.free(binding.ws_id);
    defer allocator.free(binding.name);

    const session_id = host_session.resolveHookSessionId(allocator) orelse return;
    defer allocator.free(session_id);

    const content_opt = result.value(FLAG_CONTENT);
    var content_hash_owned: ?[]const u8 = null;
    defer if (content_hash_owned) |h| allocator.free(h);
    if (content_opt) |c| {
        content_hash_owned = try util_hash.sha256HexAlloc(allocator, c);
    }

    // Build the payload based on event_type. Hook-side load/refer events are
    // intentionally unsupported because they require structured MCP payloads.
    const payload: attestation.AttestationEvent.Payload = if (std.mem.eql(u8, event_type, "user_prompt"))
        .{ .user_prompt = .{
            .content_hash = content_hash_owned orelse "",
            .content = content_opt,
        } }
    else if (std.mem.eql(u8, event_type, "setup"))
        .{ .setup = .{} }
    else if (std.mem.eql(u8, event_type, "discover"))
        .{ .discover = .{} }
    else if (std.mem.eql(u8, event_type, "agent_report"))
        .{ .agent_report = .{ .summary = content_opt orelse "" } }
    else
        .{ .setup = .{} };

    attestation.appendAttestationEvent(allocator, .{
        .ws_id = binding.ws_id,
        .session_id = session_id,
        .event_id = attestation.nextEventId(),
        .ts = std.time.milliTimestamp(),
        .payload = payload,
    }) catch |err| {
        std.log.warn("attestation append failed: {}", .{err});
        return;
    };
}

fn isAllowedType(event_type: []const u8) bool {
    for (ALLOWED_TYPES) |t| {
        if (std.mem.eql(u8, t, event_type)) return true;
    }
    return false;
}

fn printHelp(out: *std.Io.Writer) !void {
    try out.print("{s}{s}clumsies _agent attestation-append{s}\n\n", .{ P, Color.bold, Color.reset });
    try out.print("Append a single attestation event to the current workspace's attestation log.\n", .{});
    try out.print("Intended for adapter hooks (UserPromptSubmit, etc).\n\n", .{});
    try out.print("{s}Usage:{s}\n", .{ Color.bold, Color.reset });
    try out.print("  clumsies _agent attestation-append --type user_prompt --content \"hello\"\n", .{});
}

test "attestation append rejects structured MCP-only event types" {
    try std.testing.expect(!isAllowedType("load"));
    try std.testing.expect(!isAllowedType("refer"));
    try std.testing.expect(isAllowedType("user_prompt"));
    try std.testing.expect(isAllowedType("agent_report"));
}
