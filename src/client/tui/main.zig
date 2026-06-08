const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Shell = @import("shell.zig").Shell;
const auth_mod = @import("../auth.zig");
const api = @import("api.zig");
const tasks = @import("tasks.zig");
const agent_runner = @import("runtime/agent_runner.zig");
const agent_workspace = @import("../agent_workspace.zig");
const agent = @import("clumsies_lib").agent;
const persistence = agent.session_persistence;

pub fn run() !void {
    var da: std.heap.DebugAllocator(.{}) = .init;
    defer _ = da.deinit();
    const allocator = da.allocator();

    var api_state = api.state.ApiState.init(allocator);
    api_state.bindAllocator();
    try loadAgentSession(&api_state, allocator);
    defer api_state.deinit();
    // Wait for every dispatcher-spawned worker to finish before tearing
    // down the allocator; otherwise a late worker would write through
    // freed memory. Runs before api_state.deinit thanks to reverse-defer
    // order.
    defer api_state.thread_registry.joinAll(allocator);

    // startFetch registers its spawned bootstrap thread into
    // api_state.thread_registry, so joinAll above catches it on exit.
    if (auth_mod.loadAuth(allocator)) |auth_info| {
        defer auth_info.deinit(allocator);
        api.fetch.startFetch(&api_state, auth_info.hub_url, auth_info.username, auth_info.access_token, auth_info.refresh_token) catch {};
        tasks.attestation_upload.start(&api_state) catch {};
    } else |_| {}

    var app = try vxfw.App.init(allocator);
    defer app.deinit();

    if (builtin.os.tag != .windows) {
        var title_buffer: [64]u8 = undefined;
        var title_writer = std.fs.File.Writer.init(std.fs.File.stdout(), &title_buffer);
        defer title_writer.interface.flush() catch {};
        title_writer.interface.writeAll("\x1b]2;clumsies hub\x07") catch {};
    }

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    var dashboard = Shell.init(&api_state, app, &env_map);
    defer dashboard.deinit();
    try app.run(dashboard.widget(), .{});
}

/// Loads any previously persisted agent session for the current workspace.
///
/// Session files live at `~/.clumsies/agent/sessions/<hash>.jsonl` where
/// the hash is derived from the workspace root. If no file exists, the
/// session stays empty and new runs will create it on first persist.
fn loadAgentSession(api_state: *api.state.ApiState, allocator: std.mem.Allocator) !void {
    const tool_root = agent_workspace.resolveToolRoot(allocator) catch return;
    defer allocator.free(tool_root);

    var hasher = std.hash.Wyhash.init(0);
    hasher.update(tool_root);
    const digest = hasher.final();

    const home = std.process.getEnvVarOwned(allocator, "HOME") catch
        std.process.getEnvVarOwned(allocator, "USERPROFILE") catch
        return;
    defer allocator.free(home);

    const sessions_dir = try std.fs.path.join(allocator, &.{ home, ".clumsies", "agent", "sessions" });
    defer allocator.free(sessions_dir);

    var name_buf: [20]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{x}.jsonl", .{digest}) catch return;
    const path = try std.fs.path.join(allocator, &.{ sessions_dir, name });
    defer allocator.free(path);

    // File may not exist yet — that's fine, the session starts empty.
    std.fs.cwd().access(path, .{}) catch return;

    // Load and replace the default empty session.
    api_state.agent_session.deinit();
    api_state.agent_session = persistence.loadFromFile(api_state.backing_allocator, path) catch {
        api_state.agent_session = agent.Session.init(api_state.backing_allocator);
    };
}

pub fn main() !void {
    try run();
}
