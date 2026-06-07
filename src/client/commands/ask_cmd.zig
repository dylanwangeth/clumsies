const std = @import("std");
const clumsies = @import("clumsies_lib");
const agent_config = @import("../agent_config.zig");
const agent_workspace = @import("../agent_workspace.zig");
const styles = @import("../styles.zig");

const agent = clumsies.agent;
const Color = styles.Color;
const P = styles.P;

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

    if (args.len == 0) return promptRequired(stderr);

    const prompt = try std.mem.join(allocator, " ", args);
    defer allocator.free(prompt);
    const trimmed_prompt = validPrompt(prompt) orelse return promptRequired(stderr);

    const tool_root = agent_workspace.resolveToolRoot(allocator) catch |err| {
        try printWorkspaceRootError(stderr, err);
        return error.CommandFailed;
    };
    defer allocator.free(tool_root);

    var provider_env = agent_config.loadFromDir(allocator, tool_root) catch |err| {
        try printProviderConfigError(stderr, err);
        return error.CommandFailed;
    };
    defer provider_env.deinit();

    var provider_state = agent.providers.OpenAICompatible.init(allocator, .{
        .base_url = provider_env.base_url,
        .api_key = provider_env.api_key,
        .model = provider_env.model,
        .auth = if (provider_env.api_key_header_name) |header| .{ .api_key = header } else .bearer,
        .request_timeout_ms = provider_env.timeout_ms,
        .use_env_proxy = provider_env.use_env_proxy,
    });
    defer provider_state.deinit();

    const messages = [_]agent.transcript.Message{
        .{ .user = .{ .content = trimmed_prompt } },
    };

    var builtins: agent.tools.Builtin = .{ .workspace_path = tool_root };
    var tool_runtime = builtins.runtime();
    const run_result = agent.loop.run(allocator, &messages, .{
        .model_provider = provider_state.provider(),
        .tool_runtime = &tool_runtime,
        .provider_options = .{ .max_output_tokens = provider_env.max_output_tokens },
    }) catch |err| {
        if (provider_state.takeLastError()) |provider_error| {
            defer provider_error.deinit(allocator);
            try printProviderHttpError(stderr, provider_error);
            return error.CommandFailed;
        }
        if (provider_state.takeLastTransportFailure()) |failure| {
            defer failure.deinit(allocator);
            try stderr.print("{s}{s}{s}Error:{s} provider transport failed at {s}: {s}\n", .{
                P,
                Color.bold,
                Color.red,
                Color.reset,
                @tagName(failure.stage),
                failure.message,
            });
            return error.CommandFailed;
        }
        try stderr.print("{s}{s}{s}Error:{s} provider request failed: {s} (model {s}, proxy {s}, timeout {d}ms)\n", .{
            P,
            Color.bold,
            Color.red,
            Color.reset,
            @errorName(err),
            provider_env.model,
            proxyLabel(provider_env.use_env_proxy),
            provider_env.timeout_ms,
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
    try stdout.print("Runs one prompt through the configured provider and built-in coding tools, then prints the final assistant reply.\n", .{});
    try stdout.print("Provider configuration is read from the workspace .env and environment variables; .env wins for CLUMSIES_AGENT_PROVIDER_* keys.\n", .{});
    try stdout.print("Set CLUMSIES_AGENT_PROVIDER_MAX_OUTPUT_TOKENS when you want to cap assistant output explicitly.\n", .{});
    try stdout.print("Provider requests use HTTP_PROXY/HTTPS_PROXY automatically; set CLUMSIES_AGENT_PROVIDER_USE_PROXY=false to bypass them.\n", .{});
}

fn promptRequired(stderr: *std.Io.Writer) !void {
    try stderr.print("{s}{s}{s}Error:{s} prompt is required.\n\n", .{ P, Color.bold, Color.red, Color.reset });
    try printHelp(stderr);
    return error.CommandFailed;
}

fn validPrompt(prompt: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, prompt, " \t\r\n");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn printProviderConfigError(stderr: *std.Io.Writer, err: anyerror) !void {
    try stderr.print("{s}{s}{s}Error:{s} ", .{
        P,
        Color.bold,
        Color.red,
        Color.reset,
    });
    try agent_config.printError(stderr, err);
    try stderr.writeAll(". Set provider configuration in the environment or .env.\n");
}

fn printWorkspaceRootError(stderr: *std.Io.Writer, err: anyerror) !void {
    try stderr.print("{s}{s}{s}Error:{s} could not resolve agent workspace root: {s}\n", .{
        P,
        Color.bold,
        Color.red,
        Color.reset,
        @errorName(err),
    });
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

    if (std.unicode.utf8ValidateSlice(trimmed)) {
        try stderr.print(": {s}\n", .{truncateUtf8Boundary(trimmed, 1024)});
        return;
    }

    var hex_buf: [128]u8 = undefined;
    const prefix = trimmed[0..@min(trimmed.len, 32)];
    const hex = std.fmt.bufPrint(&hex_buf, "{f}", .{std.ascii.hexEscape(prefix, .lower)}) catch unreachable;
    try stderr.print(": non-UTF-8 response body ({d} bytes, hex prefix {s})\n", .{ trimmed.len, hex });
}

fn proxyLabel(use_env_proxy: bool) []const u8 {
    return if (use_env_proxy) "auto" else "off";
}

/// Bounds provider diagnostics without splitting localized UTF-8 text.
fn truncateUtf8Boundary(text: []const u8, max_bytes: usize) []const u8 {
    var end = @min(text.len, max_bytes);
    if (end == text.len) return text;
    while (end > 0 and (text[end] & 0xc0) == 0x80) : (end -= 1) {}
    return text[0..end];
}

test "truncateUtf8Boundary keeps CLI provider diagnostics valid" {
    try std.testing.expectEqualStrings("评价", truncateUtf8Boundary("评价一下", 7));
    try std.testing.expectEqualStrings("评价", truncateUtf8Boundary("评价", 6));
}

test "validPrompt rejects whitespace-only prompts" {
    try std.testing.expect(validPrompt(" \t\r\n") == null);
    try std.testing.expectEqualStrings("hello", validPrompt("  hello \n").?);
}
