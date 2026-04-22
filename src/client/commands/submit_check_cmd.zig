const std = @import("std");
const attestation = @import("../attestation.zig");
const session_marker = @import("../session_marker.zig");
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
/// Best-effort: silent failure on missing binding, missing session marker,
/// or file read errors. Designed to be called from adapter hook scripts
/// where blocking the user is unacceptable.
pub fn run(stdout: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator) !void {
    _ = stdout;
    _ = stderr;

    const cwd = std.fs.cwd().realpathAlloc(allocator, ".") catch return;
    defer allocator.free(cwd);

    const binding = workspace_config.resolveWorkspace(allocator, cwd) catch return;
    defer allocator.free(binding.ws_id);
    defer allocator.free(binding.name);

    const ws_dir = workspace_config.getWsDir(allocator, binding.ws_id) catch return;
    defer allocator.free(ws_dir);

    const marker_opt = session_marker.read(allocator, ws_dir) catch null;
    if (marker_opt == null) return;
    const marker = marker_opt.?;
    defer allocator.free(marker.session_id);

    const attestation_path = attestation.attestationFilePath(allocator, binding.ws_id) catch return;
    defer allocator.free(attestation_path);

    const file = std.fs.openFileAbsolute(attestation_path, .{}) catch return;
    defer file.close();

    const stat = file.stat() catch return;
    if (stat.size == 0) return;

    var contents_buf: [10 * 1024 * 1024]u8 = undefined;
    var reader = file.reader(&contents_buf);
    const contents = reader.interface.allocRemaining(allocator, std.io.Limit.limited(10 * 1024 * 1024)) catch return;
    defer allocator.free(contents);

    var found_user_prompt = false;
    var found_report = false;

    var lines = std.mem.splitSequence(u8, contents, "\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        // Quick check for session_id and type without full JSON parse
        if (std.mem.indexOf(u8, line, marker.session_id) == null) continue;

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
