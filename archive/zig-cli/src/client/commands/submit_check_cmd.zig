const std = @import("std");
const attestation = @import("../attestation.zig");
const host_session = @import("../host_session.zig");
const workspace_config = @import("../workspace_config.zig");

/// `clumsies _agent submit-check`
///
/// Checks whether the agent has submitted an agent_report attestation event
/// since the most recent user_prompt in the current session. Used by the
/// stop hook to decide whether to inject a reminder.
///
/// Exit 0 = agent_report found (agent already submitted)
/// Exit 1 = no agent_report since last user_prompt
///
/// Best-effort: silent failure on missing binding, missing hook session,
/// or file read errors. Designed to be called from adapter hook scripts
/// where blocking the user is unacceptable.
pub fn run(stdout: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator) !void {
    _ = stdout;
    _ = stderr;

    const cwd = std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return;
    defer allocator.free(cwd);

    const binding = workspace_config.resolveWorkspace(allocator, cwd) catch return;
    defer allocator.free(binding.ws_id);
    defer allocator.free(binding.name);

    const session_id = host_session.resolveHookSessionId(allocator) orelse return;
    defer allocator.free(session_id);

    const attestation_path = attestation.sessionAttestationFilePath(allocator, binding.ws_id, session_id) catch return;
    defer allocator.free(attestation_path);

    const file = std.Io.Dir.openFileAbsolute(std.Options.debug_io, attestation_path, .{}) catch return;
    defer file.close(std.Options.debug_io);

    const stat = file.stat(std.Options.debug_io) catch return;
    if (stat.size == 0) return;

    var contents_buf: [10 * 1024 * 1024]u8 = undefined;
    var reader = file.reader(std.Options.debug_io, &contents_buf);
    const contents = reader.interface.allocRemaining(allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch return;
    defer allocator.free(contents);

    var found_user_prompt = false;
    var found_report = false;

    var lines = std.mem.splitSequence(u8, contents, "\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        if (std.mem.indexOf(u8, line, session_id) == null) continue;

        if (std.mem.indexOf(u8, line, "\"type\":\"user_prompt\"") != null) {
            found_user_prompt = true;
            found_report = false;
        } else if (std.mem.indexOf(u8, line, "\"type\":\"agent_report\"") != null) {
            if (found_user_prompt) {
                found_report = true;
            }
        }
    }

    if (found_report) {
        std.process.exit(0);
    } else {
        std.process.exit(1);
    }
}
