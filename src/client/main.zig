const std = @import("std");
const testing = std.testing;
const build_options = @import("build_options");
const styles = @import("styles.zig");

/// Raise the default log level so third-party debug traffic
/// (libvaxis, etc.) does not print to stderr while the terminal is
/// still in cooked mode before the TUI's alt-screen switch —
/// otherwise lines like `debug (vaxis): enabling mouse mode` flash
/// above the UI on launch. Warnings and errors still surface.
pub const std_options: std.Options = .{
    .log_level = .warn,
};

// Public re-exports for cross-artifact consumers (e.g., seed).
pub const attestation = @import("attestation.zig");
const tui = @import("tui/main.zig");

const cmd_login = @import("commands/login_cmd.zig");
const cmd_init = @import("commands/init_cmd.zig");
const cmd_sync = @import("commands/sync_cmd.zig");
const cmd_mcp = @import("commands/mcp_cmd.zig");
const cmd_adapt = @import("commands/adapt_cmd.zig");
const cmd_remove_adapter = @import("commands/remove_adapter_cmd.zig");
const cmd_setup = @import("commands/setup_cmd.zig");
const cmd_workspace_info = @import("commands/workspace_info_cmd.zig");
const cmd_flush_attestation = @import("commands/flush_attestation_cmd.zig");
const cmd_attestation_append = @import("commands/attestation_append_cmd.zig");
const cmd_submit_check = @import("commands/submit_check_cmd.zig");
const cmd_help = @import("commands/help.zig");

const Color = styles.Color;
const P = styles.P;

const version = build_options.version;

const Command = enum {
    login,
    init_cmd,
    sync,
    adapt,
    remove_adapter,
    mcp,
    flush,
    help,
    version,
    none,
};

const command_map = std.StaticStringMap(Command).initComptime(.{
    .{ "login", .login },
    .{ "init", .init_cmd },
    .{ "sync", .sync },
    .{ "adapt", .adapt },
    .{ "remove-adapter", .remove_adapter },
    .{ "mcp", .mcp },
    .{ "flush", .flush },
    .{ "help", .help },
    .{ "-h", .help },
    .{ "--help", .help },
    .{ "-v", .version },
    .{ "--version", .version },
});

pub fn main() !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout_file_writer = std.fs.File.Writer.init(std.fs.File.stdout(), &stdout_buffer);
    var stderr_file_writer = std.fs.File.Writer.init(std.fs.File.stderr(), &stderr_buffer);
    defer stdout_file_writer.interface.flush() catch {};
    defer stderr_file_writer.interface.flush() catch {};
    const stdout_writer = &stdout_file_writer.interface;
    const stderr_writer = &stderr_file_writer.interface;

    var debug_alloc: if (@import("builtin").mode == .Debug) std.heap.DebugAllocator(.{}) else struct {} =
        if (@import("builtin").mode == .Debug) .{} else .{};
    defer if (@import("builtin").mode == .Debug) {
        _ = debug_alloc.deinit();
    };
    const allocator = if (@import("builtin").mode == .Debug)
        debug_alloc.allocator()
    else
        std.heap.smp_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var cmd: Command = .none;
    var cmd_args_start: usize = 1;

    var is_agent_cmd = false;
    for (args[1..], 1..) |arg, i| {
        if (command_map.get(arg)) |matched_cmd| {
            cmd = matched_cmd;
            if (cmd != .version and cmd != .help) {
                cmd_args_start = i + 1;
            }
            break;
        }
        if (std.mem.eql(u8, arg, "_agent")) {
            is_agent_cmd = true;
            cmd_args_start = i + 1;
            break;
        }
    }

    const cmd_args = args[cmd_args_start..];

    if (is_agent_cmd) {
        const subcmd = if (cmd_args.len > 0) cmd_args[0] else "";
        if (std.mem.eql(u8, subcmd, "setup")) {
            try cmd_setup.run(stdout_writer, stderr_writer, allocator);
        } else if (std.mem.eql(u8, subcmd, "workspace-info")) {
            try cmd_workspace_info.run(stdout_writer, stderr_writer, allocator);
        } else if (std.mem.eql(u8, subcmd, "attestation-append")) {
            try cmd_attestation_append.run(stdout_writer, stderr_writer, allocator, cmd_args[1..]);
        } else if (std.mem.eql(u8, subcmd, "submit-check")) {
            try cmd_submit_check.run(stdout_writer, stderr_writer, allocator);
        } else {
            try stderr_writer.print("{s}{s}{s}Error:{s} unknown agent command: {s}\n", .{ P, Color.bold, Color.red, Color.reset, subcmd });
            stderr_file_writer.interface.flush() catch {};
            std.process.exit(1);
        }
        return;
    }

    switch (cmd) {
        .version => {
            try stdout_writer.print("{s}{s}{s}clumsies{s} {s}\n", .{ P, Color.bold, Color.orange, Color.reset, version });
        },
        .help => try cmd_help.run(stdout_writer),
        .login => cmd_login.run(stdout_writer, stderr_writer, allocator, cmd_args) catch |err| switch (err) {
            error.CommandFailed => {
                stderr_file_writer.interface.flush() catch {};
                std.process.exit(1);
            },
            else => return err,
        },
        .init_cmd => try cmd_init.run(stdout_writer, stderr_writer, allocator, cmd_args),
        .sync => try cmd_sync.run(stdout_writer, stderr_writer, allocator, cmd_args),
        .adapt => try cmd_adapt.run(stdout_writer, stderr_writer, allocator, cmd_args),
        .remove_adapter => try cmd_remove_adapter.run(stdout_writer, stderr_writer, allocator, cmd_args),
        .mcp => try cmd_mcp.run(stdout_writer, stderr_writer, allocator, cmd_args, version),
        .flush => {
            try cmd_flush_attestation.run(stdout_writer, stderr_writer, allocator, cmd_args);
        },
        .none => {
            if (args.len > 1) {
                // Unknown command
                try stderr_writer.print("{s}{s}{s}Error:{s} unknown command '{s}'\n\n", .{ P, Color.bold, Color.red, Color.reset, args[1] });
                try cmd_help.run(stderr_writer);
                stderr_file_writer.interface.flush() catch {};
                std.process.exit(1);
            } else {
                if (canLaunchTui()) {
                    try tui.run();
                } else {
                    try stdout_writer.print("{s}{s}{s}clumsies{s} {s}\n\n", .{ P, Color.bold, Color.orange, Color.reset, version });
                    try stdout_writer.print("TUI Dashboard requires an interactive terminal.\n\n", .{});
                    try cmd_help.run(stdout_writer);
                }
            }
        },
    }
}

fn canLaunchTui() bool {
    return std.fs.File.stdin().isTty() and std.fs.File.stdout().isTty();
}

test "command_map: all commands resolve" {
    const expected = [_]struct { str: []const u8, cmd: Command }{
        .{ .str = "login", .cmd = .login },
        .{ .str = "init", .cmd = .init_cmd },
        .{ .str = "sync", .cmd = .sync },
        .{ .str = "adapt", .cmd = .adapt },
        .{ .str = "remove-adapter", .cmd = .remove_adapter },
        .{ .str = "flush", .cmd = .flush },
        .{ .str = "mcp", .cmd = .mcp },
        .{ .str = "help", .cmd = .help },
        .{ .str = "-h", .cmd = .help },
        .{ .str = "--help", .cmd = .help },
        .{ .str = "-v", .cmd = .version },
        .{ .str = "--version", .cmd = .version },
    };
    for (expected) |e| {
        const result = command_map.get(e.str);
        try testing.expect(result != null);
        try testing.expectEqual(e.cmd, result.?);
    }
}

test "command_map: unknown command returns null" {
    try testing.expect(command_map.get("foobar") == null);
    try testing.expect(command_map.get("") == null);
}

// Test aggregator. `zig build test` runs tests declared on the root
// module's container (this file). Test blocks in files reached only
// through ordinary `const x = @import(...)` imports are NOT collected.
// The only way to pull them in is an explicit reference inside a test
// block — that is what this block does. When adding a new `.zig` file
// with tests, register it here so CI actually runs them.
test {
    _ = @import("clumsies_lib");

    _ = @import("adapter/model.zig");
    _ = @import("adapter/packages/claude_code.zig");
    _ = @import("adapter/packages/codex.zig");
    _ = @import("adapter/primitives/json_mcp_registry.zig");
    _ = @import("adapter/primitives/json_ops.zig");
    _ = @import("adapter/primitives/toml_ops.zig");
    _ = @import("adapter/remove.zig");
    _ = @import("adapter/root.zig");
    _ = @import("adapter/store.zig");
    _ = @import("adapter/workflow_skills.zig");

    _ = @import("batch_upload.zig");
    _ = @import("drafts.zig");
    _ = @import("flags.zig");
    _ = @import("prompt.zig");
    _ = @import("session_marker.zig");
    _ = @import("attestation.zig");
    _ = @import("workspace_config.zig");

    _ = @import("commands/init_cmd.zig");
    _ = @import("commands/login_cmd.zig");
    _ = @import("commands/sync_cmd.zig");

    _ = @import("mcp/jsonrpc.zig");
    _ = @import("mcp/server.zig");
    _ = @import("mcp/tool_result.zig");
    _ = @import("mcp/tools.zig");

    _ = @import("tui/api/cache.zig");
    _ = @import("tui/api/dispatcher.zig");
    _ = @import("tui/api/parse.zig");
    _ = @import("tui/api/request.zig");
    _ = @import("tui/api/view_model.zig");
    _ = @import("tui/app/workspace.zig");
    _ = @import("tui/editor_host.zig");
    _ = @import("tui/attestation_reader.zig");
    _ = @import("tui/tree.zig");
    _ = @import("tui/widgets.zig");
    _ = @import("tui/widgets/diff_viewer.zig");
}
