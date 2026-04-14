const std = @import("std");
const testing = std.testing;
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
    const LoginBody = struct { username: []const u8, credential: []const u8 };
    const body = std.json.Stringify.valueAlloc(allocator, LoginBody{ .username = username, .credential = password }, .{}) catch return error.OutOfMemory;
    defer allocator.free(body);

    // POST /api/auth/login
    var client = HubClient.init(allocator, hub_url, null);
    const response = try client.post("/api/auth/login", body);
    defer response.deinit();

    if (response.status == .ok) {
        const parsed = std.json.parseFromSlice(LoginResponse, allocator, response.body, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch {
            try stderr.print("{s}{s}{s}Error:{s} Failed to parse login response\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };
        defer parsed.deinit();
        const save_location = auth_mod.saveAuth(allocator, hub_url, username, parsed.value.access_token, parsed.value.refresh_token) catch |err| {
            try stderr.print("{s}{s}{s}Error:{s} Failed to save login credentials ({s})\n", .{ P, Color.bold, Color.red, Color.reset, @errorName(err) });
            return error.CommandFailed;
        };
        try stdout.print("{s}{s}{s}Logged in{s} as {s}{s}{s}\n", .{ P, Color.bold, Color.green, Color.reset, Color.cyan, username, Color.reset });
        try printStorageNote(stderr, allocator, save_location);
        return;
    }

    if (response.status != .unauthorized) {
        try stderr.print("{s}{s}{s}Error:{s} Login failed (HTTP {d})\n", .{ P, Color.bold, Color.red, Color.reset, @intFromEnum(response.status) });
        return;
    }

    // 401: might be wrong password or invited user needing activation
    try stderr.print("{s}Login failed. If you were invited, enter your invitation token to activate.\n", .{P});
    try stderr.print("{s}Invitation token (or press Enter to abort): ", .{P});
    try stderr.flush();
    const invite_token = try readLine(allocator);
    defer allocator.free(invite_token);

    if (invite_token.len == 0) {
        try stderr.print("{s}{s}{s}Error:{s} Login failed\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    }

    // Collect new password for activation
    try stderr.print("{s}Set password: ", .{P});
    try stderr.flush();
    const new_password = try readPassword(allocator);
    defer allocator.free(new_password);
    try stderr.print("\n", .{});

    // Build activate body
    const ActivateBody = struct { username: []const u8, invite_token: []const u8, credential: []const u8 };
    const activate_body = std.json.Stringify.valueAlloc(allocator, ActivateBody{
        .username = username,
        .invite_token = invite_token,
        .credential = new_password,
    }, .{}) catch return error.OutOfMemory;
    defer allocator.free(activate_body);

    const activate_resp = try client.post("/api/auth/activate", activate_body);
    defer activate_resp.deinit();

    if (activate_resp.status != .ok) {
        try stderr.print("{s}{s}{s}Error:{s} Activation failed (HTTP {d})\n", .{ P, Color.bold, Color.red, Color.reset, @intFromEnum(activate_resp.status) });
        if (activate_resp.body.len > 0) {
            try stderr.print("{s}{s}\n", .{ P, activate_resp.body });
        }
        return;
    }

    const parsed = std.json.parseFromSlice(LoginResponse, allocator, activate_resp.body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to parse activation response\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer parsed.deinit();
    const save_location = auth_mod.saveAuth(allocator, hub_url, username, parsed.value.access_token, parsed.value.refresh_token) catch |err| {
        try stderr.print("{s}{s}{s}Error:{s} Failed to save login credentials ({s})\n", .{ P, Color.bold, Color.red, Color.reset, @errorName(err) });
        return error.CommandFailed;
    };
    try stdout.print("{s}{s}{s}Account activated and logged in{s} as {s}{s}{s}\n", .{ P, Color.bold, Color.green, Color.reset, Color.cyan, username, Color.reset });
    try printStorageNote(stderr, allocator, save_location);
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
    const line_len = if (len > 0 and line_buf[len - 1] == '\r') len - 1 else len;
    return try allocator.dupe(u8, line_buf[0..line_len]);
}

fn readPassword(allocator: std.mem.Allocator) ![]const u8 {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag == .windows) {
        return readLine(allocator);
    }
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

fn printStorageNote(stderr: *std.Io.Writer, allocator: std.mem.Allocator, save_location: auth_mod.SaveLocation) !void {
    if (save_location != .file_fallback) return;

    const base = auth_mod.getBasePath(allocator) catch {
        try stderr.print("{s}Note: Keychain was unavailable; credentials were stored in ~/.clumsies/auth.json\n", .{P});
        return;
    };
    defer allocator.free(base);

    const path = std.fs.path.join(allocator, &.{ base, "auth.json" }) catch {
        try stderr.print("{s}Note: Keychain was unavailable; credentials were stored in ~/.clumsies/auth.json\n", .{P});
        return;
    };
    defer allocator.free(path);

    try stderr.print("{s}Note: Keychain was unavailable; credentials were stored in {s}\n", .{ P, path });
}

test "LoginResponse parsing ignores expires_in" {
    const body =
        \\{"access_token":"acc","refresh_token":"ref","expires_in":3600}
    ;

    const parsed = try std.json.parseFromSlice(LoginResponse, testing.allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try testing.expectEqualStrings("acc", parsed.value.access_token);
    try testing.expectEqualStrings("ref", parsed.value.refresh_token);
}

fn printHelp(out: *std.Io.Writer) !void {
    try out.print("{s}Usage: {s}clumsies login [--hub-url <url>] [--username <user>]{s}\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Authenticate with a Clumsies Hub instance.\n", .{P});
    try out.print("{s}Flags:\n", .{P});
    try out.print("{s}  {s}--hub-url <url>{s}   Hub URL (default: {s})\n", .{ P, Color.cyan, Color.reset, DEFAULT_HUB_URL });
    try out.print("{s}  {s}--username <user>{s} Username (prompted if omitted)\n", .{ P, Color.cyan, Color.reset });
}
