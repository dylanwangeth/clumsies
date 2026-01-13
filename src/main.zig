const std = @import("std");
const build_options = @import("build_options");
const styles = @import("styles.zig");

const cmd_init = @import("commands/init.zig");
const cmd_push = @import("commands/push.zig");
const cmd_pull = @import("commands/pull.zig");
const cmd_clone = @import("commands/clone.zig");
const cmd_status = @import("commands/status.zig");
const cmd_log = @import("commands/log.zig");
const cmd_config = @import("commands/config.zig");
const cmd_upgrade = @import("commands/upgrade.zig");
const cmd_bundle = @import("commands/bundle.zig");
const cmd_prompt = @import("commands/prompt.zig");
const cmd_help = @import("commands/help.zig");

const Color = styles.Color;
const P = styles.P;

const version = build_options.version;

const Command = enum {
    init,
    push,
    pull,
    clone,
    status,
    log,
    bundle,
    prompt,
    config,
    upgrade,
    help,
    version,
    none,
};

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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var cmd: Command = .none;
    var cmd_args_start: usize = 1;

    // Parse command
    for (args[1..], 1..) |arg, i| {
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            cmd = .version;
            break;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "help")) {
            cmd = .help;
            break;
        } else if (std.mem.eql(u8, arg, "init")) {
            cmd = .init;
            cmd_args_start = i + 1;
            break;
        } else if (std.mem.eql(u8, arg, "push")) {
            cmd = .push;
            cmd_args_start = i + 1;
            break;
        } else if (std.mem.eql(u8, arg, "pull")) {
            cmd = .pull;
            cmd_args_start = i + 1;
            break;
        } else if (std.mem.eql(u8, arg, "clone")) {
            cmd = .clone;
            cmd_args_start = i + 1;
            break;
        } else if (std.mem.eql(u8, arg, "status")) {
            cmd = .status;
            cmd_args_start = i + 1;
            break;
        } else if (std.mem.eql(u8, arg, "log")) {
            cmd = .log;
            cmd_args_start = i + 1;
            break;
        } else if (std.mem.eql(u8, arg, "bundle")) {
            cmd = .bundle;
            cmd_args_start = i + 1;
            break;
        } else if (std.mem.eql(u8, arg, "prompt")) {
            cmd = .prompt;
            cmd_args_start = i + 1;
            break;
        } else if (std.mem.eql(u8, arg, "config")) {
            cmd = .config;
            cmd_args_start = i + 1;
            break;
        } else if (std.mem.eql(u8, arg, "upgrade")) {
            cmd = .upgrade;
            cmd_args_start = i + 1;
            break;
        }
    }

    const cmd_args = args[cmd_args_start..];

    // Execute command
    switch (cmd) {
        .version => {
            try stdout_writer.print("\n{s}{s}{s}clumsies{s} {s}\n\n", .{ P, Color.bold, Color.orange, Color.reset, version });
        },
        .help => {
            try cmd_help.run(stdout_writer);
        },
        .init => {
            try cmd_init.run(stdout_writer, stderr_writer, allocator, cmd_args);
        },
        .push => {
            try cmd_push.run(stdout_writer, stderr_writer, allocator, cmd_args);
        },
        .pull => {
            try cmd_pull.run(stdout_writer, stderr_writer, allocator);
        },
        .clone => {
            try cmd_clone.run(stdout_writer, stderr_writer, allocator, cmd_args);
        },
        .status => {
            try cmd_status.run(stdout_writer, stderr_writer, allocator);
        },
        .log => {
            try cmd_log.run(stdout_writer, stderr_writer, allocator);
        },
        .bundle => {
            try cmd_bundle.run(stdout_writer, stderr_writer, allocator, cmd_args);
        },
        .prompt => {
            try cmd_prompt.run(stdout_writer, stderr_writer, allocator, cmd_args);
        },
        .config => {
            try cmd_config.run(stdout_writer, stderr_writer, allocator, cmd_args);
        },
        .upgrade => {
            try cmd_upgrade.run(stdout_writer, stderr_writer, allocator, version);
        },
        .none => {
            try cmd_help.run(stdout_writer);
        },
    }
}
