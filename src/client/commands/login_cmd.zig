const std = @import("std");
const testing = std.testing;
const flag = @import("../flags.zig");
const hub_client = @import("../hub_client.zig");
const auth_mod = @import("../auth.zig");
const auth_api = @import("clumsies_lib").protocol.auth_api;
const LoginResponse = auth_api.LoginResponse;
const HubClient = hub_client.HubClient;
const HubResponse = hub_client.Response;
const styles = @import("../styles.zig");

const Color = styles.Color;
const P = styles.P;

const DEFAULT_HUB_URL = "http://127.0.0.1:8400";
const HubUrlError = std.mem.Allocator.Error || error{
    InvalidHubUrl,
    UnsupportedHubUrlScheme,
};

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
        error.UnexpectedArgument => {
            try stderr.print("{s}{s}{s}Error:{s} Unexpected argument: {s}\n", .{ P, Color.bold, Color.red, Color.reset, err_ctx.flag.? });
            try printHelp(stderr);
            return;
        },
        error.MissingValue => {
            try stderr.print("{s}{s}{s}Error:{s} {s} requires a value\n", .{ P, Color.bold, Color.red, Color.reset, err_ctx.flag.? });
            return;
        },
    };
    defer result.deinit(allocator);

    const hub_url = normalizeHubUrl(allocator, result.value(0) orelse DEFAULT_HUB_URL) catch |err| switch (err) {
        error.InvalidHubUrl => {
            try stderr.print("{s}{s}{s}Error:{s} Invalid hub URL. Use a full URL like http://127.0.0.1:8400 or localhost:8400.\n", .{
                P,
                Color.bold,
                Color.red,
                Color.reset,
            });
            return error.CommandFailed;
        },
        error.UnsupportedHubUrlScheme => {
            try stderr.print("{s}{s}{s}Error:{s} Hub URL must use http:// or https://\n", .{
                P,
                Color.bold,
                Color.red,
                Color.reset,
            });
            return error.CommandFailed;
        },
        else => return err,
    };
    defer allocator.free(hub_url);

    // Get username: from flag or rule interactively
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
    defer client.deinit();
    const response = try postOrPrintClientError(stderr, &client, hub_url, "/api/auth/login", body);
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

    const activate_resp = try postOrPrintClientError(stderr, &client, hub_url, "/api/auth/activate", activate_body);
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

fn postOrPrintClientError(
    stderr: *std.Io.Writer,
    client: *HubClient,
    hub_url: []const u8,
    path: []const u8,
    body: []const u8,
) !HubResponse {
    return client.post(path, body) catch |err| {
        try printHubRequestError(stderr, hub_url, err);
        return error.CommandFailed;
    };
}

fn printHubRequestError(stderr: *std.Io.Writer, hub_url: []const u8, err: anyerror) !void {
    switch (err) {
        error.ConnectionRefused => {
            try stderr.print(
                "{s}{s}{s}Error:{s} Failed to reach hub at {s} (connection refused). Start clumsies-hub or pass --hub-url.\n",
                .{ P, Color.bold, Color.red, Color.reset, hub_url },
            );
        },
        error.ConnectionTimedOut => {
            try stderr.print(
                "{s}{s}{s}Error:{s} Hub request to {s} timed out. Check that clumsies-hub is reachable or pass --hub-url.\n",
                .{ P, Color.bold, Color.red, Color.reset, hub_url },
            );
        },
        error.NetworkUnreachable => {
            try stderr.print(
                "{s}{s}{s}Error:{s} Network is unreachable for hub {s}. Check your network or pass --hub-url.\n",
                .{ P, Color.bold, Color.red, Color.reset, hub_url },
            );
        },
        error.TemporaryNameServerFailure, error.NameServerFailure, error.UnknownHostName, error.HostLacksNetworkAddresses => {
            try stderr.print(
                "{s}{s}{s}Error:{s} Could not resolve hub host in {s}. Check --hub-url.\n",
                .{ P, Color.bold, Color.red, Color.reset, hub_url },
            );
        },
        error.ConnectionResetByPeer => {
            try stderr.print(
                "{s}{s}{s}Error:{s} Hub connection to {s} was reset. Check that clumsies-hub is healthy.\n",
                .{ P, Color.bold, Color.red, Color.reset, hub_url },
            );
        },
        error.UnsupportedUriScheme => {
            try stderr.print(
                "{s}{s}{s}Error:{s} Hub URL must use http:// or https://\n",
                .{ P, Color.bold, Color.red, Color.reset },
            );
        },
        error.TlsInitializationFailed => {
            try stderr.print(
                "{s}{s}{s}Error:{s} Failed to initialize TLS for hub {s}. Check the URL scheme and TLS settings.\n",
                .{ P, Color.bold, Color.red, Color.reset, hub_url },
            );
        },
        error.UnexpectedConnectFailure => {
            try stderr.print(
                "{s}{s}{s}Error:{s} Failed to open a network connection to hub {s}. Start clumsies-hub or pass --hub-url.\n",
                .{ P, Color.bold, Color.red, Color.reset, hub_url },
            );
        },
        else => {
            try stderr.print(
                "{s}{s}{s}Error:{s} Failed to contact hub at {s} ({s})\n",
                .{ P, Color.bold, Color.red, Color.reset, hub_url, @errorName(err) },
            );
        },
    }
}

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

fn normalizeHubUrl(allocator: std.mem.Allocator, raw: []const u8) HubUrlError![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidHubUrl;

    const with_scheme = if (std.mem.indexOf(u8, trimmed, "://") == null)
        try std.fmt.allocPrint(allocator, "http://{s}", .{trimmed})
    else
        try allocator.dupe(u8, trimmed);
    errdefer allocator.free(with_scheme);

    const without_trailing_slash = std.mem.trimRight(u8, with_scheme, "/");
    if (without_trailing_slash.len == 0) return error.InvalidHubUrl;

    const uri = std.Uri.parse(without_trailing_slash) catch return error.InvalidHubUrl;
    if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) {
        return error.UnsupportedHubUrlScheme;
    }
    if (uri.host == null) return error.InvalidHubUrl;

    if (without_trailing_slash.len == with_scheme.len) return with_scheme;

    const normalized = try allocator.dupe(u8, without_trailing_slash);
    allocator.free(with_scheme);
    return normalized;
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

test "normalizeHubUrl adds http scheme for host:port input" {
    const normalized = try normalizeHubUrl(testing.allocator, "localhost:8410");
    defer testing.allocator.free(normalized);

    try testing.expectEqualStrings("http://localhost:8410", normalized);
}

test "normalizeHubUrl trims trailing slash" {
    const normalized = try normalizeHubUrl(testing.allocator, "http://127.0.0.1:8410/");
    defer testing.allocator.free(normalized);

    try testing.expectEqualStrings("http://127.0.0.1:8410", normalized);
}

test "normalizeHubUrl rejects unsupported schemes" {
    try testing.expectError(error.UnsupportedHubUrlScheme, normalizeHubUrl(testing.allocator, "ftp://localhost:8410"));
}

test "printHubRequestError formats connection refused without stack-oriented detail" {
    var capture = std.Io.Writer.Allocating.init(testing.allocator);
    defer capture.deinit();

    try printHubRequestError(&capture.writer, "http://127.0.0.1:8400", error.ConnectionRefused);
    const output = try capture.toOwnedSlice();
    defer testing.allocator.free(output);

    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "Failed to reach hub at http://127.0.0.1:8400"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "Start clumsies-hub or pass --hub-url."));
}

test "printHubRequestError formats bad host" {
    var capture = std.Io.Writer.Allocating.init(testing.allocator);
    defer capture.deinit();

    try printHubRequestError(&capture.writer, "http://bad-host:8400", error.UnknownHostName);
    const output = try capture.toOwnedSlice();
    defer testing.allocator.free(output);

    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "Could not resolve hub host"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "http://bad-host:8400"));
}

test "printHubRequestError formats unexpected connect failure" {
    var capture = std.Io.Writer.Allocating.init(testing.allocator);
    defer capture.deinit();

    try printHubRequestError(&capture.writer, "http://127.0.0.1:8400", error.UnexpectedConnectFailure);
    const output = try capture.toOwnedSlice();
    defer testing.allocator.free(output);

    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "Failed to open a network connection to hub http://127.0.0.1:8400"));
}

fn printHelp(out: *std.Io.Writer) !void {
    try out.print("{s}Usage: {s}clumsies login [--hub-url <url>] [--username <user>]{s}\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Authenticate with a Clumsies Hub instance.\n", .{P});
    try out.print("{s}Flags:\n", .{P});
    try out.print("{s}  {s}--hub-url <url>{s}   Hub URL (default: {s})\n", .{ P, Color.cyan, Color.reset, DEFAULT_HUB_URL });
    try out.print("{s}  {s}--username <user>{s} Username (prompted if omitted)\n", .{ P, Color.cyan, Color.reset });
}
