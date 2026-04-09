const std = @import("std");
const testing = std.testing;
const build_options = @import("build_options");
const styles = @import("styles.zig");

const cmd_login = @import("commands/login_cmd.zig");
const cmd_init = @import("commands/init_cmd.zig");
const cmd_sync = @import("commands/sync_cmd.zig");
const cmd_mcp = @import("commands/mcp_cmd.zig");
const cmd_setup = @import("commands/setup_cmd.zig");
const cmd_help = @import("commands/help.zig");

const Color = styles.Color;
const P = styles.P;

const version = build_options.version;

const Command = enum {
    login,
    init_cmd,
    sync,
    mcp,
    help,
    version,
    none,
};

const command_map = std.StaticStringMap(Command).initComptime(.{
    .{ "login", .login },
    .{ "init", .init_cmd },
    .{ "sync", .sync },
    .{ "mcp", .mcp },
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
        .login => try cmd_login.run(stdout_writer, stderr_writer, allocator, cmd_args),
        .init_cmd => try cmd_init.run(stdout_writer, stderr_writer, allocator, cmd_args),
        .sync => try cmd_sync.run(stdout_writer, stderr_writer, allocator, cmd_args),
        .mcp => try cmd_mcp.run(stdout_writer, stderr_writer, allocator, cmd_args, version),
        .none => {
            if (args.len > 1) {
                // Unknown command
                try stderr_writer.print("{s}{s}{s}Error:{s} unknown command '{s}'\n\n", .{ P, Color.bold, Color.red, Color.reset, args[1] });
                try cmd_help.run(stderr_writer);
                stderr_file_writer.interface.flush() catch {};
                std.process.exit(1);
            } else {
                // No args — TUI placeholder
                try stdout_writer.print("{s}{s}{s}clumsies{s} {s}\n\n", .{ P, Color.bold, Color.orange, Color.reset, version });
                try stdout_writer.print("TUI Dashboard is not yet available.\n\n", .{});
                try cmd_help.run(stdout_writer);
            }
        },
    }
}

test "command_map: all commands resolve" {
    const expected = [_]struct { str: []const u8, cmd: Command }{
        .{ .str = "login", .cmd = .login },
        .{ .str = "init", .cmd = .init_cmd },
        .{ .str = "sync", .cmd = .sync },
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

test "command_map: old commands return null" {
    const old_cmds = [_][]const u8{ "add", "rm", "push", "pull", "remote", "clone", "upgrade", "status", "log", "ls", "show", "set", "get", "pub", "stats", "config" };
    for (old_cmds) |cmd| {
        try testing.expect(command_map.get(cmd) == null);
    }
}

test "command_map: unknown command returns null" {
    try testing.expect(command_map.get("foobar") == null);
    try testing.expect(command_map.get("") == null);
}
