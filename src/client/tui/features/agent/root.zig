//! Coding-agent feature container.
//!
//! This tab is the first interactive surface for the agent core. It treats a
//! session as a container of runs: the left panel renders the current/latest
//! run, and the right panel lists runs in that session.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../../theme.zig");
const draw = @import("../../widgets/draw.zig");
const w = @import("../../widgets.zig");
const agent_runner = @import("../../runtime/agent_runner.zig");
const agent = @import("clumsies_lib").agent;

const SPINNER_FRAMES = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
const TRACE_ENTRY_GAP_ROWS: u16 = 1;

pub const State = struct {
    prompt_buf: [4096]u8 = .{0} ** 4096,
    prompt_len: usize = 0,
    prompt_active: bool = false,
    focus: Focus = .run,
    selected_run_index: ?usize = null,
    run_scroll_bars: vxfw.ScrollBars,

    pub fn init() State {
        return .{
            .run_scroll_bars = w.initPlainScrollBars(theme.PANEL, 3),
        };
    }
};

pub const Focus = enum {
    run,
    runs,
};

/// Renders the agent tab as agent output + prompt beside a session run list.
///
/// The shell owns the concrete `State`; this feature only owns the tab-specific
/// layout and reads the shared `ApiState.agent_session` under the API mutex.
pub fn drawRoot(self: anytype, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    var root = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    w.fillSurface(&root, theme.CANVAS);

    const composer_h: u16 = 6;
    const runs_w: u16 = @min(size.width, @max(@as(u16, 30), size.width / 4));
    const run_w = size.width -| runs_w;
    const run_h = size.height -| composer_h;
    const children = try ctx.arena.alloc(vxfw.SubSurface, 3);
    children[0] = .{
        .origin = .{ .row = 0, .col = 0 },
        .surface = try drawCurrentRun(self, ctx.withConstraints(
            .{ .width = run_w, .height = run_h },
            .{ .width = run_w, .height = run_h },
        )),
    };
    children[1] = .{
        .origin = .{ .row = run_h, .col = 0 },
        .surface = try drawComposer(self, ctx.withConstraints(
            .{ .width = run_w, .height = composer_h },
            .{ .width = run_w, .height = composer_h },
        )),
    };
    children[2] = .{
        .origin = .{ .row = 0, .col = run_w },
        .surface = try drawRuns(self, ctx.withConstraints(
            .{ .width = runs_w, .height = size.height },
            .{ .width = runs_w, .height = size.height },
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
                resetRunScroll(self);
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
    if (self.agent.focus == .run) {
        if (try scrollRun(self, ctx, key)) {
            return;
        }
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
        if (key.matches(vaxis.Key.enter, .{})) {
            self.agent.focus = .run;
            resetRunScroll(self);
            ctx.consumeAndRedraw();
            return;
        }
    }
    if (!is_running and key.matches(vaxis.Key.escape, .{}) and self.agent.selected_run_index != null) {
        self.agent.selected_run_index = null;
        self.agent.focus = .run;
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('i', .{})) {
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
        .{ .key = "j/k", .label = "scroll" },
        .{ .key = "?", .label = "help" },
        .{ .key = "q", .label = "quit" },
    };
    if (self.agent.prompt_active) return &.{
        .{ .key = "Enter", .label = "run" },
        .{ .key = "Esc", .label = "blur" },
        .{ .key = "Ctrl+C", .label = "quit" },
    };
    if (self.agent.focus == .runs) return &.{
        .{ .key = "i", .label = "prompt" },
        .{ .key = "Tab", .label = "focus" },
        .{ .key = "↑/↓", .label = "runs" },
        .{ .key = "Enter", .label = "open" },
        .{ .key = "?", .label = "help" },
        .{ .key = "q", .label = "quit" },
    };
    return &.{
        .{ .key = "i", .label = "prompt" },
        .{ .key = "Tab", .label = "focus" },
        .{ .key = "j/k", .label = "scroll" },
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

fn resetRunScroll(self: anytype) void {
    self.agent.run_scroll_bars.scroll_view.cursor = 0;
    self.agent.run_scroll_bars.scroll_view.scroll.top = 0;
    self.agent.run_scroll_bars.scroll_view.scroll.vertical_offset = 0;
    self.agent.run_scroll_bars.scroll_view.scroll.left = 0;
    self.agent.run_scroll_bars.estimated_content_height = 0;
    self.agent.run_scroll_bars.estimated_content_width = null;
}

/// Routes Agent stream navigation through the same ScrollView model as other panels.
///
/// Normal one-row and half-page movement is delegated to ScrollView itself so
/// `pending_lines`, `vertical_offset`, and `has_more_vertical` stay coherent
/// across draw calls. Only project-level jump keys are handled here because the
/// existing content panels implement those outside vaxis as well.
fn scrollRun(self: anytype, ctx: *vxfw.EventContext, key: vaxis.Key) !bool {
    if (w.isJumpDownKey(key) or w.isJumpUpKey(key)) {
        const step = w.pageStepRows(&self.agent.run_scroll_bars.scroll_view);
        const row_count: u32 = self.agent.run_scroll_bars.estimated_content_height orelse 0;
        const visible: u32 = @intCast(visibleRunRows(&self.agent.run_scroll_bars.scroll_view));
        const max_top = row_count -| visible;
        if (w.isJumpDownKey(key)) {
            self.agent.run_scroll_bars.scroll_view.scroll.top = @min(max_top, self.agent.run_scroll_bars.scroll_view.scroll.top + @as(u32, @intCast(step)));
        } else {
            self.agent.run_scroll_bars.scroll_view.scroll.top = self.agent.run_scroll_bars.scroll_view.scroll.top -| @as(u32, @intCast(step));
        }
        self.agent.run_scroll_bars.scroll_view.scroll.vertical_offset = 0;
        self.agent.run_scroll_bars.scroll_view.scroll.left = 0;
        ctx.consumeAndRedraw();
        return true;
    }

    if (!isScrollViewKey(key)) return false;
    try self.agent.run_scroll_bars.scroll_view.handleEvent(ctx, .{ .key_press = key });
    self.agent.run_scroll_bars.scroll_view.scroll.left = 0;
    return true;
}

fn isScrollViewKey(key: vaxis.Key) bool {
    return key.matches('j', .{}) or
        key.matches(vaxis.Key.down, .{}) or
        key.matches('k', .{}) or
        key.matches(vaxis.Key.up, .{}) or
        key.matches('d', .{ .ctrl = true }) or
        key.matches('u', .{ .ctrl = true });
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
    w.writeText(&surface, ctx, 2, 0, "Prompt", theme.boldOn(theme.PANEL, theme.TEXT));

    const is_running = blk: {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        const running = self.api_state.agent_run_active;
        const boundary = if (self.api_state.agent_run_error) |message|
            firstLineTrimmed(message, surface.size.width -| 12)
        else
            sessionHeaderLine(ctx.arena, .{
                .workspace_root = self.api_state.agent_workspace_root,
                .model = self.api_state.agent_provider_model,
            }, surface.size.width -| 12) catch "model unknown · ~ · Main [default]";
        const header = composerHeader(ctx.arena, boundary, surface.size.width -| 4) catch boundary;
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
    w.writeText(&surface, ctx, 2, 0, "Agent", theme.boldOn(theme.PANEL, theme.TEXT));

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
    const icons = runIconSet(self.tick_count);
    const status_label = try statusGlyphLabel(
        ctx.arena,
        icons,
        state.status,
        is_live_view and self.api_state.agent_run_active,
        is_live_view and self.api_state.agent_run_cancel_requested,
        has_run_error or (is_live_view and self.api_state.agent_run_error != null),
    );
    w.writeRightText(&surface, ctx, 0, status_label, statusStyle(state.status, is_live_view and self.api_state.agent_run_active, has_run_error or (is_live_view and self.api_state.agent_run_error != null)));
    if (records.len == 0) {
        const text = if (is_live_view and self.api_state.agent_run_active)
            try std.fmt.allocPrint(ctx.arena, "{s} starting", .{icons.spinner})
        else
            "No runs yet.";
        try syncRunStreamWidgets(self, ctx.arena, &.{.{ .text = text, .style = theme.fg(theme.MUTED) }}, surface.size.height -| 2);
        return drawRunBody(self, ctx, &surface);
    }

    const show_provider_pending = shouldShowProviderPending(is_live_view and self.api_state.agent_run_active, records);
    const body_width = surface.size.width -| 2;
    const content_width = @max(@as(u16, 1), body_width -| @intFromBool(self.agent.run_scroll_bars.draw_vertical_scrollbar));
    var lines: std.ArrayListUnmanaged(RunLine) = .empty;
    if (is_live_view) {
        if (self.api_state.agent_run_error) |message| {
            try appendWrappedRunLine(ctx.arena, ctx, &lines, firstLineTrimmed(message, content_width), theme.fg(theme.DANGER), content_width);
        }
    }
    for (records, 0..) |record, record_index| {
        if (!isVisibleRunRecordAt(records, record_index)) continue;
        const line = try traceLine(ctx.arena, icons, record);
        try appendWrappedRunLine(ctx.arena, ctx, &lines, line, .{ .fg = traceColor(record), .bg = theme.PANEL }, content_width);
    }
    if (show_provider_pending) {
        const pending = try std.fmt.allocPrint(ctx.arena, "{s} model", .{icons.spinner});
        try appendWrappedRunLine(ctx.arena, ctx, &lines, pending, theme.fg(theme.ACCENT_SOFT), content_width);
    }
    trimTrailingRunGap(&lines);
    try syncRunStreamWidgets(self, ctx.arena, lines.items, surface.size.height -| 2);
    return drawRunBody(self, ctx, &surface);
}

fn drawRunBody(self: anytype, ctx: vxfw.DrawContext, surface: *vxfw.Surface) std.mem.Allocator.Error!vxfw.Surface {
    const body_w = surface.size.width -| 2;
    const body_h = surface.size.height -| 2;
    const body_ctx = ctx.withConstraints(
        .{ .width = body_w, .height = body_h },
        .{ .width = body_w, .height = body_h },
    );
    const body = try self.agent.run_scroll_bars.widget().draw(body_ctx);
    const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
    children[0] = .{
        .origin = .{ .row = 1, .col = 1 },
        .surface = body,
    };
    surface.children = children;
    return surface.*;
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
            .bg = if (is_selected) theme.PANEL_SOFT else theme.PANEL,
            .bold = is_selected and self.agent.focus == .runs,
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

const RunIconSet = struct {
    spinner: []const u8,
    user: []const u8 = "›",
    assistant: []const u8 = "✦",
    tool_ok: []const u8 = "✓",
    tool_error: []const u8 = "✗",
};

/// Returns the symbol palette for one draw tick.
///
/// Animated and static glyphs live together so the run stream has one visual
/// language: braille spinner for live work, `✦` for assistant prose, `›` for
/// user prompts, and result glyphs for completed tools.
fn runIconSet(tick_count: u64) RunIconSet {
    return .{ .spinner = SPINNER_FRAMES[@intCast(tick_count % SPINNER_FRAMES.len)] };
}

/// Formats the compact status shown in the Agent panel border.
///
/// The border status is intentionally terse: it uses the same spinner as the
/// stream for active work, then falls back to stable result glyphs for completed
/// runs so status and stream rows do not teach different symbol meanings.
fn statusGlyphLabel(arena: std.mem.Allocator, icons: RunIconSet, status: agent.Session.Status, active: bool, cancel_requested: bool, has_error: bool) std.mem.Allocator.Error![]const u8 {
    if (active and cancel_requested) return std.fmt.allocPrint(arena, "{s} stopping", .{icons.spinner});
    if (active) return std.fmt.allocPrint(arena, "{s} running", .{icons.spinner});
    if (has_error) return "✗ error";
    return switch (status) {
        .idle => "○ idle",
        .running => std.fmt.allocPrint(arena, "{s} running", .{icons.spinner}),
        .ended => |reason| switch (reason) {
            .complete => "✓ complete",
            .terminated => "■ stopped",
            .max_turns => "… max",
        },
    };
}

/// Chooses the semantic color for the compact Agent panel status.
///
/// Colors are reserved for state: accent means active work, green means a
/// completed run, red means an error, and muted means idle or non-error stop.
fn statusStyle(status: agent.Session.Status, active: bool, has_error: bool) vaxis.Style {
    if (has_error) return theme.fg(theme.DANGER);
    if (active) return theme.fgBold(theme.ACCENT_SOFT);
    return switch (status) {
        .idle => theme.fg(theme.MUTED),
        .running => theme.fgBold(theme.ACCENT_SOFT),
        .ended => |reason| theme.fg(switch (reason) {
            .complete => theme.OK,
            .terminated,
            .max_turns,
            => theme.MUTED,
        }),
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
    if (has_error) return "✗";
    return switch (status) {
        .idle => "○",
        .running => "⠋",
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
fn composerHeader(arena: std.mem.Allocator, boundary: []const u8, max_cells: u16) std.mem.Allocator.Error![]const u8 {
    return arena.dupe(u8, firstLineTrimmed(boundary, max_cells));
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
    for (records, 0..) |_, index| {
        if (isVisibleRunRecordAt(records, index)) count += 1;
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

const RunLine = struct {
    text: []const u8,
    style: vaxis.Style,
};

/// Syncs Agent stream rows into the shared ScrollBars widget.
///
/// Existing TUI content panels make ScrollView own viewport state and scrollbar
/// rendering. The Agent panel follows that same boundary by converting wrapped
/// trace output into one child widget per visible row, then letting ScrollView
/// handle row clipping, wheel movement, and key-driven scroll top updates. This
/// function only clamps invalid scroll state; it must not force a bottom anchor
/// during draw because ScrollView.draw also mutates `scroll.top`.
fn syncRunStreamWidgets(
    self: anytype,
    arena: std.mem.Allocator,
    lines: []const RunLine,
    height: u16,
) std.mem.Allocator.Error!void {
    const row_count = @max(lines.len, 1);
    const widgets = try arena.alloc(vxfw.Widget, row_count);
    const texts = try arena.alloc(vxfw.Text, row_count);
    if (lines.len == 0) {
        texts[0] = .{ .text = "", .style = theme.fg(theme.MUTED), .softwrap = false };
        widgets[0] = texts[0].widget();
    } else {
        for (lines, 0..) |line, index| {
            texts[index] = .{ .text = line.text, .style = line.style, .softwrap = false };
            widgets[index] = texts[index].widget();
        }
    }

    self.agent.run_scroll_bars.scroll_view.children = .{ .slice = widgets };
    self.agent.run_scroll_bars.estimated_content_height = @intCast(row_count);
    self.agent.run_scroll_bars.estimated_content_width = null;
    clampRunScroll(&self.agent.run_scroll_bars.scroll_view, row_count, height);
    self.agent.run_scroll_bars.scroll_view.scroll.left = 0;
}

fn clampRunScroll(scroll_view: *vxfw.ScrollView, row_count: usize, height: u16) void {
    const max_top: usize = row_count -| @as(usize, @intCast(height));
    if (max_top == 0) {
        scroll_view.scroll.top = 0;
        scroll_view.scroll.vertical_offset = 0;
    } else if (scroll_view.scroll.top > max_top) {
        scroll_view.scroll.top = @intCast(max_top);
        scroll_view.scroll.vertical_offset = 0;
    }
}

fn visibleRunRows(scroll_view: *const vxfw.ScrollView) usize {
    return @max(@as(usize, @intCast(scroll_view.last_height)), 1);
}

fn appendWrappedRunLine(
    arena: std.mem.Allocator,
    ctx: vxfw.DrawContext,
    out: *std.ArrayListUnmanaged(RunLine),
    text: []const u8,
    style: vaxis.Style,
    max_width: u16,
) std.mem.Allocator.Error!void {
    var rest = text;
    while (true) {
        const next = nextWrappedLine(ctx, rest, max_width) orelse break;
        rest = next.rest;
        try out.append(arena, .{ .text = next.line, .style = style });
    }
    if (text.len == 0) try out.append(arena, .{ .text = "", .style = style });
    var gap: u16 = 0;
    while (gap < TRACE_ENTRY_GAP_ROWS) : (gap += 1) {
        try out.append(arena, .{ .text = "", .style = theme.fg(theme.MUTED) });
    }
}

fn trimTrailingRunGap(lines: *std.ArrayListUnmanaged(RunLine)) void {
    while (lines.items.len > 0 and lines.items[lines.items.len - 1].text.len == 0) {
        lines.items.len -= 1;
    }
}

/// Decides whether one runtime record should appear in the Agent stream.
///
/// This is context-sensitive because pending and completed tools share a
/// lifecycle: `tool_start` is useful while a tool is still running, but once a
/// matching `tool_end` exists the final result row becomes the single source of
/// truth. Empty assistant tool-call messages are also hidden because the tool
/// rows render the actionable work.
fn isVisibleRunRecordAt(records: []const agent.Trace.Record, index: usize) bool {
    if (index >= records.len) return false;
    return switch (records[index]) {
        .message_append => |message| switch (message) {
            .user => true,
            .assistant => |value| value.content.len > 0,
            .tool_result => false,
        },
        .tool_start => |call| !hasLaterToolEnd(records, index, call.id),
        .tool_end,
        .run_error,
        => true,
        .agent_start,
        .turn_start,
        .turn_end,
        .agent_end,
        => false,
    };
}

fn hasLaterToolEnd(records: []const agent.Trace.Record, start_index: usize, call_id: []const u8) bool {
    if (start_index + 1 >= records.len) return false;
    for (records[start_index + 1 ..]) |record| {
        switch (record) {
            .tool_end => |value| {
                if (std.mem.eql(u8, value.call.id, call_id)) return true;
            },
            else => {},
        }
    }
    return false;
}

/// Formats one trace record into the user-facing run stream.
///
/// Trace records are runtime events, while this panel is a coding-agent
/// conversation. This adapter gives user messages, assistant prose, live tools,
/// and tool results distinct symbols before the generic wrapped-text renderer
/// lays them out.
fn traceLine(arena: std.mem.Allocator, icons: RunIconSet, record: agent.Trace.Record) std.mem.Allocator.Error![]const u8 {
    return switch (record) {
        .agent_start => std.fmt.allocPrint(arena, "○ start", .{}),
        .turn_start => |value| std.fmt.allocPrint(arena, "◌ turn {d}", .{value.turn_index + 1}),
        .message_append => |message| messageAppendLine(arena, icons, message),
        .tool_start => |call| std.fmt.allocPrint(arena, "{s} {s} {s}", .{ icons.spinner, call.name, call.arguments }),
        .tool_end => |value| std.fmt.allocPrint(arena, "{s} {s} {s}", .{
            if (value.result.is_error) icons.tool_error else icons.tool_ok,
            value.call.name,
            value.result.content,
        }),
        .turn_end => |value| std.fmt.allocPrint(arena, "◌ turn {d}", .{value.turn_index + 1}),
        .run_error => |value| std.fmt.allocPrint(arena, "{s} {s}", .{ icons.tool_error, value.message }),
        .agent_end => |value| std.fmt.allocPrint(arena, "{s}", .{endReasonGlyphLabel(value.reason)}),
    };
}

/// Formats transcript messages that appear inside the visible run stream.
///
/// Assistant text and tool requests both arrive through assistant messages, so
/// this function keeps natural-language answers on `✦` while pending tool-call
/// requests use the spinner language shared with live tool execution.
fn messageAppendLine(arena: std.mem.Allocator, icons: RunIconSet, message: agent.Trace.MessageAppend) std.mem.Allocator.Error![]const u8 {
    return switch (message) {
        .user => |value| std.fmt.allocPrint(arena, "{s} {s}", .{ icons.user, value.content }),
        .assistant => |value| if (value.content.len > 0)
            std.fmt.allocPrint(arena, "{s} {s}", .{ icons.assistant, value.content })
        else
            std.fmt.allocPrint(arena, "{s} {d} tool call(s)", .{ icons.spinner, value.tool_calls.len }),
        .tool_result => |value| std.fmt.allocPrint(arena, "{s} {s}", .{ if (value.is_error) icons.tool_error else icons.tool_ok, value.content }),
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
            .assistant => theme.TEXT_SOFT,
            .tool_result => |value| if (value.is_error) theme.DANGER else theme.TEXT_SOFT,
        },
        .tool_start => theme.INFO,
        .tool_end => |value| if (value.result.is_error) theme.DANGER else theme.OK,
    };
}

const WrappedLine = struct {
    line: []const u8,
    rest: []const u8,
};

fn nextWrappedLine(ctx: vxfw.DrawContext, text: []const u8, max_width: u16) ?WrappedLine {
    if (text.len == 0 or max_width == 0) return null;
    const line_len = draw.wrappedLineLen(ctx, text, max_width);
    if (line_len == 0) {
        if (text[0] == '\n') return .{ .line = "", .rest = text[1..] };
        return null;
    }
    var rest = text[line_len..];
    if (rest.len > 0 and rest[0] == '\n') {
        rest = rest[1..];
    } else {
        rest = draw.trimLeadingSpaces(rest);
    }
    return .{ .line = text[0..line_len], .rest = rest };
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

test "agent scroll delegates row and half-page keys to ScrollView" {
    try std.testing.expect(isScrollViewKey(.{ .codepoint = 'j' }));
    try std.testing.expect(isScrollViewKey(.{ .codepoint = 'k' }));
    try std.testing.expect(isScrollViewKey(.{ .codepoint = vaxis.Key.down }));
    try std.testing.expect(isScrollViewKey(.{ .codepoint = vaxis.Key.up }));
    try std.testing.expect(isScrollViewKey(.{ .codepoint = 'd', .mods = .{ .ctrl = true } }));
    try std.testing.expect(isScrollViewKey(.{ .codepoint = 'u', .mods = .{ .ctrl = true } }));
    try std.testing.expect(!isScrollViewKey(.{ .codepoint = 'i' }));
}

test "agent prompt starts blurred so global tab shortcuts remain available" {
    const state = State.init();
    try std.testing.expect(!state.prompt_active);
    try std.testing.expectEqual(Focus.run, state.focus);
    try std.testing.expectEqual(@as(?usize, null), state.selected_run_index);
    try std.testing.expectEqual(@as(?u32, null), state.run_scroll_bars.estimated_content_height);
}

test "agent running stop key follows common Esc cancellation" {
    try std.testing.expect(isStopKey(.{ .codepoint = vaxis.Key.escape }));
    try std.testing.expect(!isStopKey(.{ .codepoint = 's' }));
}

test "statusGlyphLabel reflects wrapper errors without fabricating core end reason" {
    var arena_instance = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const icons: RunIconSet = .{ .spinner = "⠋" };
    try std.testing.expectEqualStrings("⠋ stopping", try statusGlyphLabel(arena, icons, .running, true, true, false));
    try std.testing.expectEqualStrings("⠋ running", try statusGlyphLabel(arena, icons, .running, true, false, true));
    try std.testing.expectEqualStrings("✗ error", try statusGlyphLabel(arena, icons, .running, false, false, true));
    try std.testing.expectEqualStrings("✗ error", try statusGlyphLabel(arena, icons, .{ .ended = .terminated }, false, false, true));
    try std.testing.expectEqualStrings("✓ complete", try statusGlyphLabel(arena, icons, .{ .ended = .complete }, false, false, false));
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

test "clampRunScroll only repairs invalid viewport offsets" {
    var scroll_view = vxfw.ScrollView{ .children = .{ .slice = &.{} } };
    scroll_view.scroll.top = 2;
    clampRunScroll(&scroll_view, 20, 5);
    try std.testing.expectEqual(@as(u32, 2), scroll_view.scroll.top);

    scroll_view.scroll.top = 99;
    clampRunScroll(&scroll_view, 20, 5);
    try std.testing.expectEqual(@as(u32, 15), scroll_view.scroll.top);

    clampRunScroll(&scroll_view, 4, 5);
    try std.testing.expectEqual(@as(u32, 0), scroll_view.scroll.top);
}

test "trimTrailingRunGap removes only bottom spacer rows" {
    var lines: std.ArrayListUnmanaged(RunLine) = .empty;
    try lines.append(std.testing.allocator, .{ .text = "› prompt", .style = theme.fg(theme.TEXT) });
    try lines.append(std.testing.allocator, .{ .text = "", .style = theme.fg(theme.MUTED) });
    try lines.append(std.testing.allocator, .{ .text = "", .style = theme.fg(theme.MUTED) });
    defer lines.deinit(std.testing.allocator);

    trimTrailingRunGap(&lines);
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqualStrings("› prompt", lines.items[0].text);
}

test "traceLine renders wrapper run errors as run stream diagnostics" {
    const icons: RunIconSet = .{ .spinner = "⠋" };
    const line = try traceLine(std.testing.allocator, icons, .{ .run_error = .{ .message = "provider HTTP 401: bad key" } });
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("✗ provider HTTP 401: bad key", line);
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

test "traceLine uses separate assistant and tool symbols" {
    const icons: RunIconSet = .{ .spinner = "⠋" };

    const assistant_line = try traceLine(std.testing.allocator, icons, .{ .message_append = .{ .assistant = .{
        .content = "I will inspect the file.",
        .tool_calls = &.{},
    } } });
    defer std.testing.allocator.free(assistant_line);
    try std.testing.expectEqualStrings("✦ I will inspect the file.", assistant_line);

    const tool_start_line = try traceLine(std.testing.allocator, icons, .{ .tool_start = .{
        .id = "call_1",
        .name = "Read",
        .arguments = "{\"path\":\"src/root.zig\"}",
    } });
    defer std.testing.allocator.free(tool_start_line);
    try std.testing.expectEqualStrings("⠋ Read {\"path\":\"src/root.zig\"}", tool_start_line);

    const tool_end_line = try traceLine(std.testing.allocator, icons, .{ .tool_end = .{
        .call = .{ .id = "call_1", .name = "Read", .arguments = "{\"path\":\"src/root.zig\"}" },
        .result = .{
            .content = "{\"status\":\"ok\"}",
            .is_error = false,
            .control = .continue_run,
        },
    } });
    defer std.testing.allocator.free(tool_end_line);
    try std.testing.expectEqualStrings("✓ Read {\"status\":\"ok\"}", tool_end_line);
}

test "displayRecordCount hides internal loop boundaries from the run stream" {
    try std.testing.expectEqual(@as(usize, 3), displayRecordCount(&.{
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

test "displayRecordCount hides completed tool-start spinners" {
    try std.testing.expectEqual(@as(usize, 1), displayRecordCount(&.{
        .{ .message_append = .{ .assistant = .{
            .content = "",
            .tool_calls = &.{.{ .id = "call_1", .name = "Read", .arguments = "{\"path\":\"src/root.zig\"}" }},
        } } },
        .{ .tool_start = .{ .id = "call_1", .name = "Read", .arguments = "{\"path\":\"src/root.zig\"}" } },
        .{ .tool_end = .{
            .call = .{ .id = "call_1", .name = "Read", .arguments = "{\"path\":\"src/root.zig\"}" },
            .result = .{
                .content = "{\"status\":\"ok\"}",
                .is_error = false,
                .control = .continue_run,
            },
        } },
    }));
    try std.testing.expectEqual(@as(usize, 1), displayRecordCount(&.{
        .{ .tool_start = .{ .id = "call_1", .name = "Read", .arguments = "{\"path\":\"src/root.zig\"}" } },
    }));
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

test "composerHeader does not append input hints to runtime metadata" {
    const line = try composerHeader(std.testing.allocator, "deepseek-chat · ~/workspace/clumsies · Main [default]", 80);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("deepseek-chat · ~/workspace/clumsies · Main [default]", line);
    try std.testing.expect(std.mem.indexOf(u8, line, " · i") == null);
    try std.testing.expect(std.mem.indexOf(u8, line, "⠋") == null);
}

test "firstLineTrimmed does not split UTF-8 provider output" {
    try std.testing.expectEqualStrings("plain", firstLineTrimmed("plain text", 5));
    try std.testing.expectEqualStrings("评价", firstLineTrimmed("评价一下这个项目", 7));
    try std.testing.expectEqualStrings("评价", firstLineTrimmed("  评价一下\nnext", 7));
    try std.testing.expectEqualStrings("评价", firstLineTrimmed("评价", 6));
}
