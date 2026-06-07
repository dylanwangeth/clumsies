const std = @import("std");
const testing = std.testing;
const build_options = @import("build_options");
const hub_main = @import("clumsies_hub_main");
const logger = @import("clumsies_lib").logger;
const styles = @import("styles.zig");

// Compile-time filter set to .debug so logger.logFn controls
// filtering. This suppresses third-party debug output (libvaxis, etc.)
// at runtime rather than compile time, while keeping our own scoped
// logs visible at the configured level.
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logger.logFn,
};

fn recoverPanic(msg: []const u8, ra: ?usize) noreturn {
    const vaxis = @import("vaxis");
    vaxis.recover();
    var stderr_buf: [256]u8 = undefined;
    var stderr_writer = std.fs.File.Writer.init(std.fs.File.stderr(), &stderr_buf);
    stderr_writer.interface.writeAll("\x1b[0m\x1b[?25h\r\n") catch {};
    stderr_writer.interface.flush() catch {};
    std.debug.defaultPanic(msg, ra);
}

pub const panic = std.debug.FullPanic(recoverPanic);

const tui = @import("tui/main.zig");

const cmd_login = @import("commands/login_cmd.zig");
const cmd_init = @import("commands/init_cmd.zig");
const cmd_sync = @import("commands/sync_cmd.zig");
const cmd_mcp = @import("commands/mcp_cmd.zig");
const cmd_adapt = @import("commands/adapt_cmd.zig");
const cmd_setup = @import("commands/setup_cmd.zig");
const cmd_workspace_info = @import("commands/workspace_info_cmd.zig");
const cmd_attestation_append = @import("commands/attestation_append_cmd.zig");
const cmd_submit_check = @import("commands/submit_check_cmd.zig");
const cmd_ask = @import("commands/ask_cmd.zig");
const cmd_help = @import("commands/help.zig");

const Color = styles.Color;
const P = styles.P;

const version = build_options.version;

const Command = enum {
    login,
    init_cmd,
    sync,
    adapt,
    mcp,
    hub,
    ask,
    help,
    version,
    none,
};

const command_map = std.StaticStringMap(Command).initComptime(.{
    .{ "login", .login },
    .{ "init", .init_cmd },
    .{ "sync", .sync },
    .{ "adapt", .adapt },
    .{ "mcp", .mcp },
    .{ "hub", .hub },
    .{ "ask", .ask },
    .{ "help", .help },
    .{ "-h", .help },
    .{ "--help", .help },
    .{ "-v", .version },
    .{ "--version", .version },
});

pub fn main() void {
    run() catch |err| {
        if (err == error.CommandFailed) {
            std.process.exit(1);
        }
        var stderr_buffer: [4096]u8 = undefined;
        var stderr_file_writer = std.fs.File.Writer.init(std.fs.File.stderr(), &stderr_buffer);
        defer stderr_file_writer.interface.flush() catch {};
        stderr_file_writer.interface.print("{s}{s}{s}Error:{s} {s}\n", .{
            P,
            Color.bold,
            Color.red,
            Color.reset,
            @errorName(err),
        }) catch {};
        std.process.exit(1);
    };
}

fn run() !void {
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

    if (cmd == .hub) {
        if (cmd_args.len > 0) {
            if (std.mem.eql(u8, cmd_args[0], "-h") or std.mem.eql(u8, cmd_args[0], "--help")) {
                try printHubHelp(stdout_writer);
                return;
            }
            try stderr_writer.print("{s}{s}{s}Error:{s} unknown hub argument: {s}\n", .{ P, Color.bold, Color.red, Color.reset, cmd_args[0] });
            return error.CommandFailed;
        }
        hub_main.run(allocator) catch |err| switch (err) {
            error.HubStartupFailed => return error.CommandFailed,
            else => return err,
        };
        return;
    }

    initClientLogger(allocator);
    defer logger.deinit();

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
            return error.CommandFailed;
        }
        return;
    }

    switch (cmd) {
        .version => {
            try stdout_writer.print("{s}{s}{s}clumsies{s} {s}\n", .{ P, Color.bold, Color.orange, Color.reset, version });
        },
        .help => try cmd_help.run(stdout_writer),
        .login => cmd_login.run(stdout_writer, stderr_writer, allocator, cmd_args) catch |err| switch (err) {
            error.CommandFailed => return error.CommandFailed,
            else => return err,
        },
        .init_cmd => try cmd_init.run(stdout_writer, stderr_writer, allocator, cmd_args),
        .sync => try cmd_sync.run(stdout_writer, stderr_writer, allocator, cmd_args),
        .adapt => try cmd_adapt.run(stdout_writer, stderr_writer, allocator, cmd_args),
        .mcp => try cmd_mcp.run(stdout_writer, stderr_writer, allocator, cmd_args, version),
        .ask => try cmd_ask.run(stdout_writer, stderr_writer, allocator, cmd_args),
        .hub => unreachable,
        .none => {
            if (args.len > 1) {
                // Unknown command
                try stderr_writer.print("{s}{s}{s}Error:{s} unknown command '{s}'\n\n", .{ P, Color.bold, Color.red, Color.reset, args[1] });
                try cmd_help.run(stderr_writer);
                return error.CommandFailed;
            } else {
                if (canLaunchTui()) {
                    try tui.run();
                } else {
                    try stdout_writer.print("{s}{s}{s}clumsies{s} {s}\n\n", .{ P, Color.bold, Color.orange, Color.reset, version });
                    try stdout_writer.print("TUI Shell requires an interactive terminal.\n\n", .{});
                    try cmd_help.run(stdout_writer);
                }
            }
        },
    }
}

fn canLaunchTui() bool {
    return std.fs.File.stdin().isTty() and std.fs.File.stdout().isTty();
}

fn initClientLogger(allocator: std.mem.Allocator) void {
    var env_map = logger.loadEnvMap(allocator) catch {
        logger.initBestEffort(.{ .level = .info, .sink = .disabled });
        return;
    };
    defer env_map.deinit();

    const config = logger.configFromEnvMap(&env_map);

    const log_file_path = clientLogFilePath(allocator) catch {
        logger.initBestEffort(.{ .level = config.level, .sink = .disabled });
        return;
    };
    defer allocator.free(log_file_path);

    logger.initBestEffort(.{
        .level = config.level,
        .sink = .{ .file = log_file_path },
        .rotate = config.rotate,
        .max_bytes = config.max_bytes,
        .backups = config.backups,
    });
    std.log.scoped(.client_logger).info("client log file={s}", .{log_file_path});
    if (config.invalid_level) |raw| logger.noteInvalidLevel(raw);
}

fn printHubHelp(stdout: *std.Io.Writer) !void {
    try stdout.print("{s}{s}{s}Usage:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}clumsies hub{s}    Start Hub server\n\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("Hub reads configuration from environment variables and .env.\n", .{});
}

fn clientLogFilePath(allocator: std.mem.Allocator) ![]const u8 {
    const env_path = std.process.getEnvVarOwned(allocator, "CLUMSIES_LOG_FILE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return logger.clientDefaultLogPath(allocator),
        else => return err,
    };
    defer allocator.free(env_path);
    return logger.resolveLogFilePath(allocator, env_path);
}

test "command_map: all commands resolve" {
    const expected = [_]struct { str: []const u8, cmd: Command }{
        .{ .str = "login", .cmd = .login },
        .{ .str = "init", .cmd = .init_cmd },
        .{ .str = "sync", .cmd = .sync },
        .{ .str = "adapt", .cmd = .adapt },
        .{ .str = "mcp", .cmd = .mcp },
        .{ .str = "hub", .cmd = .hub },
        .{ .str = "ask", .cmd = .ask },
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
    _ = @import("agent_config.zig");
    _ = @import("agent_workspace.zig");
    _ = @import("drafts.zig");
    _ = @import("flags.zig");
    _ = @import("host_session.zig");
    _ = @import("local_content.zig");
    _ = @import("rule.zig");
    _ = @import("attestation.zig");
    _ = @import("workspace_config.zig");

    _ = @import("commands/init_cmd.zig");
    _ = @import("commands/login_cmd.zig");
    _ = @import("commands/sync_cmd.zig");
    _ = @import("commands/ask_cmd.zig");

    _ = @import("mcp/jsonrpc.zig");
    _ = @import("mcp/server.zig");
    _ = @import("mcp/tool_result.zig");
    _ = @import("mcp/tools.zig");

    _ = @import("tui/api/cache.zig");
    _ = @import("tui/api/dispatcher.zig");
    _ = @import("tui/api/parse.zig");
    _ = @import("tui/api/request.zig");
    _ = @import("tui/api/view_model.zig");
    _ = @import("tui/api.zig");
    _ = @import("tui/features.zig");
    _ = @import("tui/features/agent/root.zig");
    _ = @import("tui/features/analysis/root.zig");
    _ = @import("tui/features/dashboard/root.zig");
    _ = @import("tui/features/drafts/root.zig");
    _ = @import("tui/features/artifact/root.zig");
    _ = @import("tui/features/review/root.zig");
    _ = @import("tui/features/settings/root.zig");
    _ = @import("tui/features/workspace/root.zig");
    _ = @import("tui/main.zig");
    _ = @import("tui/models.zig");
    _ = @import("tui/models/view_types.zig");
    _ = @import("tui/prefs.zig");
    _ = @import("tui/runtime.zig");
    _ = @import("tui/runtime/agent_runner.zig");
    _ = @import("tui/runtime/drafts_reader.zig");
    _ = @import("tui/runtime/editor_host.zig");
    _ = @import("tui/runtime/markdown_viewer.zig");
    _ = @import("tui/runtime/attestation_reader.zig");
    _ = @import("tui/models/path_tree.zig");
    _ = @import("tui/shell.zig");
    _ = @import("tui/tasks.zig");
    _ = @import("tui/tasks/attestation_upload.zig");
    _ = @import("tui/widgets.zig");
    _ = @import("tui/widgets/diff_viewer.zig");
}
