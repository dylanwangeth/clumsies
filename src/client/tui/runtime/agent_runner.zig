//! Background execution bridge from the TUI to the agent loop.
//!
//! Provider requests and local tools are blocking operations. This module keeps
//! them off the vaxis event thread and streams loop events back into
//! `ApiState.agent_session` under the shared TUI mutex.

const std = @import("std");
const clumsies = @import("clumsies_lib");
const agent_config = @import("../../agent_config.zig");
const agent_workspace = @import("../../agent_workspace.zig");
const state = @import("../api/state.zig");

const agent = clumsies.agent;
const event = agent.event;
const log = std.log.scoped(.tui_agent);

const StartContext = struct {
    api_state: *state.ApiState,
    prompt: []const u8,
    run_id: u64,
};

const WatchdogContext = struct {
    api_state: *state.ApiState,
    prompt: []const u8,
    run_id: u64,
    timeout_ms: u64,
};

const SinkContext = struct {
    api_state: *state.ApiState,
    run_id: u64,
};

const CancelContext = struct {
    api_state: *state.ApiState,
    run_id: u64,
};

const Preflight = struct {
    tool_root: []const u8,
    model: []const u8,
    timeout_ms: u64,
    use_env_proxy: bool,

    fn deinit(self: Preflight, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_root);
        allocator.free(self.model);
    }
};

/// Starts one agent run from a user prompt.
///
/// The function copies `prompt` before spawning so callers may keep using their
/// input buffer. Only one run is allowed at a time because the initial TUI
/// surface renders a single live session; later session tabs can lift that
/// restriction by owning one runner per conversation.
pub fn start(api_state: *state.ApiState, prompt: []const u8) !void {
    if (std.mem.trim(u8, prompt, " \t\r\n").len == 0) return error.EmptyPrompt;
    try ensureNoActiveRun(api_state);

    const preflight = try preflightProviderConfig(api_state);
    defer preflight.deinit(api_state.backing_allocator);
    log.info("agent_start_requested workspace={s}", .{preflight.tool_root});

    const display_model = try api_state.backing_allocator.dupe(u8, preflight.model);
    var display_model_owned = true;
    errdefer if (display_model_owned) api_state.backing_allocator.free(display_model);
    const prompt_copy = try api_state.backing_allocator.dupe(u8, prompt);
    var prompt_owned = true;
    errdefer if (prompt_owned) api_state.backing_allocator.free(prompt_copy);
    var watchdog_owned = preflight.timeout_ms > 0;
    var watchdog_prompt_owned = false;
    const watchdog_prompt = if (watchdog_owned) blk: {
        const copy = try api_state.backing_allocator.dupe(u8, prompt);
        watchdog_prompt_owned = true;
        break :blk copy;
    } else "";
    errdefer if (watchdog_prompt_owned) api_state.backing_allocator.free(watchdog_prompt);
    var context_owned = true;
    var context_initialized = false;
    const ctx = try api_state.backing_allocator.create(StartContext);
    errdefer if (context_owned) {
        if (context_initialized) {
            allocatorCleanup(api_state, ctx);
        } else {
            api_state.backing_allocator.destroy(ctx);
        }
    };
    const watchdog_ctx = if (watchdog_owned)
        try api_state.backing_allocator.create(WatchdogContext)
    else
        null;
    errdefer if (watchdog_owned) api_state.backing_allocator.destroy(watchdog_ctx.?);

    var run_id: u64 = undefined;
    {
        api_state.mutex.lock();
        defer api_state.mutex.unlock();
        if (api_state.agent_run_active) return error.AgentRunInProgress;

        api_state.agent_session.clearCurrentRun();
        api_state.agent_run_active = true;
        api_state.agent_run_cancel_requested = false;
        clearProviderMetadataLocked(api_state);
        api_state.agent_provider_model = display_model;
        api_state.agent_provider_timeout_ms = preflight.timeout_ms;
        api_state.agent_provider_use_proxy = preflight.use_env_proxy;
        display_model_owned = false;
        api_state.agent_run_id +%= 1;
        run_id = api_state.agent_run_id;
        if (api_state.agent_run_error) |message| {
            api_state.backing_allocator.free(message);
            api_state.agent_run_error = null;
        }
    }
    ctx.* = .{
        .api_state = api_state,
        .prompt = prompt_copy,
        .run_id = run_id,
    };
    context_initialized = true;
    prompt_owned = false;
    if (watchdog_ctx) |watchdog_context| {
        watchdog_context.* = .{
            .api_state = api_state,
            .prompt = watchdog_prompt,
            .run_id = run_id,
            .timeout_ms = preflight.timeout_ms,
        };
        api_state.thread_registry.spawnRegistered(api_state.backing_allocator, watchdog, .{watchdog_context}) catch |err| {
            recordRunFailureForRun(api_state, run_id, prompt_copy, @errorName(err)) catch |record_err| {
                log.warn("agent_watchdog_spawn_failure_record_failed run_id={d} err={s}", .{ run_id, @errorName(record_err) });
            };
            setErrorForRun(api_state, run_id, @errorName(err)) catch |set_err| {
                log.warn("agent_watchdog_spawn_error_record_failed err={s}", .{@errorName(set_err)});
            };
            markInactiveForRun(api_state, run_id);
            return err;
        };
        watchdog_owned = false;
        watchdog_prompt_owned = false;
    }

    api_state.thread_registry.spawnRegistered(api_state.backing_allocator, worker, .{ctx}) catch |err| {
        recordRunFailureForRun(api_state, run_id, prompt_copy, @errorName(err)) catch |record_err| {
            log.warn("agent_worker_spawn_failure_record_failed run_id={d} err={s}", .{ run_id, @errorName(record_err) });
        };
        allocatorCleanup(api_state, ctx);
        context_owned = false;
        setErrorForRun(api_state, run_id, @errorName(err)) catch |set_err| {
            log.warn("agent_spawn_error_record_failed err={s}", .{@errorName(set_err)});
        };
        markInactiveForRun(api_state, run_id);
        return err;
    };
    context_owned = false;
}

/// Fails before preflight work when another run already owns the session.
///
/// This keeps repeated keypresses or stale UI state from doing filesystem and
/// provider-config work, and it preserves the user-facing error priority:
/// "already running" should not be hidden behind an unrelated `.env` problem.
fn ensureNoActiveRun(api_state: *state.ApiState) !void {
    api_state.mutex.lock();
    defer api_state.mutex.unlock();
    if (api_state.agent_run_active) return error.AgentRunInProgress;
}

/// Returns a static toast message for errors surfaced synchronously by `start`.
pub fn startErrorText(err: anyerror) []const u8 {
    return switch (err) {
        error.EmptyPrompt => "Prompt is empty.",
        error.AgentRunInProgress => "Agent is already running.",
        agent_config.Error.MissingBaseUrl => "missing CLUMSIES_AGENT_PROVIDER_BASE_URL",
        agent_config.Error.MissingApiKey => "missing CLUMSIES_AGENT_PROVIDER_API_KEY",
        agent_config.Error.MissingModel => "missing CLUMSIES_AGENT_PROVIDER_MODEL",
        agent_config.Error.InvalidTimeout => "CLUMSIES_AGENT_PROVIDER_TIMEOUT_MS must be an unsigned millisecond value",
        agent_config.Error.InvalidMaxOutputTokens => "CLUMSIES_AGENT_PROVIDER_MAX_OUTPUT_TOKENS must be an unsigned 32-bit token count",
        agent_config.Error.InvalidUseProxy => "CLUMSIES_AGENT_PROVIDER_USE_PROXY must be true or false",
        else => "Could not start agent run.",
    };
}

/// Requests that the active agent run stop at the next loop boundary.
///
/// This is cooperative cancellation. Provider HTTP requests and local tools may
/// already be blocking, so they must return or time out before the loop can
/// observe this flag and finish with `.terminated`.
pub fn requestStop(api_state: *state.ApiState) bool {
    api_state.mutex.lock();
    defer api_state.mutex.unlock();
    if (!api_state.agent_run_active) return false;
    api_state.agent_run_cancel_requested = true;
    return true;
}

/// Resolves and caches the workspace root that built-in tools can access.
///
/// The Agent tab needs to show this boundary before a run starts. The actual
/// worker resolves the root again at run time, so the displayed value is a
/// fresh idle-state hint rather than a capability token.
pub fn refreshWorkspaceRoot(api_state: *state.ApiState) !void {
    const allocator = api_state.backing_allocator;
    const tool_root = agent_workspace.resolveToolRoot(allocator) catch |err| {
        try setFormattedError(
            api_state,
            "could not resolve agent workspace root: {s}",
            .{@errorName(err)},
        );
        return err;
    };
    defer allocator.free(tool_root);
    try setRunWorkspace(api_state, tool_root);
}

/// Validates provider config before spawning the blocking worker.
///
/// Configuration failures are user-actionable and should be visible as an
/// immediate toast instead of being hidden inside an async worker. The worker
/// still reloads configuration at run time so the actual request uses the same
/// path and latest `.env` contents.
fn preflightProviderConfig(api_state: *state.ApiState) !Preflight {
    const allocator = api_state.backing_allocator;
    const tool_root = try agent_workspace.resolveToolRoot(allocator);
    errdefer allocator.free(tool_root);
    try setRunWorkspace(api_state, tool_root);

    var provider_env = agent_config.loadFromDir(allocator, tool_root) catch |err| {
        try setError(api_state, startErrorText(err));
        return err;
    };
    const model = try allocator.dupe(u8, provider_env.model);
    errdefer allocator.free(model);
    const timeout_ms = provider_env.timeout_ms;
    const use_env_proxy = provider_env.use_env_proxy;
    provider_env.deinit();
    return .{
        .tool_root = tool_root,
        .model = model,
        .timeout_ms = timeout_ms,
        .use_env_proxy = use_env_proxy,
    };
}

fn allocatorCleanup(api_state: *state.ApiState, ctx: *StartContext) void {
    api_state.backing_allocator.free(ctx.prompt);
    api_state.backing_allocator.destroy(ctx);
}

fn worker(ctx: *StartContext) void {
    const api_state = ctx.api_state;
    const allocator = api_state.backing_allocator;
    defer allocator.destroy(ctx);
    defer allocator.free(ctx.prompt);
    defer markInactiveForRun(api_state, ctx.run_id);

    log.info("agent_worker_started run_id={d}", .{ctx.run_id});
    runAgent(api_state, ctx.run_id, ctx.prompt) catch |err| {
        log.warn("agent_run_failed run_id={d} err={s}", .{ ctx.run_id, @errorName(err) });
        recordRunFailureForRun(api_state, ctx.run_id, ctx.prompt, @errorName(err)) catch |record_err| {
            log.warn("agent_run_failure_record_failed run_id={d} err={s}", .{ ctx.run_id, @errorName(record_err) });
        };
        setErrorIfEmptyForRun(api_state, ctx.run_id, @errorName(err)) catch |set_err| {
            log.warn("agent_run_error_record_failed err={s}", .{@errorName(set_err)});
        };
        return;
    };
    log.info("agent_worker_finished run_id={d}", .{ctx.run_id});
}

fn watchdog(ctx: *WatchdogContext) void {
    const api_state = ctx.api_state;
    const allocator = api_state.backing_allocator;
    defer allocator.destroy(ctx);
    defer allocator.free(ctx.prompt);

    var elapsed_ms: u64 = 0;
    while (elapsed_ms < ctx.timeout_ms) {
        const slice_ms: u64 = @min(ctx.timeout_ms - elapsed_ms, @as(u64, 250));
        std.Thread.sleep(slice_ms * @as(u64, std.time.ns_per_ms));
        elapsed_ms += slice_ms;
        if (!isRunActive(api_state, ctx.run_id)) return;
    }
    timeoutRun(api_state, ctx.run_id, ctx.timeout_ms, ctx.prompt) catch |err| {
        log.warn("agent_timeout_record_failed run_id={d} err={s}", .{ ctx.run_id, @errorName(err) });
    };
}

fn runAgent(api_state: *state.ApiState, run_id: u64, prompt: []const u8) !void {
    const allocator = api_state.backing_allocator;

    const tool_root = try agent_workspace.resolveToolRoot(allocator);
    defer allocator.free(tool_root);
    try setRunWorkspaceForRun(api_state, run_id, tool_root);
    log.info("agent_workspace_resolved run_id={d} workspace={s}", .{ run_id, tool_root });

    var provider_env = agent_config.loadFromDir(allocator, tool_root) catch |err| {
        var writer = std.Io.Writer.Allocating.init(allocator);
        defer writer.deinit();
        try agent_config.printError(&writer.writer, err);
        const message = try writer.toOwnedSlice();
        defer allocator.free(message);
        try setAndRecordErrorForRun(api_state, run_id, prompt, message);
        return err;
    };
    defer provider_env.deinit();
    try setRunProviderForRun(api_state, run_id, .{
        .model = provider_env.model,
        .timeout_ms = provider_env.timeout_ms,
        .use_env_proxy = provider_env.use_env_proxy,
    });
    log.info("agent_provider_configured run_id={d} model={s} timeout_ms={d}", .{
        run_id,
        provider_env.model,
        provider_env.timeout_ms,
    });

    var provider_state = agent.providers.OpenAICompatible.init(allocator, .{
        .base_url = provider_env.base_url,
        .api_key = provider_env.api_key,
        .model = provider_env.model,
        .auth = if (provider_env.api_key_header_name) |header| .{ .api_key = header } else .bearer,
        .request_timeout_ms = provider_env.timeout_ms,
        .use_env_proxy = provider_env.use_env_proxy,
    });
    defer provider_state.deinit();

    var builtins: agent.tools.Builtin = .{ .workspace_path = tool_root };
    var tool_runtime = builtins.runtime();
    const messages = [_]agent.transcript.Message{
        .{ .user = .{ .content = prompt } },
    };

    var sink_ctx = SinkContext{ .api_state = api_state, .run_id = run_id };
    var cancel_ctx = CancelContext{ .api_state = api_state, .run_id = run_id };
    log.info("agent_loop_enter run_id={d}", .{run_id});
    const run_result = agent.loop.run(allocator, &messages, .{
        .model_provider = provider_state.provider(),
        .tool_runtime = &tool_runtime,
        .provider_options = .{ .max_output_tokens = provider_env.max_output_tokens },
        .event_sink = sink(&sink_ctx),
        .session_entries = &.{},
        .cancel = cancelToken(&cancel_ctx),
    }) catch |err| {
        if (provider_state.takeLastError()) |provider_error| {
            defer provider_error.deinit(allocator);
            try setAndRecordFormattedErrorForRun(
                api_state,
                run_id,
                prompt,
                "provider HTTP {d}: {s}",
                .{ @intFromEnum(provider_error.status), trimProviderBody(provider_error.body) },
            );
            return err;
        }
        if (provider_state.takeLastTransportFailure()) |failure| {
            defer failure.deinit(allocator);
            try setAndRecordFormattedErrorForRun(
                api_state,
                run_id,
                prompt,
                "provider transport failed at {s}: {s}",
                .{ @tagName(failure.stage), failure.message },
            );
            return err;
        }
        try setAndRecordFormattedErrorForRun(
            api_state,
            run_id,
            prompt,
            "provider request failed: {s} (model {s}, proxy {s}, timeout {d}ms)",
            .{
                @errorName(err),
                provider_env.model,
                proxyLabel(provider_env.use_env_proxy),
                provider_env.timeout_ms,
            },
        );
        return err;
    };
    defer run_result.deinit(allocator);
    log.info("agent_loop_exit run_id={d} reason={s}", .{ run_id, @tagName(run_result.end_reason) });
}

fn cancelToken(ctx: *CancelContext) agent.loop.Cancel {
    return .{
        .ctx = ctx,
        .is_requested_fn = isCancelRequested,
    };
}

fn isCancelRequested(ctx: *anyopaque) bool {
    const cancel_ctx: *CancelContext = @ptrCast(@alignCast(ctx));
    const api_state = cancel_ctx.api_state;
    api_state.mutex.lock();
    defer api_state.mutex.unlock();
    return api_state.agent_run_id != cancel_ctx.run_id or api_state.agent_run_cancel_requested;
}

fn sink(ctx: *SinkContext) event.Sink {
    return .{
        .ctx = ctx,
        .emit_fn = emit,
    };
}

/// Emits one loop event into the shared TUI session under lock.
///
/// `event.Event` payloads are borrowed from the running loop. `Session.sink`
/// deep-clones them before the lock is released, so Agent draw code never
/// reads provider- or tool-owned temporary buffers.
fn emit(ctx: *anyopaque, new_event: event.Event) !void {
    const sink_ctx: *SinkContext = @ptrCast(@alignCast(ctx));
    const api_state = sink_ctx.api_state;
    api_state.mutex.lock();
    defer api_state.mutex.unlock();
    if (!api_state.agent_run_active or api_state.agent_run_id != sink_ctx.run_id) return;
    try api_state.agent_session.sink().emit(new_event);
}

fn markInactiveForRun(api_state: *state.ApiState, run_id: u64) void {
    api_state.mutex.lock();
    defer api_state.mutex.unlock();
    if (api_state.agent_run_id != run_id) return;
    // Cancellation belongs to the active worker. Once the worker has finished,
    // keeping the flag set would make the next idle snapshot look like it still
    // carries a pending stop request.
    api_state.agent_run_active = false;
    api_state.agent_run_cancel_requested = false;
}

fn isRunActive(api_state: *state.ApiState, run_id: u64) bool {
    api_state.mutex.lock();
    defer api_state.mutex.unlock();
    return api_state.agent_run_active and api_state.agent_run_id == run_id;
}

fn timeoutRun(api_state: *state.ApiState, run_id: u64, timeout_ms: u64, prompt: []const u8) !void {
    const message = try std.fmt.allocPrint(
        api_state.backing_allocator,
        "agent run timed out after {d} ms",
        .{timeout_ms},
    );
    defer api_state.backing_allocator.free(message);

    api_state.mutex.lock();
    defer api_state.mutex.unlock();
    if (!api_state.agent_run_active or api_state.agent_run_id != run_id) return;
    try ensureRunHasPromptLocked(api_state, prompt);
    try terminateRunIfOpenLocked(api_state, message);
    try setErrorLocked(api_state, message);
    api_state.agent_run_active = false;
    api_state.agent_run_cancel_requested = true;
    log.warn("agent_run_timeout run_id={d} timeout_ms={d}", .{ run_id, timeout_ms });
}

/// Ensures wrapper-created terminal records still belong to a visible run.
///
/// The watchdog can fire before the worker reaches `agent.loop.run`, especially
/// when provider setup or DNS blocks unexpectedly. In that case the core loop
/// has not emitted `.agent_start` or the user message yet, so the TUI would show
/// a terminated run with no prompt. Recording the prompt here keeps the session
/// history truthful without duplicating it after a normal loop start.
fn ensureRunHasPromptLocked(api_state: *state.ApiState, prompt: []const u8) !void {
    if (api_state.agent_session.trace.records.items.len == 0) {
        try api_state.agent_session.sink().emit(.agent_start);
    }
    for (api_state.agent_session.history()) |entry| {
        switch (entry) {
            .message => |message| switch (message) {
                .user => return,
                .assistant,
                .tool_result,
                => {},
            },
            .run_end => {},
        }
    }
    try api_state.agent_session.sink().emit(.{ .message_append = .{ .user = .{ .content = prompt } } });
}

/// Records a terminal event for wrapper-level failures that bypass core finish.
///
/// Provider/network/configuration errors can happen after the core has emitted
/// `.agent_start` and the user prompt but before it can emit `.agent_end`.
/// Without this wrapper terminal record the TUI projection would remain
/// `.running` even though the background worker has stopped.
fn recordRunFailureForRun(api_state: *state.ApiState, run_id: u64, prompt: []const u8, message: []const u8) !void {
    api_state.mutex.lock();
    defer api_state.mutex.unlock();
    if (api_state.agent_run_id != run_id) return;
    try ensureRunHasPromptLocked(api_state, prompt);
    try terminateRunIfOpenLocked(api_state, message);
}

fn terminateRunIfOpenLocked(api_state: *state.ApiState, message: []const u8) !void {
    for (api_state.agent_session.history()) |entry| {
        switch (entry) {
            .run_end => return,
            .message => {},
        }
    }
    try api_state.agent_session.sink().emit(.{ .run_error = .{ .message = message } });
    try api_state.agent_session.sink().emit(.{ .agent_end = .{
        .reason = .terminated,
        .message_count = api_state.agent_session.state.message_count,
    } });
}

fn setError(api_state: *state.ApiState, message: []const u8) !void {
    api_state.mutex.lock();
    defer api_state.mutex.unlock();
    try setErrorLocked(api_state, message);
}

fn setErrorForRun(api_state: *state.ApiState, run_id: u64, message: []const u8) !void {
    api_state.mutex.lock();
    defer api_state.mutex.unlock();
    if (api_state.agent_run_id != run_id) return;
    try setErrorLocked(api_state, message);
}

fn setErrorIfEmptyForRun(api_state: *state.ApiState, run_id: u64, message: []const u8) !void {
    api_state.mutex.lock();
    defer api_state.mutex.unlock();
    if (api_state.agent_run_id != run_id) return;
    if (api_state.agent_run_error != null) return;
    try setErrorLocked(api_state, message);
}

fn setFormattedError(api_state: *state.ApiState, comptime fmt: []const u8, args: anytype) !void {
    const allocator = api_state.backing_allocator;
    const message = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(message);
    try setError(api_state, message);
}

/// Records a terminal diagnostic in both the live error slot and run trace.
///
/// The live slot powers the composer/status toast, while `.run_error` in trace
/// preserves the same actionable message with the historical run. Worker catch
/// paths may later see only a coarse Zig error name, so provider/config failure
/// sites call this helper while the specific diagnostic body is still in scope.
fn setAndRecordErrorForRun(api_state: *state.ApiState, run_id: u64, prompt: []const u8, message: []const u8) !void {
    try setErrorForRun(api_state, run_id, message);
    try recordRunFailureForRun(api_state, run_id, prompt, message);
}

fn setAndRecordFormattedErrorForRun(
    api_state: *state.ApiState,
    run_id: u64,
    prompt: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const allocator = api_state.backing_allocator;
    const message = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(message);
    try setAndRecordErrorForRun(api_state, run_id, prompt, message);
}

fn setErrorLocked(api_state: *state.ApiState, message: []const u8) !void {
    if (api_state.agent_run_error) |old| {
        api_state.backing_allocator.free(old);
        api_state.agent_run_error = null;
    }
    api_state.agent_run_error = try api_state.backing_allocator.dupe(u8, message);
}

fn setRunWorkspace(api_state: *state.ApiState, path: []const u8) !void {
    const owned = try api_state.backing_allocator.dupe(u8, path);
    api_state.mutex.lock();
    defer api_state.mutex.unlock();
    if (api_state.agent_workspace_root) |old| api_state.backing_allocator.free(old);
    api_state.agent_workspace_root = owned;
}

fn setRunWorkspaceForRun(api_state: *state.ApiState, run_id: u64, path: []const u8) !void {
    const owned = try api_state.backing_allocator.dupe(u8, path);
    api_state.mutex.lock();
    defer api_state.mutex.unlock();
    if (api_state.agent_run_id != run_id) {
        api_state.backing_allocator.free(owned);
        return;
    }
    if (api_state.agent_workspace_root) |old| api_state.backing_allocator.free(old);
    api_state.agent_workspace_root = owned;
}

const ProviderDisplay = struct {
    model: []const u8,
    timeout_ms: u64,
    use_env_proxy: bool,
};

fn setRunProviderForRun(api_state: *state.ApiState, run_id: u64, provider: ProviderDisplay) !void {
    const owned = try api_state.backing_allocator.dupe(u8, provider.model);
    api_state.mutex.lock();
    defer api_state.mutex.unlock();
    if (api_state.agent_run_id != run_id) {
        api_state.backing_allocator.free(owned);
        return;
    }
    if (api_state.agent_provider_model) |old| api_state.backing_allocator.free(old);
    api_state.agent_provider_model = owned;
    api_state.agent_provider_timeout_ms = provider.timeout_ms;
    api_state.agent_provider_use_proxy = provider.use_env_proxy;
}

fn clearProviderMetadataLocked(api_state: *state.ApiState) void {
    if (api_state.agent_provider_model) |model_name| {
        api_state.backing_allocator.free(model_name);
        api_state.agent_provider_model = null;
    }
    api_state.agent_provider_timeout_ms = null;
    api_state.agent_provider_use_proxy = null;
}

fn proxyLabel(use_env_proxy: bool) []const u8 {
    return if (use_env_proxy) "auto" else "off";
}

fn trimProviderBody(body: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (!std.unicode.utf8ValidateSlice(trimmed)) return "non-UTF-8 provider error body";
    return truncateUtf8Boundary(trimmed, 1024);
}

/// Keeps provider diagnostics bounded without corrupting UTF-8 output.
///
/// Error bodies are rendered in the Agent tab. Providers may return localized
/// messages, so truncating the raw byte stream must still preserve codepoint
/// boundaries before the text reaches the TUI renderer.
fn truncateUtf8Boundary(text: []const u8, max_bytes: usize) []const u8 {
    var end = @min(text.len, max_bytes);
    if (end == text.len) return text;
    while (end > 0 and (text[end] & 0xc0) == 0x80) : (end -= 1) {}
    return text[0..end];
}

test "requestStop only marks an active agent run" {
    var api_state = state.ApiState.init(std.testing.allocator);
    defer api_state.deinit();
    api_state.bindAllocator();

    try std.testing.expect(!requestStop(&api_state));

    api_state.mutex.lock();
    api_state.agent_run_active = true;
    api_state.mutex.unlock();

    try std.testing.expect(requestStop(&api_state));
    api_state.mutex.lock();
    defer api_state.mutex.unlock();
    try std.testing.expect(api_state.agent_run_cancel_requested);
}

test "ensureNoActiveRun preserves already-running error priority" {
    var api_state = state.ApiState.init(std.testing.allocator);
    defer api_state.deinit();
    api_state.bindAllocator();

    try ensureNoActiveRun(&api_state);

    api_state.mutex.lock();
    api_state.agent_run_active = true;
    api_state.mutex.unlock();

    try std.testing.expectError(error.AgentRunInProgress, ensureNoActiveRun(&api_state));
}

test "startErrorText names missing provider keys for toasts" {
    try std.testing.expectEqualStrings(
        "missing CLUMSIES_AGENT_PROVIDER_BASE_URL",
        startErrorText(agent_config.Error.MissingBaseUrl),
    );
    try std.testing.expectEqualStrings(
        "CLUMSIES_AGENT_PROVIDER_TIMEOUT_MS must be an unsigned millisecond value",
        startErrorText(agent_config.Error.InvalidTimeout),
    );
    try std.testing.expectEqualStrings(
        "CLUMSIES_AGENT_PROVIDER_USE_PROXY must be true or false",
        startErrorText(agent_config.Error.InvalidUseProxy),
    );
}

test "setError replaces the previous owned TUI error" {
    var api_state = state.ApiState.init(std.testing.allocator);
    defer api_state.deinit();
    api_state.bindAllocator();

    try setError(&api_state, "first");
    try setError(&api_state, "second");

    api_state.mutex.lock();
    defer api_state.mutex.unlock();
    try std.testing.expectEqualStrings("second", api_state.agent_run_error.?);
}

test "markInactive clears run and cancellation flags together" {
    var api_state = state.ApiState.init(std.testing.allocator);
    defer api_state.deinit();
    api_state.bindAllocator();

    api_state.mutex.lock();
    api_state.agent_run_active = true;
    api_state.agent_run_id = 7;
    api_state.agent_run_cancel_requested = true;
    api_state.mutex.unlock();

    markInactiveForRun(&api_state, 7);

    api_state.mutex.lock();
    defer api_state.mutex.unlock();
    try std.testing.expect(!api_state.agent_run_active);
    try std.testing.expect(!api_state.agent_run_cancel_requested);
}

test "markInactive ignores stale worker completions" {
    var api_state = state.ApiState.init(std.testing.allocator);
    defer api_state.deinit();
    api_state.bindAllocator();

    api_state.mutex.lock();
    api_state.agent_run_active = true;
    api_state.agent_run_id = 8;
    api_state.mutex.unlock();

    markInactiveForRun(&api_state, 7);

    api_state.mutex.lock();
    defer api_state.mutex.unlock();
    try std.testing.expect(api_state.agent_run_active);
}

test "timeoutRun terminates only the matching active run" {
    var api_state = state.ApiState.init(std.testing.allocator);
    defer api_state.deinit();
    api_state.bindAllocator();

    api_state.mutex.lock();
    api_state.agent_run_active = true;
    api_state.agent_run_id = 9;
    try api_state.agent_session.sink().emit(.agent_start);
    api_state.mutex.unlock();

    try timeoutRun(&api_state, 8, 10, "fix timeout");

    api_state.mutex.lock();
    try std.testing.expect(api_state.agent_run_active);
    api_state.mutex.unlock();

    try timeoutRun(&api_state, 9, 10, "fix timeout");

    api_state.mutex.lock();
    defer api_state.mutex.unlock();
    try std.testing.expect(!api_state.agent_run_active);
    try std.testing.expect(api_state.agent_run_cancel_requested);
    try std.testing.expectEqualStrings("agent run timed out after 10 ms", api_state.agent_run_error.?);
    const history = api_state.agent_session.currentRun().?.history();
    try std.testing.expectEqualStrings("fix timeout", history[0].message.user.content);
    try std.testing.expectEqual(agent.transcript.EndReason.terminated, history[1].run_end);
}

test "timeoutRun records prompt when worker has not entered the loop" {
    var api_state = state.ApiState.init(std.testing.allocator);
    defer api_state.deinit();
    api_state.bindAllocator();

    api_state.mutex.lock();
    api_state.agent_run_active = true;
    api_state.agent_run_id = 10;
    api_state.mutex.unlock();

    try timeoutRun(&api_state, 10, 10, "explain provider hang");

    api_state.mutex.lock();
    defer api_state.mutex.unlock();
    const history = api_state.agent_session.currentRun().?.history();
    try std.testing.expectEqual(@as(usize, 2), history.len);
    try std.testing.expectEqualStrings("explain provider hang", history[0].message.user.content);
    try std.testing.expectEqual(agent.transcript.EndReason.terminated, history[1].run_end);
}

test "recordRunFailureForRun terminates a provider-failed visible run" {
    var api_state = state.ApiState.init(std.testing.allocator);
    defer api_state.deinit();
    api_state.bindAllocator();

    api_state.mutex.lock();
    api_state.agent_run_active = true;
    api_state.agent_run_id = 11;
    try api_state.agent_session.sink().emit(.agent_start);
    try api_state.agent_session.sink().emit(.{ .message_append = .{ .user = .{ .content = "why did provider fail?" } } });
    api_state.mutex.unlock();

    try recordRunFailureForRun(&api_state, 11, "why did provider fail?", "provider HTTP 401: bad key");

    api_state.mutex.lock();
    defer api_state.mutex.unlock();
    const history = api_state.agent_session.currentRun().?.history();
    try std.testing.expectEqual(@as(usize, 2), history.len);
    try std.testing.expectEqualStrings("why did provider fail?", history[0].message.user.content);
    try std.testing.expectEqual(agent.transcript.EndReason.terminated, history[1].run_end);
    const records = api_state.agent_session.currentRun().?.trace.records.items;
    try std.testing.expectEqualStrings("provider HTTP 401: bad key", records[2].run_error.message);
    try std.testing.expectEqual(agent.Session.Status{ .ended = .terminated }, api_state.agent_session.state.status);
}

test "recordRunFailureForRun creates a visible run before loop entry" {
    var api_state = state.ApiState.init(std.testing.allocator);
    defer api_state.deinit();
    api_state.bindAllocator();

    api_state.mutex.lock();
    api_state.agent_run_active = true;
    api_state.agent_run_id = 12;
    api_state.mutex.unlock();

    try recordRunFailureForRun(&api_state, 12, "provider config changed", "missing CLUMSIES_AGENT_PROVIDER_BASE_URL");

    api_state.mutex.lock();
    defer api_state.mutex.unlock();
    const history = api_state.agent_session.currentRun().?.history();
    try std.testing.expectEqual(@as(usize, 2), history.len);
    try std.testing.expectEqualStrings("provider config changed", history[0].message.user.content);
    try std.testing.expectEqual(agent.transcript.EndReason.terminated, history[1].run_end);
    const records = api_state.agent_session.currentRun().?.trace.records.items;
    try std.testing.expectEqualStrings("missing CLUMSIES_AGENT_PROVIDER_BASE_URL", records[2].run_error.message);
}

test "setAndRecordErrorForRun preserves the specific run diagnostic" {
    var api_state = state.ApiState.init(std.testing.allocator);
    defer api_state.deinit();
    api_state.bindAllocator();

    api_state.mutex.lock();
    api_state.agent_run_active = true;
    api_state.agent_run_id = 13;
    api_state.mutex.unlock();

    try setAndRecordErrorForRun(
        &api_state,
        13,
        "call provider",
        "provider HTTP 401: invalid API key",
    );
    try setErrorIfEmptyForRun(&api_state, 13, "ProviderRequestFailed");
    try recordRunFailureForRun(&api_state, 13, "call provider", "ProviderRequestFailed");

    api_state.mutex.lock();
    defer api_state.mutex.unlock();
    try std.testing.expectEqualStrings("provider HTTP 401: invalid API key", api_state.agent_run_error.?);
    const records = api_state.agent_session.currentRun().?.trace.records.items;
    try std.testing.expectEqualStrings("provider HTTP 401: invalid API key", records[2].run_error.message);
    try std.testing.expectEqual(agent.transcript.EndReason.terminated, records[3].agent_end.reason);
}

test "trimProviderBody bounds diagnostics on UTF-8 boundaries" {
    try std.testing.expectEqualStrings("评价", trimProviderBody(" \n评价\t"));

    const prefix = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const body = prefix ** 16 ++ "评";
    try std.testing.expectEqual(@as(usize, 1024), trimProviderBody(body).len);

    const split_body = prefix ** 15 ++ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++ "评价";
    try std.testing.expectEqualStrings(prefix ** 15 ++ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", trimProviderBody(split_body));
}
