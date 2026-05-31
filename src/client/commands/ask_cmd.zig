const std = @import("std");
const clumsies = @import("clumsies_lib");
const logger = clumsies.logger;
const styles = @import("../styles.zig");

const agent = clumsies.agent;
const Color = styles.Color;
const P = styles.P;
const DEFAULT_MAX_OUTPUT_TOKENS = 1024;

const PROVIDER_ENV_KEYS = [_][]const u8{
    "CLUMSIES_AGENT_PROVIDER_BASE_URL",
    "CLUMSIES_AGENT_PROVIDER_API_KEY",
    "CLUMSIES_AGENT_PROVIDER_MODEL",
    "CLUMSIES_AGENT_PROVIDER_AUTH_HEADER",
};

/// Runs one prompt through the real agent loop and prints the final reply.
///
/// The command intentionally avoids a direct provider call so CLI smoke tests
/// exercise the same tool declaration, execution, and run-message replay path
/// that future interactive surfaces will use.
pub fn run(
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    if (args.len > 0 and (std.mem.eql(u8, args[0], "-h") or std.mem.eql(u8, args[0], "--help"))) {
        try printHelp(stdout);
        return;
    }

    if (args.len == 0) {
        try stderr.print("{s}{s}{s}Error:{s} prompt is required.\n\n", .{ P, Color.bold, Color.red, Color.reset });
        try printHelp(stderr);
        return error.CommandFailed;
    }

    const prompt = try std.mem.join(allocator, " ", args);
    defer allocator.free(prompt);

    var env_map = try logger.loadEnvMap(allocator);
    defer env_map.deinit();
    try loadProviderDotEnv(allocator, &env_map);

    const base_url = requiredEnv(&env_map, stderr, "CLUMSIES_AGENT_PROVIDER_BASE_URL") orelse return error.CommandFailed;
    const api_key = requiredEnv(&env_map, stderr, "CLUMSIES_AGENT_PROVIDER_API_KEY") orelse return error.CommandFailed;
    const model = requiredEnv(&env_map, stderr, "CLUMSIES_AGENT_PROVIDER_MODEL") orelse return error.CommandFailed;

    var provider_state = agent.providers.OpenAICompatible.init(allocator, .{
        .base_url = base_url,
        .api_key = api_key,
        .model = model,
        .auth = if (env_map.get("CLUMSIES_AGENT_PROVIDER_AUTH_HEADER")) |header| .{ .api_key = header } else .bearer,
    });
    defer provider_state.deinit();

    const messages = [_]agent.transcript.Message{
        .{ .user = .{ .content = prompt } },
    };

    var builtins: agent.tools.Builtin = .{};
    var tool_runtime = builtins.runtime();
    const run_result = agent.loop.run(allocator, &messages, .{
        .model_provider = provider_state.provider(),
        .tool_runtime = &tool_runtime,
        .provider_options = .{ .max_output_tokens = DEFAULT_MAX_OUTPUT_TOKENS },
    }) catch |err| {
        if (provider_state.takeLastError()) |provider_error| {
            defer provider_error.deinit(allocator);
            try printProviderHttpError(stderr, provider_error);
            return error.CommandFailed;
        }
        try stderr.print("{s}{s}{s}Error:{s} provider request failed: {s}\n", .{
            P,
            Color.bold,
            Color.red,
            Color.reset,
            @errorName(err),
        });
        return error.CommandFailed;
    };
    defer run_result.deinit(allocator);

    const final_content = lastAssistantContent(run_result.messages) orelse "";
    if (final_content.len == 0) {
        try stderr.print("{s}{s}{s}Error:{s} provider returned an empty assistant message.\n", .{
            P,
            Color.bold,
            Color.red,
            Color.reset,
        });
        return error.CommandFailed;
    }

    try stdout.print("{s}\n", .{final_content});
}

fn printHelp(stdout: *std.Io.Writer) !void {
    try stdout.print("{s}{s}{s}Usage:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}clumsies ask <prompt...>{s}\n\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("Sends one prompt to the configured OpenAI-compatible provider and prints the assistant reply.\n", .{});
    try stdout.print("Provider configuration is read from .env and environment variables; .env wins for CLUMSIES_AGENT_PROVIDER_* keys.\n", .{});
}

fn printMissingEnv(stderr: *std.Io.Writer, name: []const u8) !void {
    try stderr.print("{s}{s}{s}Error:{s} Missing {s}. Set it in the environment or .env.\n", .{
        P,
        Color.bold,
        Color.red,
        Color.reset,
        name,
    });
}

fn requiredEnv(env_map: *const std.process.EnvMap, stderr: *std.Io.Writer, name: []const u8) ?[]const u8 {
    const value = env_map.get(name) orelse {
        printMissingEnv(stderr, name) catch {};
        return null;
    };
    if (value.len == 0) {
        printMissingEnv(stderr, name) catch {};
        return null;
    }
    return value;
}

fn loadProviderDotEnv(allocator: std.mem.Allocator, env_map: *std.process.EnvMap) !void {
    const file = std.fs.cwd().openFile(".env", .{}) catch return;
    defer file.close();

    const size = file.getEndPos() catch return;
    if (size == 0) return;
    const alloc_size = std.math.cast(usize, size) orelse return;
    const contents = try allocator.alloc(u8, alloc_size);
    defer allocator.free(contents);

    var buf: [4096]u8 = undefined;
    var reader = std.fs.File.Reader.init(file, &buf);
    reader.interface.readSliceAll(contents) catch return;

    var iter = std.mem.splitSequence(u8, contents, "\n");
    while (iter.next()) |line| {
        try applyProviderEnvLine(allocator, env_map, line);
    }
}

/// Applies one `.env` line when it belongs to the provider configuration.
///
/// `.env` is allowed to override process environment for provider keys only;
/// this command should not silently change unrelated client behavior.
fn applyProviderEnvLine(allocator: std.mem.Allocator, env_map: *std.process.EnvMap, line: []const u8) !void {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return;
    const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return;
    const key = std.mem.trim(u8, trimmed[0..eq], " \t");
    if (!isProviderEnvKey(key)) return;

    const raw_value = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
    const value = stripQuotes(raw_value);
    const key_owned = try allocator.dupe(u8, key);
    errdefer allocator.free(key_owned);
    const value_owned = try allocator.dupe(u8, value);
    errdefer allocator.free(value_owned);
    try env_map.put(key_owned, value_owned);
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

/// Finds the final textual assistant response after any tool turns.
///
/// Earlier assistant messages may only request tools. The CLI should print the
/// later response produced after tool results have been replayed to the model.
fn lastAssistantContent(messages: []const agent.transcript.Message) ?[]const u8 {
    var index = messages.len;
    while (index > 0) {
        index -= 1;
        switch (messages[index]) {
            .assistant => |assistant| if (assistant.content.len > 0) return assistant.content,
            else => {},
        }
    }
    return null;
}

fn printProviderHttpError(stderr: *std.Io.Writer, provider_error: agent.providers.OpenAICompatible.ProviderError) !void {
    try stderr.print("{s}{s}{s}Error:{s} provider request failed with HTTP {d}", .{
        P,
        Color.bold,
        Color.red,
        Color.reset,
        @intFromEnum(provider_error.status),
    });

    const trimmed = std.mem.trim(u8, provider_error.body, " \t\r\n");
    if (trimmed.len == 0) {
        try stderr.print(".\n", .{});
        return;
    }

    try stderr.print(": {s}\n", .{trimmed[0..@min(trimmed.len, 1024)]});
}
