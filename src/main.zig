const std = @import("std");
const testing = std.testing;
const build_options = @import("build_options");
const styles = @import("styles.zig");

const cmd_remote = @import("commands/remote.zig");
const cmd_push = @import("commands/push.zig");
const cmd_pull = @import("commands/pull.zig");
const cmd_clone = @import("commands/clone.zig");
const cmd_status = @import("commands/status.zig");
const cmd_log = @import("commands/log.zig");
const cmd_config = @import("commands/config.zig");
const cmd_upgrade = @import("commands/upgrade.zig");
const cmd_ls = @import("commands/ls.zig");
const cmd_add = @import("commands/add_cmd.zig");
const cmd_rm = @import("commands/rm_cmd.zig");
const cmd_show = @import("commands/show_cmd.zig");
const cmd_set = @import("commands/set_cmd.zig");
const cmd_get = @import("commands/get_cmd.zig");
const cmd_pub = @import("commands/pub_cmd.zig");
const cmd_mcp = @import("commands/mcp_cmd.zig");
const cmd_stats = @import("commands/stats_cmd.zig");
const cmd_setup = @import("commands/setup_cmd.zig");
const cmd_help = @import("commands/help.zig");

const flags = @import("flags.zig");

const Color = styles.Color;
const P = styles.P;

const version = build_options.version;

const Command = enum {
    remote,
    push,
    pull,
    clone,
    status,
    log,
    ls,
    add,
    rm_cmd,
    show_cmd,
    set_cmd,
    get,
    pub_cmd,
    mcp,
    stats_cmd,
    config,
    upgrade,
    help,
    version,
    none,
};

// Command lookup table for efficient parsing
const command_map = std.StaticStringMap(Command).initComptime(.{
    .{ "remote", .remote },
    .{ "push", .push },
    .{ "pull", .pull },
    .{ "clone", .clone },
    .{ "status", .status },
    .{ "log", .log },
    .{ "ls", .ls },
    .{ "add", .add },
    .{ "rm", .rm_cmd },
    .{ "show", .show_cmd },
    .{ "set", .set_cmd },
    .{ "get", .get },
    .{ "pub", .pub_cmd },
    .{ "mcp", .mcp },
    .{ "stats", .stats_cmd },
    .{ "config", .config },
    .{ "upgrade", .upgrade },
    .{ "help", .help },
    .{ "-h", .help },
    .{ "--help", .help },
    .{ "-v", .version },
    .{ "--version", .version },
});

pub fn main() !void {
    // Setup stdout/stderr with buffers
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout_file_writer = std.fs.File.Writer.init(std.fs.File.stdout(), &stdout_buffer);
    var stderr_file_writer = std.fs.File.Writer.init(std.fs.File.stderr(), &stderr_buffer);
    defer stdout_file_writer.interface.flush() catch {};
    defer stderr_file_writer.interface.flush() catch {};
    const stdout_writer = &stdout_file_writer.interface;
    const stderr_writer = &stderr_file_writer.interface;

    // Setup allocator
    var debug_alloc = std.heap.DebugAllocator(.{}){};
    defer _ = debug_alloc.deinit();
    const allocator = debug_alloc.allocator();

    // Parse args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var cmd: Command = .none;
    var cmd_args_start: usize = 1;

    // Parse command using lookup table
    var is_agent_cmd = false;
    for (args[1..], 1..) |arg, i| {
        if (command_map.get(arg)) |matched_cmd| {
            cmd = matched_cmd;
            // Version and help don't need additional args
            if (cmd != .version and cmd != .help) {
                cmd_args_start = i + 1;
            }
            break;
        }
        // Hidden _agent prefix: clumsies _agent <subcommand> [args...]
        if (std.mem.eql(u8, arg, "_agent")) {
            is_agent_cmd = true;
            cmd_args_start = i + 1;
            break;
        }
    }

    const cmd_args = args[cmd_args_start..];

    // Handle _agent subcommands (hidden, not in help)
    if (is_agent_cmd) {
        const subcmd = if (cmd_args.len > 0) cmd_args[0] else "";
        if (std.mem.eql(u8, subcmd, "setup")) {
            try cmd_setup.run(stdout_writer, stderr_writer, allocator, cmd_args[1..]);
        } else {
            try stderr_writer.print("{s}{s}{s}Error:{s} Unknown agent command: {s}\n", .{ P, Color.bold, Color.red, Color.reset, subcmd });
        }
        return;
    }

    // Execute command
    switch (cmd) {
        .version => {
            try stdout_writer.print("{s}{s}{s}clumsies{s} {s}\n", .{ P, Color.bold, Color.orange, Color.reset, version });
        },
        .help => try cmd_help.run(stdout_writer),
        .remote => try cmd_remote.run(stdout_writer, stderr_writer, allocator, cmd_args),
        .push => try cmd_push.run(stdout_writer, stderr_writer, allocator, cmd_args),
        .pull => try cmd_pull.run(stdout_writer, stderr_writer, allocator, cmd_args),
        .clone => try cmd_clone.run(stdout_writer, stderr_writer, allocator, cmd_args),
        .status => try cmd_status.run(stdout_writer, stderr_writer, allocator),
        .log => try cmd_log.run(stdout_writer, stderr_writer, allocator),
        .ls => try cmd_ls.run(stdout_writer, stderr_writer, allocator, cmd_args),
        .add => try cmd_add.run(stdout_writer, stderr_writer, allocator, cmd_args),
        .rm_cmd => try cmd_rm.run(stdout_writer, stderr_writer, allocator, cmd_args),
        .show_cmd => try cmd_show.run(stdout_writer, stderr_writer, allocator, cmd_args),
        .set_cmd => try cmd_set.run(stdout_writer, stderr_writer, allocator, cmd_args),
        .get => try cmd_get.run(stdout_writer, stderr_writer, allocator, cmd_args),
        .pub_cmd => try cmd_pub.run(stdout_writer, stderr_writer, allocator, cmd_args),
        .mcp => try cmd_mcp.run(stdout_writer, stderr_writer, allocator, cmd_args, version),
        .stats_cmd => try cmd_stats.run(stdout_writer, stderr_writer, allocator, cmd_args),
        .config => try cmd_config.run(stdout_writer, stderr_writer, allocator, cmd_args),
        .upgrade => try cmd_upgrade.run(stdout_writer, stderr_writer, allocator, version),
        .none => try cmd_help.run(stdout_writer),
    }
}

test "command_map: all commands resolve" {
    const expected = [_]struct { str: []const u8, cmd: Command }{
        .{ .str = "remote", .cmd = .remote },
        .{ .str = "push", .cmd = .push },
        .{ .str = "pull", .cmd = .pull },
        .{ .str = "clone", .cmd = .clone },
        .{ .str = "status", .cmd = .status },
        .{ .str = "log", .cmd = .log },
        .{ .str = "ls", .cmd = .ls },
        .{ .str = "add", .cmd = .add },
        .{ .str = "rm", .cmd = .rm_cmd },
        .{ .str = "show", .cmd = .show_cmd },
        .{ .str = "set", .cmd = .set_cmd },
        .{ .str = "get", .cmd = .get },
        .{ .str = "pub", .cmd = .pub_cmd },
        .{ .str = "mcp", .cmd = .mcp },
        .{ .str = "stats", .cmd = .stats_cmd },
        .{ .str = "config", .cmd = .config },
        .{ .str = "upgrade", .cmd = .upgrade },
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
    try testing.expect(command_map.get("LS") == null);
}

test "command_map: agent-facing commands not exposed as public CLI" {
    const agent_only = [_][]const u8{ "setup", "begin", "complete", "search", "load", "refer", "validate", "_agent" };
    for (agent_only) |cmd| {
        try testing.expect(command_map.get(cmd) == null);
    }
}
