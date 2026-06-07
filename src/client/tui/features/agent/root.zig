//! Coding-agent feature container.
//!
//! This tab is the first interactive surface for the agent core. It treats a
//! session as a container of runs: the left panel renders the current/latest
//! run, and the right panel lists runs in that session.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../../theme.zig");
const w = @import("../../widgets.zig");
const agent_runner = @import("../../runtime/agent_runner.zig");
const agent = @import("clumsies_lib").agent;

pub const State = struct {
    prompt_buf: [4096]u8 = .{0} ** 4096,
    prompt_len: usize = 0,
    prompt_active: bool = false,
    focus: Focus = .run,
    selected_run_index: ?usize = null,

    pub fn init() State {
        return .{};
    }
};

pub const Focus = enum {
    run,
    runs,
};

/// Renders the agent tab as composer + current run + run list.
///
/// The shell owns the concrete `State`; this feature only owns the tab-specific
/// layout and reads the shared `ApiState.agent_session` under the API mutex.
pub fn drawRoot(self: anytype, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    var root = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    w.fillSurface(&root, theme.CANVAS);

    const composer_h: u16 = 3;
    const body_h = size.height -| composer_h;
    const runs_w: u16 = @min(size.width, @max(@as(u16, 30), size.width / 4));
    const run_w = size.width -| runs_w;
    const children = try ctx.arena.alloc(vxfw.SubSurface, 3);
    children[0] = .{
        .origin = .{ .row = 0, .col = 0 },
        .surface = try drawComposer(self, ctx.withConstraints(
            .{ .width = size.width, .height = composer_h },
            .{ .width = size.width, .height = composer_h },
        )),
    };
    children[1] = .{
        .origin = .{ .row = composer_h, .col = 0 },
        .surface = try drawCurrentRun(self, ctx.withConstraints(
            .{ .width = run_w, .height = body_h },
            .{ .width = run_w, .height = body_h },
        )),
    };
    children[2] = .{
        .origin = .{ .row = composer_h, .col = run_w },
        .surface = try drawRuns(self, ctx.withConstraints(
            .{ .width = runs_w, .height = body_h },
            .{ .width = runs_w, .height = body_h },
        )),
    };
    root.children = children;
    return root;
}

/// Handles prompt input for the agent tab and starts one background run.
///
/// A run is delegated to `agent_runner` so the Vaxis event loop never blocks on
/// provider HTTP or tool execution. The runner emits events back into
/// `ApiState.agent_session`, which this tab renders on later ticks.
pub fn handleModuleEvent(
    self: anytype,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
) anyerror!void {
    const is_running = agentRunActive(self);
    if (self.agent.prompt_active) {
        if (is_running) {
            if (key.matches(vaxis.Key.escape, .{})) {
                self.agent.prompt_active = false;
                ctx.consumeAndRedraw();
            } else {
                ctx.consumeEvent();
            }
            return;
        }

        var input = w.TextInput{
            .buf = &self.agent.prompt_buf,
            .len = &self.agent.prompt_len,
            .bg = theme.PANEL_ALT,
        };
        switch (input.handleKey(key)) {
            .submit => {
                const prompt = std.mem.trim(u8, self.agent.prompt_buf[0..self.agent.prompt_len], " \t\r\n");
                agent_runner.start(self.api_state, prompt) catch |err| {
                    self.notifyOp(.failure, agent_runner.startErrorText(err));
                    ctx.consumeAndRedraw();
                    return;
                };
                self.agent.selected_run_index = null;
                input.clear();
                self.agent.prompt_active = false;
                self.agent.focus = .run;
                ctx.consumeAndRedraw();
                return;
            },
            .cancel => {
                self.agent.prompt_active = false;
                self.agent.focus = .run;
                ctx.consumeAndRedraw();
                return;
            },
            .consumed => {
                ctx.consumeAndRedraw();
                return;
            },
            .ignored => {},
        }
    }
    if (isFocusKey(key)) |delta| {
        moveFocus(self, delta);
        ctx.consumeAndRedraw();
        return;
    }
    if (is_running and isStopKey(key)) {
        if (agent_runner.requestStop(self.api_state)) {
            self.notifyOp(.warning, "Stopping agent run...");
        }
        ctx.consumeAndRedraw();
        return;
    }
    if (!is_running and self.agent.focus == .runs) {
        if (isRunListKey(key)) |delta| {
            if (selectRun(self, delta)) {
                ctx.consumeAndRedraw();
            } else {
                ctx.consumeEvent();
            }
            return;
        }
    }
    if (!is_running and key.matches(vaxis.Key.escape, .{}) and self.agent.selected_run_index != null) {
        self.agent.selected_run_index = null;
        self.agent.focus = .run;
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('i', .{}) or key.matches(vaxis.Key.enter, .{})) {
        if (is_running) {
            self.notifyOp(.warning, "Agent is already running.");
            ctx.consumeAndRedraw();
            return;
        }
        self.agent.prompt_active = true;
        ctx.consumeAndRedraw();
        return;
    }
}

/// Returns footer shortcuts for the agent tab's two interaction modes.
pub fn shortcuts(self: anytype) []const w.Shortcut {
    if (agentRunActive(self)) return &.{
        .{ .key = "Esc", .label = "stop" },
        .{ .key = "Tab", .label = "focus" },
        .{ .key = "?", .label = "help" },
        .{ .key = "q", .label = "quit" },
    };
    if (self.agent.prompt_active) return &.{
        .{ .key = "Enter", .label = "run" },
        .{ .key = "Esc", .label = "blur" },
        .{ .key = "Ctrl+C", .label = "quit" },
    };
    return &.{
        .{ .key = "i", .label = "prompt" },
        .{ .key = "Enter", .label = "prompt" },
        .{ .key = "Tab", .label = "focus" },
        .{ .key = "↑/↓", .label = "runs" },
        .{ .key = "?", .label = "help" },
        .{ .key = "q", .label = "quit" },
    };
}

/// Reads whether a background run is active without exposing the shared mutex.
fn agentRunActive(self: anytype) bool {
    self.api_state.mutex.lock();
    defer self.api_state.mutex.unlock();
    return self.api_state.agent_run_active;
}

fn isStopKey(key: vaxis.Key) bool {
    return key.matches(vaxis.Key.escape, .{});
}

fn isRunListKey(key: vaxis.Key) ?isize {
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) return 1;
    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) return -1;
    return null;
}

fn isFocusKey(key: vaxis.Key) ?isize {
    if (key.matches(vaxis.Key.tab, .{}) or key.matches(vaxis.Key.right, .{})) return 1;
    if (key.matches(vaxis.Key.left, .{})) return -1;
    return null;
}

fn moveFocus(self: anytype, delta: isize) void {
    const next = movedFocus(self.agent.focus, delta);
    self.agent.focus = next;
}

fn movedFocus(focus: Focus, delta: isize) Focus {
    const index: isize = switch (focus) {
        .run => 0,
        .runs => 1,
    };
    const next = @mod(index + delta, 2);
    return switch (next) {
        0 => .run,
        else => .runs,
    };
}

/// Moves the selected run in the right-hand session run list.
///
/// The Agent tab defaults to a live view of the latest run. Once a completed
/// run is selected, the left panel renders that run's owned trace until the
/// user clears selection or starts another run.
fn selectRun(self: anytype, delta: isize) bool {
    self.api_state.mutex.lock();
    defer self.api_state.mutex.unlock();

    const runs = self.api_state.agent_session.runsView();
    const current_index = if (self.api_state.agent_session.currentRun()) |current| current.index else null;
    const next = movedRunSelection(runs.len, self.agent.selected_run_index, current_index, delta) orelse return false;
    self.agent.selected_run_index = next;
    return true;
}

fn drawComposer(self: anytype, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, theme.focusBorder(self.agent.prompt_active), theme.PANEL);
    w.writeText(&surface, ctx, 2, 0, "Agent", theme.boldOn(theme.PANEL, theme.TEXT));

    const is_running = blk: {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        const running = self.api_state.agent_run_active;
        const stopping = running and self.api_state.agent_run_cancel_requested;
        const boundary = if (self.api_state.agent_run_error) |message|
            firstLineTrimmed(message, surface.size.width -| 12)
        else
            sessionHeaderLine(ctx.arena, .{
                .workspace_root = self.api_state.agent_workspace_root,
                .model = self.api_state.agent_provider_model,
            }, surface.size.width -| 12) catch "model unknown · ~ · Main [default]";
        const hint = if (stopping) "◒" else if (running) "●" else if (self.agent.prompt_active) "Enter" else "i";
        const header = composerHeader(ctx.arena, hint, boundary, surface.size.width -| 4) catch hint;
        w.writeRightText(&surface, ctx, 0, header, theme.fg(if (self.api_state.agent_run_error != null) theme.DANGER else if (running) theme.ACCENT_SOFT else theme.MUTED));
        break :blk running;
    };

    var input = w.TextInput{
        .buf = &self.agent.prompt_buf,
        .len = &self.agent.prompt_len,
        .bg = theme.PANEL_ALT,
    };
    input.drawOnSurface(&surface, ctx, 2, 1, surface.size.width -| 4);
    if (!self.agent.prompt_active or is_running) surface.cursor = null;
    return surface;
}

/// Draws the current/latest run as a coding-agent execution stream.
///
/// This panel follows the common coding-agent TUI shape: user message,
/// assistant response, tool execution, and tool result all appear in one
/// chronological stream. Metadata stays out of this panel because it competes
/// with the working conversation.
fn drawCurrentRun(self: anytype, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, theme.focusBorder(self.agent.focus == .run), theme.PANEL);
    w.writeText(&surface, ctx, 2, 0, "Run", theme.boldOn(theme.PANEL, theme.TEXT));

    self.api_state.mutex.lock();
    defer self.api_state.mutex.unlock();
    const runs = self.api_state.agent_session.runsView();
    const current_index = if (self.api_state.agent_session.currentRun()) |current| current.index else null;
    const selected_index = resolvedRunSelection(runs.len, self.agent.selected_run_index, current_index);
    const is_live_view = selected_index == null or (current_index != null and selected_index.? == current_index.?);
    const state = if (selected_index) |index| &runs[index].state else &self.api_state.agent_session.state;
    const records = if (selected_index) |index|
        runs[index].trace.records.items
    else
        self.api_state.agent_session.trace.records.items;
    const has_run_error = traceHasRunError(records);
    w.writeRightText(&surface, ctx, 0, statusGlyphLabel(
        state.status,
        is_live_view and self.api_state.agent_run_active,
        is_live_view and self.api_state.agent_run_cancel_requested,
        has_run_error or (is_live_view and self.api_state.agent_run_error != null),
    ), theme.fg(theme.ACCENT_SOFT));
    if (is_live_view) {
        if (self.api_state.agent_run_error) |message| {
            w.writeText(&surface, ctx, 2, 1, firstLineTrimmed(message, surface.size.width -| 4), theme.fg(theme.DANGER));
        }
    }

    if (records.len == 0) {
        const text = if (is_live_view and self.api_state.agent_run_active)
            "◌ starting"
        else
            "No runs yet.";
        w.writeText(&surface, ctx, 2, 2, text, theme.fg(theme.MUTED));
        return surface;
    }

    const first_entry_row: u16 = if (is_live_view and self.api_state.agent_run_error != null) 2 else 1;
    const body_rows = visibleRowsFrom(surface.size.height, first_entry_row);
    const show_provider_pending = shouldShowProviderPending(is_live_view and self.api_state.agent_run_active, records);
    const start_index = runStreamTailStartIndex(records, body_rows, show_provider_pending);
    var row: u16 = first_entry_row;
    if (start_index > 0) {
        const hidden = try std.fmt.allocPrint(ctx.arena, "{d} earlier events hidden", .{start_index});
        w.writeText(&surface, ctx, 2, row, firstLineTrimmed(hidden, surface.size.width -| 4), theme.fg(theme.MUTED));
        row += 1;
    }

    var visible_index: usize = 0;
    for (records) |record| {
        if (!isVisibleRunRecord(record)) continue;
        if (visible_index < start_index) {
            visible_index += 1;
            continue;
        }
        if (row >= surface.size.height -| 1) break;
        const line = try traceLine(ctx.arena, record);
        const color = traceColor(record);
        row = drawTraceLine(&surface, ctx, row, line, color);
        visible_index += 1;
    }
    if (row < surface.size.height -| 1 and show_provider_pending) {
        w.writeText(&surface, ctx, 2, row, "◒ provider", theme.fg(theme.MUTED));
    }
    return surface;
}

/// Draws the run list for the current session.
///
/// Session switching belongs to the future drawer-level navigation. This panel
/// stays inside the current session and treats each user prompt as the anchor
/// for one agent-loop run, making old prompts easy to reopen while a new run is
/// active.
fn drawRuns(self: anytype, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, theme.focusBorder(self.agent.focus == .runs), theme.PANEL);
    w.writeText(&surface, ctx, 2, 0, "Session", theme.boldOn(theme.PANEL, theme.TEXT));

    self.api_state.mutex.lock();
    defer self.api_state.mutex.unlock();
    const runs = self.api_state.agent_session.runsView();
    if (runs.len == 0) {
        w.writeText(&surface, ctx, 2, 2, "No prompts yet.", theme.fg(theme.MUTED));
        return surface;
    }

    const visible_rows = visibleRowsFrom(surface.size.height, 1);
    const start_index = tailStartIndex(runs.len, visible_rows);
    const current_index = if (self.api_state.agent_session.currentRun()) |current| current.index else null;
    const selected_index = resolvedRunSelection(runs.len, self.agent.selected_run_index, current_index);
    var row: u16 = 1;
    for (runs[start_index..]) |*run| {
        if (row >= surface.size.height -| 1) break;
        const is_selected = if (selected_index) |index| index == run.index else false;
        const marker: []const u8 = if (is_selected) ">" else " ";
        const line = try runListLine(ctx.arena, marker, run);
        w.writeText(&surface, ctx, 2, row, firstLineTrimmed(line, surface.size.width -| 4), .{
            .fg = if (is_selected) theme.ACCENT_SOFT else theme.TEXT,
            .bg = theme.PANEL,
        });
        row += 1;
    }
    return surface;
}

/// Resolves the run that the left panel should display.
///
/// A missing selection means "follow the latest/current run." Invalid stale
/// selections also fall back to the current run so clearing session state does
/// not leave the UI pointing outside the run list.
fn resolvedRunSelection(runs_len: usize, selected_index: ?usize, current_index: ?usize) ?usize {
    if (selected_index) |index| {
        if (index < runs_len) return index;
    }
    if (current_index) |index| {
        if (index < runs_len) return index;
    }
    return null;
}

fn movedRunSelection(runs_len: usize, selected_index: ?usize, current_index: ?usize, delta: isize) ?usize {
    if (runs_len == 0) return null;
    const start = resolvedRunSelection(runs_len, selected_index, current_index) orelse runs_len - 1;
    if (delta < 0) {
        const magnitude: usize = @intCast(-delta);
        return start -| magnitude;
    }
    const magnitude: usize = @intCast(delta);
    return @min(runs_len - 1, start + magnitude);
}

fn endReasonLabel(reason: agent.transcript.EndReason) []const u8 {
    return switch (reason) {
        .complete => "complete",
        .terminated => "terminated",
        .max_turns => "max turns",
    };
}

fn statusGlyphLabel(status: agent.Session.Status, active: bool, cancel_requested: bool, has_error: bool) []const u8 {
    if (active and cancel_requested) return "◒ stopping";
    if (active) return "● running";
    if (has_error) return "× error";
    return switch (status) {
        .idle => "○ idle",
        .running => "● running",
        .ended => |reason| switch (reason) {
            .complete => "✓ complete",
            .terminated => "■ stopped",
            .max_turns => "… max",
        },
    };
}

fn runListLine(arena: std.mem.Allocator, marker: []const u8, run: *const agent.Session.Run) std.mem.Allocator.Error![]const u8 {
    const prompt = runPrompt(run) orelse "(no prompt)";
    return std.fmt.allocPrint(
        arena,
        "{s} {s} {s}",
        .{
            marker,
            runGlyph(run.state.status, traceHasRunError(run.trace.records.items)),
            prompt,
        },
    );
}

fn runGlyph(status: agent.Session.Status, has_error: bool) []const u8 {
    if (has_error) return "×";
    return switch (status) {
        .idle => "○",
        .running => "●",
        .ended => |reason| switch (reason) {
            .complete => "✓",
            .terminated => "■",
            .max_turns => "…",
        },
    };
}

fn runPrompt(run: *const agent.Session.Run) ?[]const u8 {
    for (run.history()) |entry| {
        switch (entry) {
            .message => |message| switch (message) {
                .user => |value| return value.content,
                .assistant,
                .tool_result,
                => {},
            },
            .run_end => {},
        }
    }
    return null;
}

/// Formats model, workspace, and session boundaries outside the run stream.
///
/// The current run panel should stay focused on causal agent events. Workspace
/// scope is still critical safety context, so the composer shows it as ambient
/// status before a prompt is submitted and while a run is active.
const HeaderContext = struct {
    workspace_root: ?[]const u8,
    model: ?[]const u8,
};

/// Builds the composer border metadata shown on the right side.
///
/// Workspace and provider state are execution boundaries, not prompt content.
/// Keeping them in the border preserves the prompt panel's interior for user
/// input while still making the active runtime scope visible before a run.
fn composerHeader(arena: std.mem.Allocator, hint: []const u8, boundary: []const u8, max_cells: u16) std.mem.Allocator.Error![]const u8 {
    const max: usize = max_cells;
    if (max <= hint.len + 3) return arena.dupe(u8, hint);
    const boundary_budget: u16 = @intCast(@min(boundary.len, max - hint.len - 3));
    return std.fmt.allocPrint(arena, "{s} · {s}", .{
        firstLineTrimmed(boundary, boundary_budget),
        hint,
    });
}

fn sessionHeaderLine(arena: std.mem.Allocator, context: HeaderContext, max_cells: u16) std.mem.Allocator.Error![]const u8 {
    const model = context.model orelse "model unknown";
    const root = context.workspace_root orelse "~";
    const workspace = try compactHomePath(arena, root);
    defer arena.free(workspace);
    const budget = @max(@as(u16, 12), max_cells / 2);
    return std.fmt.allocPrint(arena, "{s} · {s} · Main [default]", .{
        firstLineTrimmed(model, max_cells -| budget -| 18),
        firstLineTrimmed(workspace, budget),
    });
}

fn compactHomePath(arena: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error![]const u8 {
    const home = std.posix.getenv("HOME") orelse return arena.dupe(u8, path);
    if (std.mem.eql(u8, path, home)) return arena.dupe(u8, "~");
    if (std.mem.startsWith(u8, path, home) and path.len > home.len and path[home.len] == '/') {
        return std.fmt.allocPrint(arena, "~{s}", .{path[home.len..]});
    }
    return arena.dupe(u8, path);
}

/// Counts trace records that belong in the user-facing run stream.
///
/// The trace still keeps internal loop boundaries for observability, but the
/// Agent tab should read like a coding-agent conversation rather than an event
/// debugger. Tool-result transcript messages are intentionally hidden here
/// because `tool_end` already renders the same execution result; the transcript
/// entry remains in trace/session for provider replay.
fn displayRecordCount(records: []const agent.Trace.Record) usize {
    var count: usize = 0;
    for (records) |record| {
        if (isVisibleRunRecord(record)) count += 1;
    }
    return count;
}

/// Returns whether a run trace contains a wrapper-level terminal diagnostic.
///
/// Core `.agent_end(.terminated)` can mean cancellation, a stop requested by a
/// tool, or a provider/runtime failure. The TUI needs this trace-level signal
/// to label historical failed runs as errors without changing core end reasons.
fn traceHasRunError(records: []const agent.Trace.Record) bool {
    for (records) |record| {
        switch (record) {
            .run_error => return true,
            else => {},
        }
    }
    return false;
}

/// Chooses the first visible run event by estimated rendered row cost.
///
/// The live run panel renders each event as a bounded wrapped block, so plain
/// event counts are not enough for tailing. This helper estimates the same row
/// budget used by `drawTraceLine`, keeping the newest assistant/tool output
/// visible even when earlier events contain multi-line JSON or long text.
fn runStreamTailStartIndex(
    records: []const agent.Trace.Record,
    visible_rows: usize,
    show_provider_pending: bool,
) usize {
    if (visible_rows == 0) return displayRecordCount(records);

    var visible_count: usize = 0;
    for (records) |record| {
        if (isVisibleRunRecord(record)) visible_count += 1;
    }

    var used_rows: usize = if (show_provider_pending) 1 else 0;
    var keep_count: usize = 0;
    var reverse_index = records.len;
    while (reverse_index > 0) {
        reverse_index -= 1;
        const record = records[reverse_index];
        if (!isVisibleRunRecord(record)) continue;
        const cost = estimatedTraceRows(record);
        if (keep_count > 0 and used_rows + cost > visible_rows) break;
        if (keep_count == 0 and used_rows + cost > visible_rows) {
            keep_count = 1;
            break;
        }
        used_rows += cost;
        keep_count += 1;
    }
    return visible_count - keep_count;
}

fn estimatedTraceRows(record: agent.Trace.Record) usize {
    return switch (record) {
        .tool_end => |value| if (std.mem.indexOfScalar(u8, value.result.content, '\n') != null) 4 else 3,
        .message_append => |message| switch (message) {
            .user => |value| if (std.mem.indexOfScalar(u8, value.content, '\n') != null) 4 else 3,
            .assistant => |value| if (std.mem.indexOfScalar(u8, value.content, '\n') != null) 4 else 3,
            .tool_result => 0,
        },
        .tool_start,
        .run_error,
        .agent_end,
        => 3,
        .agent_start,
        .turn_start,
        .turn_end,
        => 0,
    };
}

fn isVisibleRunRecord(record: agent.Trace.Record) bool {
    return switch (record) {
        .message_append => |message| switch (message) {
            .user,
            .assistant,
            => true,
            .tool_result => false,
        },
        .tool_start,
        .tool_end,
        .run_error,
        .agent_end,
        => true,
        .agent_start,
        .turn_start,
        .turn_end,
        => false,
    };
}

fn traceLine(arena: std.mem.Allocator, record: agent.Trace.Record) std.mem.Allocator.Error![]const u8 {
    return switch (record) {
        .agent_start => std.fmt.allocPrint(arena, "○ start", .{}),
        .turn_start => |value| std.fmt.allocPrint(arena, "◌ turn {d}", .{value.turn_index + 1}),
        .message_append => |message| messageAppendLine(arena, message),
        .tool_start => |call| std.fmt.allocPrint(arena, "◦ {s} {s}", .{ call.name, call.arguments }),
        .tool_end => |value| std.fmt.allocPrint(arena, "{s} {s} {s}", .{
            if (value.result.is_error) "×" else "✓",
            value.call.name,
            value.result.content,
        }),
        .turn_end => |value| std.fmt.allocPrint(arena, "◌ turn {d}", .{value.turn_index + 1}),
        .run_error => |value| std.fmt.allocPrint(arena, "× {s}", .{value.message}),
        .agent_end => |value| std.fmt.allocPrint(arena, "{s}", .{endReasonGlyphLabel(value.reason)}),
    };
}

fn messageAppendLine(arena: std.mem.Allocator, message: agent.Trace.MessageAppend) std.mem.Allocator.Error![]const u8 {
    return switch (message) {
        .user => |value| std.fmt.allocPrint(arena, "› {s}", .{value.content}),
        .assistant => |value| if (value.content.len > 0)
            std.fmt.allocPrint(arena, "· {s}", .{value.content})
        else
            std.fmt.allocPrint(arena, "◦ {d} tool call(s)", .{value.tool_calls.len}),
        .tool_result => |value| std.fmt.allocPrint(arena, "{s} {s}", .{ if (value.is_error) "×" else "✓", value.content }),
    };
}

fn endReasonGlyphLabel(reason: agent.transcript.EndReason) []const u8 {
    return switch (reason) {
        .complete => "✓ complete",
        .terminated => "■ stopped",
        .max_turns => "… max turns",
    };
}

fn traceColor(record: agent.Trace.Record) vaxis.Color {
    return switch (record) {
        .agent_start,
        .turn_start,
        .turn_end,
        .agent_end,
        => theme.MUTED,
        .run_error => theme.DANGER,
        .message_append => |message| switch (message) {
            .user => theme.ACCENT_SOFT,
            .assistant => theme.TEXT,
            .tool_result => |value| if (value.is_error) theme.DANGER else theme.TEXT_SOFT,
        },
        .tool_start => theme.ACCENT_SOFT,
        .tool_end => |value| if (value.result.is_error) theme.DANGER else theme.OK,
    };
}

/// Renders one visible run event as a bounded multi-line block.
///
/// Provider and tool outputs often contain newlines or long JSON. The run
/// stream should show enough of that content to be useful while still keeping
/// the newest events visible in a live, non-scrollable panel.
fn drawTraceLine(
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    row: u16,
    text: []const u8,
    color: vaxis.Color,
) u16 {
    return w.writeWrappedTextMax(
        surface,
        ctx,
        2,
        row,
        surface.size.width -| 4,
        traceLineMaxRows(text),
        text,
        .{ .fg = color, .bg = theme.PANEL },
    );
}

fn traceLineMaxRows(text: []const u8) u16 {
    return if (std.mem.indexOfScalar(u8, text, '\n') != null) 4 else 3;
}

fn shouldShowProviderPending(active: bool, records: []const agent.Trace.Record) bool {
    if (!active or records.len == 0) return false;
    return switch (records[records.len - 1]) {
        .agent_start,
        .turn_start,
        => true,
        .message_append => |message| switch (message) {
            .user,
            .tool_result,
            => true,
            .assistant => false,
        },
        .tool_start,
        .tool_end,
        .turn_end,
        .run_error,
        .agent_end,
        => false,
    };
}

fn visibleRowsFrom(height: u16, first_row: u16) usize {
    return @intCast(height -| first_row -| 1);
}

/// Chooses the first item to render for tail-oriented live panels.
///
/// The agent tab is a live run surface, so default panels must keep newest
/// assistant/tool-result entries visible after large tool batches.
fn tailStartIndex(entry_count: usize, visible_rows: usize) usize {
    if (entry_count <= visible_rows) return 0;
    return entry_count - visible_rows;
}

fn firstLineTrimmed(text: []const u8, max_cells: u16) []const u8 {
    const line_end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    var line = std.mem.trim(u8, text[0..line_end], " \t\r\n");
    // This helper receives a display-cell budget from drawing code, but it
    // deliberately uses that value as a conservative byte budget. Rendering
    // correctness matters more here than filling every available cell.
    const byte_budget: usize = @intCast(max_cells);
    if (line.len > byte_budget) line = truncateUtf8Boundary(line, byte_budget);
    return line;
}

/// Truncates display snippets without splitting a UTF-8 byte sequence.
///
/// Agent messages often contain non-ASCII provider output. The TUI can choose
/// a conservative byte budget here, but it must still return valid UTF-8 so
/// downstream surface rendering never receives a broken codepoint.
fn truncateUtf8Boundary(text: []const u8, max_bytes: usize) []const u8 {
    var end = @min(text.len, max_bytes);
    if (end == text.len) return text;
    while (end > 0 and (text[end] & 0xc0) == 0x80) : (end -= 1) {}
    return text[0..end];
}

test "tailStartIndex keeps latest live-panel entries visible" {
    try std.testing.expectEqual(@as(usize, 0), tailStartIndex(0, 5));
    try std.testing.expectEqual(@as(usize, 0), tailStartIndex(5, 5));
    try std.testing.expectEqual(@as(usize, 3), tailStartIndex(8, 5));
    try std.testing.expectEqual(@as(usize, 8), tailStartIndex(8, 0));
}

test "resolvedRunSelection follows latest run until user selects history" {
    try std.testing.expectEqual(@as(?usize, null), resolvedRunSelection(0, null, null));
    try std.testing.expectEqual(@as(?usize, 2), resolvedRunSelection(3, null, 2));
    try std.testing.expectEqual(@as(?usize, 0), resolvedRunSelection(3, 0, 2));
    try std.testing.expectEqual(@as(?usize, 2), resolvedRunSelection(3, 9, 2));
    try std.testing.expectEqual(@as(?usize, null), resolvedRunSelection(3, 9, 4));
}

test "movedRunSelection clamps inside the session run list" {
    try std.testing.expectEqual(@as(?usize, null), movedRunSelection(0, null, null, 1));
    try std.testing.expectEqual(@as(?usize, 2), movedRunSelection(3, null, 1, 1));
    try std.testing.expectEqual(@as(?usize, 0), movedRunSelection(3, null, 1, -2));
    try std.testing.expectEqual(@as(?usize, 2), movedRunSelection(3, 2, 1, 7));
    try std.testing.expectEqual(@as(?usize, 1), movedRunSelection(3, 2, 1, -1));
}

test "agent run list uses common vertical navigation keys" {
    try std.testing.expectEqual(@as(?isize, 1), isRunListKey(.{ .codepoint = 'j' }));
    try std.testing.expectEqual(@as(?isize, -1), isRunListKey(.{ .codepoint = 'k' }));
    try std.testing.expectEqual(@as(?isize, 1), isRunListKey(.{ .codepoint = vaxis.Key.down }));
    try std.testing.expectEqual(@as(?isize, -1), isRunListKey(.{ .codepoint = vaxis.Key.up }));
    try std.testing.expectEqual(@as(?isize, null), isRunListKey(.{ .codepoint = 'i' }));
}

test "agent focus cycles between run and session list" {
    try std.testing.expectEqual(Focus.runs, movedFocus(.run, 1));
    try std.testing.expectEqual(Focus.run, movedFocus(.runs, 1));
    try std.testing.expectEqual(Focus.runs, movedFocus(.run, -1));
    try std.testing.expectEqual(Focus.run, movedFocus(.runs, -1));
}

test "agent focus keys use tab and horizontal arrows" {
    try std.testing.expectEqual(@as(?isize, 1), isFocusKey(.{ .codepoint = vaxis.Key.tab }));
    try std.testing.expectEqual(@as(?isize, 1), isFocusKey(.{ .codepoint = vaxis.Key.right }));
    try std.testing.expectEqual(@as(?isize, -1), isFocusKey(.{ .codepoint = vaxis.Key.left }));
    try std.testing.expectEqual(@as(?isize, null), isFocusKey(.{ .codepoint = 'j' }));
}

test "agent prompt starts blurred so global tab shortcuts remain available" {
    const state = State.init();
    try std.testing.expect(!state.prompt_active);
    try std.testing.expectEqual(Focus.run, state.focus);
    try std.testing.expectEqual(@as(?usize, null), state.selected_run_index);
}

test "agent running stop key follows common Esc cancellation" {
    try std.testing.expect(isStopKey(.{ .codepoint = vaxis.Key.escape }));
    try std.testing.expect(!isStopKey(.{ .codepoint = 's' }));
}

test "statusGlyphLabel reflects wrapper errors without fabricating core end reason" {
    try std.testing.expectEqualStrings("◒ stopping", statusGlyphLabel(.running, true, true, false));
    try std.testing.expectEqualStrings("● running", statusGlyphLabel(.running, true, false, true));
    try std.testing.expectEqualStrings("× error", statusGlyphLabel(.running, false, false, true));
    try std.testing.expectEqualStrings("× error", statusGlyphLabel(.{ .ended = .terminated }, false, false, true));
    try std.testing.expectEqualStrings("✓ complete", statusGlyphLabel(.{ .ended = .complete }, false, false, false));
}

test "provider pending hint follows model-boundary trace records" {
    try std.testing.expect(!shouldShowProviderPending(false, &.{
        .{ .turn_start = .{ .turn_index = 0 } },
    }));
    try std.testing.expect(shouldShowProviderPending(true, &.{
        .{ .message_append = .{ .user = .{ .content = "hello" } } },
    }));
    try std.testing.expect(shouldShowProviderPending(true, &.{
        .{ .message_append = .{ .user = .{ .content = "hello" } } },
        .{ .turn_start = .{ .turn_index = 0 } },
    }));
    try std.testing.expect(!shouldShowProviderPending(true, &.{
        .{ .message_append = .{ .assistant = .{ .content = "done", .tool_calls = &.{} } } },
    }));
}

test "traceLineMaxRows expands multiline provider output without unbounded growth" {
    try std.testing.expectEqual(@as(u16, 3), traceLineMaxRows("· one line"));
    try std.testing.expectEqual(@as(u16, 4), traceLineMaxRows("· first\nsecond\nthird\nfourth\nfifth"));
}

test "traceLine renders wrapper run errors as run stream diagnostics" {
    const line = try traceLine(std.testing.allocator, .{ .run_error = .{ .message = "provider HTTP 401: bad key" } });
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("× provider HTTP 401: bad key", line);
    try std.testing.expectEqual(theme.DANGER, traceColor(.{ .run_error = .{ .message = "x" } }));
    try std.testing.expect(traceHasRunError(&.{
        .agent_start,
        .{ .run_error = .{ .message = "provider HTTP 401: bad key" } },
    }));
    try std.testing.expect(!traceHasRunError(&.{
        .agent_start,
        .{ .agent_end = .{ .reason = .complete, .message_count = 1 } },
    }));
}

test "displayRecordCount hides internal loop boundaries from the run stream" {
    try std.testing.expectEqual(@as(usize, 4), displayRecordCount(&.{
        .agent_start,
        .{ .turn_start = .{ .turn_index = 0 } },
        .{ .message_append = .{ .user = .{ .content = "hello" } } },
        .{ .run_error = .{ .message = "provider HTTP 401: bad key" } },
        .{ .tool_end = .{
            .call = .{ .id = "call_1", .name = "Read", .arguments = "{\"path\":\"src/root.zig\"}" },
            .result = .{
                .content = "{\"status\":\"ok\"}",
                .is_error = false,
                .control = .continue_run,
            },
        } },
        .{ .message_append = .{ .tool_result = .{
            .tool_call_id = "call_1",
            .content = "{\"status\":\"ok\"}",
            .is_error = false,
        } } },
        .{ .turn_end = .{
            .turn_index = 0,
            .assistant = .{ .content = "done", .tool_calls = &.{} },
        } },
        .{ .agent_end = .{ .reason = .complete, .message_count = 2 } },
    }));
}

test "runStreamTailStartIndex tails by estimated rendered rows" {
    const records = [_]agent.Trace.Record{
        .{ .message_append = .{ .user = .{ .content = "please inspect the project" } } },
        .{ .message_append = .{ .assistant = .{ .content = "first\nsecond\nthird\nfourth", .tool_calls = &.{} } } },
        .{ .tool_end = .{
            .call = .{ .id = "call_1", .name = "Search", .arguments = "{\"query\":\"agent\"}" },
            .result = .{
                .content = "{\"status\":\"ok\",\"matches\":[\"src/agent/core/loop.zig\"]}",
                .is_error = false,
                .control = .continue_run,
            },
        } },
    };
    try std.testing.expectEqual(@as(usize, 0), runStreamTailStartIndex(&records, 10, false));
    try std.testing.expectEqual(@as(usize, 1), runStreamTailStartIndex(&records, 7, false));
    try std.testing.expectEqual(@as(usize, 2), runStreamTailStartIndex(&records, 6, false));
    try std.testing.expectEqual(@as(usize, 2), runStreamTailStartIndex(&records, 3, true));
}

test "sessionHeaderLine keeps runtime scope out of the run stream" {
    const line = try sessionHeaderLine(std.testing.allocator, .{
        .workspace_root = "/Users/lilhammer/workspace/clumsies",
        .model = "deepseek-chat",
    }, 80);
    defer std.testing.allocator.free(line);
    try std.testing.expect(std.mem.endsWith(u8, line, " · Main [default]"));
    try std.testing.expect(std.mem.indexOf(u8, line, "deepseek-chat") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "workspace/clumsies") != null);

    const resolving = try sessionHeaderLine(std.testing.allocator, .{
        .workspace_root = null,
        .model = null,
    }, 80);
    defer std.testing.allocator.free(resolving);
    try std.testing.expectEqualStrings("model unknown · ~ · Main [default]", resolving);
}

test "firstLineTrimmed does not split UTF-8 provider output" {
    try std.testing.expectEqualStrings("plain", firstLineTrimmed("plain text", 5));
    try std.testing.expectEqualStrings("评价", firstLineTrimmed("评价一下这个项目", 7));
    try std.testing.expectEqualStrings("评价", firstLineTrimmed("  评价一下\nnext", 7));
    try std.testing.expectEqualStrings("评价", firstLineTrimmed("评价", 6));
}
