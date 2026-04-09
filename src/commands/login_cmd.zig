const std = @import("std");
const flag = @import("../flags.zig");
const auth_mod = @import("../auth.zig");
const HubClient = @import("../hub_client.zig").HubClient;
const styles = @import("../styles.zig");

const Color = styles.Color;
const P = styles.P;

const DEFAULT_HUB_URL = "http://127.0.0.1:8400";

pub fn run(stdout: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const SPECS = [_]flag.FlagSpec{
        .{ .short = null, .long = "hub-url", .kind = .value },
        .{ .short = 'u', .long = "username", .kind = .value },
    };

    var err_ctx: flag.ErrorContext = .{};
    var result = flag.parse(&SPECS, allocator, args, &err_ctx) catch |err| switch (err) {
        error.HelpRequested => {
            try printHelp(stdout);
            return;
        },
        error.UnknownFlag => {
            try stderr.print("{s}{s}{s}Error:{s} Unknown flag: {s}\n", .{ P, Color.bold, Color.red, Color.reset, err_ctx.flag.? });
            try printHelp(stderr);
            return;
        },
        error.MissingValue => {
            try stderr.print("{s}{s}{s}Error:{s} {s} requires a value\n", .{ P, Color.bold, Color.red, Color.reset, err_ctx.flag.? });
            return;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer result.deinit(allocator);

    const hub_url = result.value(0) orelse DEFAULT_HUB_URL;

    // Get username: from flag or prompt interactively
    const username_from_prompt: ?[]const u8 = if (result.value(1) != null) null else blk: {
        try stderr.print("{s}Username: ", .{P});
        try stderr.flush();
        break :blk try readLine(allocator);
    };
    defer if (username_from_prompt) |u| allocator.free(u);
    const username = result.value(1) orelse username_from_prompt.?;

    // Prompt for password with echo suppressed
    try stderr.print("{s}Password: ", .{P});
    try stderr.flush();
    const password = try readPassword(allocator);
    defer allocator.free(password);
    try stderr.print("\n", .{});

    // Build JSON body
    const body = try std.fmt.allocPrint(allocator, "{{\"username\":\"{s}\",\"credential\":\"{s}\"}}", .{ username, password });
    defer allocator.free(body);

    // POST /api/auth/login
    var client = HubClient.init(allocator, hub_url, null);
    const response = try client.post("/api/auth/login", body);

    if (response.status != .ok) {
        try stderr.print("{s}{s}{s}Error:{s} Login failed (HTTP {d})\n", .{ P, Color.bold, Color.red, Color.reset, @intFromEnum(response.status) });
        if (response.body.len > 0) {
            try stderr.print("{s}{s}\n", .{ P, response.body });
        }
        return;
    }

    // Parse response JSON for access_token and refresh_token
    const parsed = std.json.parseFromSlice(LoginResponse, allocator, response.body, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to parse login response\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer parsed.deinit();

    const access_token = parsed.value.access_token;
    const refresh_token = parsed.value.refresh_token;

    // Save auth
    try auth_mod.saveAuth(allocator, hub_url, username, access_token, refresh_token);

    try stdout.print("{s}{s}{s}Logged in{s} as {s}{s}{s}\n", .{ P, Color.bold, Color.green, Color.reset, Color.cyan, username, Color.reset });
}

fn readLine(allocator: std.mem.Allocator) ![]const u8 {
    var line_buf: [1024]u8 = undefined;
    var len: usize = 0;
    const stdin = std.fs.File.stdin();
    while (len < line_buf.len) {
        var byte: [1]u8 = undefined;
        const n = stdin.read(&byte) catch break;
        if (n == 0) break;
        if (byte[0] == '\n') break;
        line_buf[len] = byte[0];
        len += 1;
    }
    return try allocator.dupe(u8, line_buf[0..len]);
}

fn readPassword(allocator: std.mem.Allocator) ![]const u8 {
    const stdin_fd = std.fs.File.stdin().handle;
    const old_termios = std.posix.tcgetattr(stdin_fd) catch {
        return readLine(allocator);
    };
    var new_termios = old_termios;
    new_termios.lflag.ECHO = false;
    std.posix.tcsetattr(stdin_fd, .FLUSH, new_termios) catch {
        return readLine(allocator);
    };
    defer std.posix.tcsetattr(stdin_fd, .FLUSH, old_termios) catch {};
    return readLine(allocator);
}

const LoginResponse = struct {
    access_token: []const u8,
    refresh_token: []const u8,
};

fn printHelp(out: *std.Io.Writer) !void {
    try out.print("{s}Usage: {s}clumsies login [--hub-url <url>] [--username <user>]{s}\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Authenticate with a Clumsies Hub instance.\n", .{P});
    try out.print("{s}Flags:\n", .{P});
    try out.print("{s}  {s}--hub-url <url>{s}   Hub URL (default: {s})\n", .{ P, Color.cyan, Color.reset, DEFAULT_HUB_URL });
    try out.print("{s}  {s}--username <user>{s} Username (prompted if omitted)\n", .{ P, Color.cyan, Color.reset });
}
