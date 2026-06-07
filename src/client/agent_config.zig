//! Agent provider configuration shared by CLI and TUI surfaces.
//!
//! The provider adapter itself lives under `src/agent`; this module is the
//! client-side configuration boundary that reads process environment and `.env`
//! files, validates required keys, and keeps the loaded `EnvMap` alive for the
//! borrowed provider slices.

const std = @import("std");

pub const DEFAULT_REQUEST_TIMEOUT_MS: u64 = 60 * std.time.ms_per_s;

const PROVIDER_ENV_KEYS = [_][]const u8{
    "CLUMSIES_AGENT_PROVIDER_BASE_URL",
    "CLUMSIES_AGENT_PROVIDER_API_KEY",
    "CLUMSIES_AGENT_PROVIDER_MODEL",
    "CLUMSIES_AGENT_PROVIDER_AUTH_HEADER",
    "CLUMSIES_AGENT_PROVIDER_TIMEOUT_MS",
    "CLUMSIES_AGENT_PROVIDER_MAX_OUTPUT_TOKENS",
    "CLUMSIES_AGENT_PROVIDER_USE_PROXY",
};

pub const Error = error{
    MissingBaseUrl,
    MissingApiKey,
    MissingModel,
    InvalidTimeout,
    InvalidMaxOutputTokens,
    InvalidUseProxy,
};

pub const ProviderEnv = struct {
    env_map: std.process.EnvMap,
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    /// Optional header name for providers that expect raw API keys instead of
    /// `Authorization: Bearer ...`.
    api_key_header_name: ?[]const u8 = null,
    timeout_ms: u64 = DEFAULT_REQUEST_TIMEOUT_MS,
    max_output_tokens: ?u32 = null,
    use_env_proxy: bool = true,

    /// Releases the environment map that owns every returned slice.
    pub fn deinit(self: *ProviderEnv) void {
        self.env_map.deinit();
    }
};

/// Loads provider configuration from process environment and cwd `.env`.
///
/// `.env` intentionally overrides process values for `CLUMSIES_AGENT_PROVIDER_*`
/// keys so local model/provider switching behaves the same in CLI and TUI
/// sessions without mutating unrelated client configuration.
pub fn load(allocator: std.mem.Allocator) !ProviderEnv {
    return loadFromDir(allocator, null);
}

/// Loads provider configuration with an optional explicit `.env` directory.
///
/// Agent surfaces that resolve a project/workspace root should pass that root
/// here so provider config and built-in tool roots describe the same project,
/// even when the process was launched from a subdirectory.
pub fn loadFromDir(allocator: std.mem.Allocator, dot_env_dir: ?[]const u8) !ProviderEnv {
    var env_map = try std.process.getEnvMap(allocator);
    errdefer env_map.deinit();
    try loadProviderDotEnv(allocator, &env_map, dot_env_dir);

    const base_url = required(&env_map, "CLUMSIES_AGENT_PROVIDER_BASE_URL") orelse return Error.MissingBaseUrl;
    const api_key = required(&env_map, "CLUMSIES_AGENT_PROVIDER_API_KEY") orelse return Error.MissingApiKey;
    const model = required(&env_map, "CLUMSIES_AGENT_PROVIDER_MODEL") orelse return Error.MissingModel;
    return .{
        .env_map = env_map,
        .base_url = base_url,
        .api_key = api_key,
        .model = model,
        .api_key_header_name = env_map.get("CLUMSIES_AGENT_PROVIDER_AUTH_HEADER"),
        .timeout_ms = (optionalUnsigned(&env_map, "CLUMSIES_AGENT_PROVIDER_TIMEOUT_MS") catch return Error.InvalidTimeout) orelse DEFAULT_REQUEST_TIMEOUT_MS,
        .max_output_tokens = optionalU32(&env_map, "CLUMSIES_AGENT_PROVIDER_MAX_OUTPUT_TOKENS") catch return Error.InvalidMaxOutputTokens,
        .use_env_proxy = (optionalBool(&env_map, "CLUMSIES_AGENT_PROVIDER_USE_PROXY") catch return Error.InvalidUseProxy) orelse true,
    };
}

/// Returns the concrete environment key responsible for a config error.
pub fn errorKey(err: anyerror) ?[]const u8 {
    return switch (err) {
        Error.MissingBaseUrl => "CLUMSIES_AGENT_PROVIDER_BASE_URL",
        Error.MissingApiKey => "CLUMSIES_AGENT_PROVIDER_API_KEY",
        Error.MissingModel => "CLUMSIES_AGENT_PROVIDER_MODEL",
        Error.InvalidTimeout => "CLUMSIES_AGENT_PROVIDER_TIMEOUT_MS",
        Error.InvalidMaxOutputTokens => "CLUMSIES_AGENT_PROVIDER_MAX_OUTPUT_TOKENS",
        Error.InvalidUseProxy => "CLUMSIES_AGENT_PROVIDER_USE_PROXY",
        else => null,
    };
}

/// Writes a human-readable provider configuration diagnostic.
///
/// CLI and TUI callers share this wording so provider setup failures do not
/// leak internal Zig error names into user-facing surfaces.
pub fn printError(writer: *std.Io.Writer, err: anyerror) !void {
    switch (err) {
        Error.MissingBaseUrl,
        Error.MissingApiKey,
        Error.MissingModel,
        => try writer.print("missing {s}", .{errorKey(err).?}),
        Error.InvalidTimeout => try writer.print("{s} must be an unsigned millisecond value", .{errorKey(err).?}),
        Error.InvalidMaxOutputTokens => try writer.print("{s} must be an unsigned 32-bit token count", .{errorKey(err).?}),
        Error.InvalidUseProxy => try writer.print("{s} must be true or false", .{errorKey(err).?}),
        else => try writer.print("provider configuration failed: {s}", .{@errorName(err)}),
    }
}

fn required(env_map: *const std.process.EnvMap, name: []const u8) ?[]const u8 {
    const value = env_map.get(name) orelse return null;
    if (value.len == 0) return null;
    return value;
}

fn optionalUnsigned(env_map: *const std.process.EnvMap, name: []const u8) !?u64 {
    const value = env_map.get(name) orelse return null;
    if (value.len == 0) return null;
    return try std.fmt.parseUnsigned(u64, value, 10);
}

fn optionalU32(env_map: *const std.process.EnvMap, name: []const u8) !?u32 {
    const value = env_map.get(name) orelse return null;
    if (value.len == 0) return null;
    return try std.fmt.parseUnsigned(u32, value, 10);
}

fn optionalBool(env_map: *const std.process.EnvMap, name: []const u8) !?bool {
    const value = env_map.get(name) orelse return null;
    if (value.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(value, "true") or std.mem.eql(u8, value, "1")) return true;
    if (std.ascii.eqlIgnoreCase(value, "false") or std.mem.eql(u8, value, "0")) return false;
    return error.InvalidBool;
}

fn loadProviderDotEnv(
    allocator: std.mem.Allocator,
    env_map: *std.process.EnvMap,
    dot_env_dir: ?[]const u8,
) !void {
    if (dot_env_dir) |dir_path| {
        var dir = if (std.fs.path.isAbsolute(dir_path))
            try std.fs.openDirAbsolute(dir_path, .{})
        else
            try std.fs.cwd().openDir(dir_path, .{});
        defer dir.close();
        return try loadProviderDotEnvFromDir(allocator, env_map, dir);
    }
    return try loadProviderDotEnvFromDir(allocator, env_map, std.fs.cwd());
}

fn loadProviderDotEnvFromDir(
    allocator: std.mem.Allocator,
    env_map: *std.process.EnvMap,
    dir: std.fs.Dir,
) !void {
    const file = dir.openFile(".env", .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    defer file.close();

    const size = try file.getEndPos();
    if (size == 0) return;
    const alloc_size = std.math.cast(usize, size) orelse return error.FileTooBig;
    const contents = try allocator.alloc(u8, alloc_size);
    defer allocator.free(contents);

    var buf: [4096]u8 = undefined;
    var reader = std.fs.File.Reader.init(file, &buf);
    try reader.interface.readSliceAll(contents);

    var iter = std.mem.splitSequence(u8, contents, "\n");
    while (iter.next()) |line| {
        try applyProviderEnvLine(env_map, line);
    }
}

/// Applies one provider `.env` line and ignores unrelated keys.
///
/// Provider configuration is allowed to override the process environment
/// because developers frequently switch real model endpoints per workspace.
fn applyProviderEnvLine(env_map: *std.process.EnvMap, line: []const u8) !void {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return;
    const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return;
    const key = providerEnvKey(std.mem.trim(u8, trimmed[0..eq], " \t"));
    if (!isProviderEnvKey(key)) return;

    const raw_value = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
    const value = stripQuotes(raw_value);
    try env_map.put(key, value);
}

fn providerEnvKey(raw_key: []const u8) []const u8 {
    const export_keyword = "export";
    if (std.mem.startsWith(u8, raw_key, export_keyword) and raw_key.len > export_keyword.len) {
        const separator = raw_key[export_keyword.len];
        if (separator == ' ' or separator == '\t') {
            return std.mem.trim(u8, raw_key[export_keyword.len..], " \t");
        }
    }
    return raw_key;
}

fn isProviderEnvKey(key: []const u8) bool {
    inline for (PROVIDER_ENV_KEYS) |candidate| {
        if (std.mem.eql(u8, key, candidate)) return true;
    }
    return false;
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and ((s[0] == '"' and s[s.len - 1] == '"') or (s[0] == '\'' and s[s.len - 1] == '\''))) {
        return s[1 .. s.len - 1];
    }
    return s;
}

test "provider key filter ignores unrelated environment" {
    try std.testing.expect(isProviderEnvKey("CLUMSIES_AGENT_PROVIDER_MODEL"));
    try std.testing.expect(isProviderEnvKey("CLUMSIES_AGENT_PROVIDER_TIMEOUT_MS"));
    try std.testing.expect(isProviderEnvKey("CLUMSIES_AGENT_PROVIDER_MAX_OUTPUT_TOKENS"));
    try std.testing.expect(isProviderEnvKey("CLUMSIES_AGENT_PROVIDER_USE_PROXY"));
    try std.testing.expect(!isProviderEnvKey("CLUMSIES_HUB_URL"));
}

test "stripQuotes removes matching shell quotes" {
    try std.testing.expectEqualStrings("abc", stripQuotes("\"abc\""));
    try std.testing.expectEqualStrings("abc", stripQuotes("'abc'"));
    try std.testing.expectEqualStrings("\"abc", stripQuotes("\"abc"));
}

test "provider timeout parses from provider environment" {
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();

    try applyProviderEnvLine(&env_map, "CLUMSIES_AGENT_PROVIDER_TIMEOUT_MS=\"2500\"");
    try std.testing.expectEqual(@as(?u64, 2500), try optionalUnsigned(&env_map, "CLUMSIES_AGENT_PROVIDER_TIMEOUT_MS"));
}

test "provider dot env accepts shell export prefix" {
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();

    try applyProviderEnvLine(&env_map, "export CLUMSIES_AGENT_PROVIDER_MODEL=\"deepseek-chat\"");
    try std.testing.expectEqualStrings("deepseek-chat", env_map.get("CLUMSIES_AGENT_PROVIDER_MODEL").?);

    try applyProviderEnvLine(&env_map, "export\tCLUMSIES_AGENT_PROVIDER_TIMEOUT_MS=2500");
    try std.testing.expectEqual(@as(?u64, 2500), try optionalUnsigned(&env_map, "CLUMSIES_AGENT_PROVIDER_TIMEOUT_MS"));
}

test "provider max output tokens parses from provider environment" {
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();

    try applyProviderEnvLine(&env_map, "CLUMSIES_AGENT_PROVIDER_MAX_OUTPUT_TOKENS=\"4096\"");
    try std.testing.expectEqual(@as(?u32, 4096), try optionalU32(&env_map, "CLUMSIES_AGENT_PROVIDER_MAX_OUTPUT_TOKENS"));
}

test "provider proxy flag parses from provider environment" {
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();

    try applyProviderEnvLine(&env_map, "CLUMSIES_AGENT_PROVIDER_USE_PROXY=\"true\"");
    try std.testing.expectEqual(@as(?bool, true), try optionalBool(&env_map, "CLUMSIES_AGENT_PROVIDER_USE_PROXY"));

    try env_map.put("CLUMSIES_AGENT_PROVIDER_USE_PROXY", "0");
    try std.testing.expectEqual(@as(?bool, false), try optionalBool(&env_map, "CLUMSIES_AGENT_PROVIDER_USE_PROXY"));
}

test "provider dot env can load from explicit project directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{
        .sub_path = ".env",
        .data =
        \\CLUMSIES_AGENT_PROVIDER_BASE_URL="https://api.example.test"
        \\CLUMSIES_AGENT_PROVIDER_API_KEY="secret"
        \\CLUMSIES_AGENT_PROVIDER_MODEL="agent-model"
        \\CLUMSIES_AGENT_PROVIDER_AUTH_HEADER="x-api-key"
        \\CLUMSIES_AGENT_PROVIDER_TIMEOUT_MS="1234"
        \\CLUMSIES_AGENT_PROVIDER_MAX_OUTPUT_TOKENS="4096"
        \\CLUMSIES_AGENT_PROVIDER_USE_PROXY="true"
        \\CLUMSIES_HUB_URL="ignored"
        \\
        ,
    });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const project_root = try tmp.dir.realpath(".", &path_buf);
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();

    try loadProviderDotEnv(std.testing.allocator, &env_map, project_root);
    try std.testing.expectEqualStrings("https://api.example.test", env_map.get("CLUMSIES_AGENT_PROVIDER_BASE_URL").?);
    try std.testing.expectEqualStrings("secret", env_map.get("CLUMSIES_AGENT_PROVIDER_API_KEY").?);
    try std.testing.expectEqualStrings("agent-model", env_map.get("CLUMSIES_AGENT_PROVIDER_MODEL").?);
    try std.testing.expectEqualStrings("x-api-key", env_map.get("CLUMSIES_AGENT_PROVIDER_AUTH_HEADER").?);
    try std.testing.expectEqual(@as(?u64, 1234), try optionalUnsigned(&env_map, "CLUMSIES_AGENT_PROVIDER_TIMEOUT_MS"));
    try std.testing.expectEqual(@as(?u32, 4096), try optionalU32(&env_map, "CLUMSIES_AGENT_PROVIDER_MAX_OUTPUT_TOKENS"));
    try std.testing.expectEqual(@as(?bool, true), try optionalBool(&env_map, "CLUMSIES_AGENT_PROVIDER_USE_PROXY"));
    try std.testing.expect(env_map.get("CLUMSIES_HUB_URL") == null);
}

test "provider dot env overrides existing provider keys only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{
        .sub_path = ".env",
        .data =
        \\CLUMSIES_AGENT_PROVIDER_MODEL="project-model"
        \\CLUMSIES_HUB_URL="ignored"
        \\
        ,
    });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const project_root = try tmp.dir.realpath(".", &path_buf);
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("CLUMSIES_AGENT_PROVIDER_MODEL", "process-model");
    try env_map.put("CLUMSIES_HUB_URL", "http://127.0.0.1:8400");

    try loadProviderDotEnv(std.testing.allocator, &env_map, project_root);

    try std.testing.expectEqualStrings("project-model", env_map.get("CLUMSIES_AGENT_PROVIDER_MODEL").?);
    try std.testing.expectEqualStrings("http://127.0.0.1:8400", env_map.get("CLUMSIES_HUB_URL").?);
}

test "provider config exposes API-key header name from project dot env" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{
        .sub_path = ".env",
        .data =
        \\CLUMSIES_AGENT_PROVIDER_BASE_URL="https://api.example.test"
        \\CLUMSIES_AGENT_PROVIDER_API_KEY="secret"
        \\CLUMSIES_AGENT_PROVIDER_MODEL="agent-model"
        \\CLUMSIES_AGENT_PROVIDER_AUTH_HEADER="x-api-key"
        \\
        ,
    });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const project_root = try tmp.dir.realpath(".", &path_buf);
    var provider_env = try loadFromDir(std.testing.allocator, project_root);
    defer provider_env.deinit();

    try std.testing.expectEqualStrings("x-api-key", provider_env.api_key_header_name.?);
}

test "provider config diagnostic names invalid timeout key" {
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();

    try printError(&writer.writer, Error.InvalidTimeout);
    const message = try writer.toOwnedSlice();
    defer std.testing.allocator.free(message);

    try std.testing.expectEqualStrings(
        "CLUMSIES_AGENT_PROVIDER_TIMEOUT_MS must be an unsigned millisecond value",
        message,
    );
}

test "provider config diagnostic names invalid max output token key" {
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();

    try printError(&writer.writer, Error.InvalidMaxOutputTokens);
    const message = try writer.toOwnedSlice();
    defer std.testing.allocator.free(message);

    try std.testing.expectEqualStrings(
        "CLUMSIES_AGENT_PROVIDER_MAX_OUTPUT_TOKENS must be an unsigned 32-bit token count",
        message,
    );
}

test "provider config diagnostic names invalid proxy key" {
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();

    try printError(&writer.writer, Error.InvalidUseProxy);
    const message = try writer.toOwnedSlice();
    defer std.testing.allocator.free(message);

    try std.testing.expectEqualStrings(
        "CLUMSIES_AGENT_PROVIDER_USE_PROXY must be true or false",
        message,
    );
}
