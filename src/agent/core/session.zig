//! Agent session container shared by future CLI, TUI, and RPC surfaces.
//!
//! A session is a longer-lived coding conversation. It owns a list of agent
//! loop runs, while the top-level history/trace/state fields expose the current
//! or latest run for UI surfaces that render one active run at a time.
//!
//! Persistence is opt-in: call `enablePersistence` to append every emitted
//! trace record to a JSONL file. `loadFromFile` in `session_persistence.zig`
//! replays those records to reconstruct an identical in-memory session.

const std = @import("std");
const event = @import("event.zig");
const tool = @import("tool.zig");
const Trace = @import("trace.zig");
const transcript = @import("transcript.zig");
const persistence = @import("session_persistence.zig");

const Session = @This();

allocator: std.mem.Allocator,
entries: std.ArrayList(Entry) = .empty,
trace: Trace,
state: State,
runs: std.ArrayList(Run) = .empty,
current_run_index: ?usize = null,
revision: u64 = 0,
save_state: ?SaveState = null,

/// Initializes an in-memory agent session.
pub fn init(allocator: std.mem.Allocator) Session {
    return .{
        .allocator = allocator,
        .trace = Trace.init(allocator),
        .state = State.init(allocator),
    };
}

/// Owned state for the optional session persistence file.
pub const SaveState = struct {
    file: std.fs.File,
    path: []const u8,
};

/// Opens a JSONL file and enables append-only persistence.
pub fn enablePersistence(self: *Session, path: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{ .truncate = false, .read = true });
    errdefer file.close();
    _ = try file.seekFromEnd(0);
    self.save_state = .{ .file = file, .path = try self.allocator.dupe(u8, path) };
}

/// Closes the persistence file and stops appending.
pub fn disablePersistence(self: *Session) void {
    if (self.save_state) |*save| {
        save.file.close();
        self.allocator.free(save.path);
    }
    self.save_state = null;
}

/// Releases durable entries, owned trace, persisted file, and derived state.
pub fn deinit(self: *Session) void {
    self.disablePersistence();
    self.clearRuns();
    self.clearEntries();
    self.entries.deinit(self.allocator);
    self.trace.deinit();
    self.state.deinit();
    self.runs.deinit(self.allocator);
}


/// Clears all runs plus the current run projection.
pub fn reset(self: *Session) void {
    self.clearRuns();
    self.current_run_index = null;
    self.clearCurrentRun();
    self.revision +%= 1;
}

/// Clears only the current/latest run projection.
///
/// The TUI calls this when a new background run has been accepted but before
/// the worker emits `.agent_start`. Historical runs remain available on the
/// same session's run list.
pub fn clearCurrentRun(self: *Session) void {
    self.clearEntries();
    self.trace.deinit();
    self.trace = Trace.init(self.allocator);
    self.state.reset();
    self.current_run_index = null;
}

/// Returns the session's composite event sink.
///
/// The agent loop knows only about `event.Sink`. `Session` implements that port
/// by cloning each borrowed event once, applying the owned record to `State`,
/// deriving an optional durable `Entry`, then transferring the same record into
/// its owned `Trace`.
pub fn sink(self: *Session) event.Sink {
    return .{ .ctx = self, .emit_fn = emit };
}

/// Returns durable session-history entries.
///
/// This excludes runtime-only progress records such as tool starts and turn
/// boundaries. Use `trace.records` when a caller needs execution observability.
pub fn history(self: *const Session) []const Entry {
    return self.entries.items;
}

/// Returns all runs recorded in this session.
pub fn runsView(self: *const Session) []const Run {
    return self.runs.items;
}

/// Returns the current or latest run, if one has started.
pub fn currentRun(self: *const Session) ?*const Run {
    const index = self.current_run_index orelse return null;
    if (index >= self.runs.items.len) return null;
    return &self.runs.items[index];
}

/// Returns all durable entries from completed (non-current) runs.
///
/// These are the conversation facts the assembler passes as long-term context
/// so the model can see what happened in previous interactions.
pub fn priorEntries(self: *const Session, allocator: std.mem.Allocator) ![]const Entry {
    var all: std.ArrayList(Entry) = .empty;
    errdefer all.deinit(allocator);
    for (self.runs.items) |*run| {
        if (self.current_run_index) |current| {
            if (run.index == current) continue;
        }
        try all.ensureUnusedCapacity(allocator, run.entries.items.len);
        for (run.entries.items) |entry| {
            const duped = try entry.clone(allocator);
            all.appendAssumeCapacity(duped);
        }
    }
    return try all.toOwnedSlice(allocator);
}

/// Replaces entries before the most recent `run_end` with a single compaction
/// entry. Entries after the boundary are kept intact. Also collapses the runs
/// list to only the last completed run.
pub fn compact(self: *Session, summary: []const u8, tokens_before: usize, compacted_run_count: usize, compacted_message_count: usize) !void {
    var entries_to_keep: usize = 0;
    var idx: usize = self.entries.items.len;
    while (idx > 0) {
        idx -= 1;
        entries_to_keep += 1;
        if (self.entries.items[idx] == .run_end) break;
    }
    if (entries_to_keep >= self.entries.items.len) return;

    const start_of_keep = self.entries.items.len - entries_to_keep;

    for (self.entries.items[0..start_of_keep]) |*old_entry| {
        old_entry.deinit(self.allocator);
    }

    var kept: std.ArrayList(Entry) = .empty;
    errdefer {
        for (kept.items) |*e| e.deinit(self.allocator);
        kept.deinit(self.allocator);
    }
    const owned_summary = try self.allocator.dupe(u8, summary);
    errdefer self.allocator.free(owned_summary);
    try kept.append(self.allocator, .{ .compaction = .{
        .summary = owned_summary,
        .tokens_before = tokens_before,
        .run_count = compacted_run_count,
        .message_count = compacted_message_count,
    } });
    for (self.entries.items[start_of_keep..]) |*entry| {
        try kept.append(self.allocator, entry.*);
    }

    self.entries.deinit(self.allocator);
    self.entries = kept;

    if (self.runs.items.len > 1) {
        const last_idx = self.runs.items.len - 1;
        for (self.runs.items[0..last_idx]) |*old_run| {
            old_run.deinit();
        }
        const last_run = self.runs.items[last_idx];
        self.runs.items.len = 0;
        try self.runs.append(self.allocator, last_run);
        self.current_run_index = 0;
    }

    self.revision +%= 1;

    // Persist compaction to session.jsonl if enabled.
    if (self.save_state) |save| {
        persistence.appendCompactionEntry(save.file, summary, tokens_before, compacted_run_count, compacted_message_count, self.allocator) catch {};
    }
}

/// On startup, trim the session to only the most recent run's entries
/// so that restored sessions with many old runs don't overflow context
/// on the first provider call.
pub fn trimToLastRun(self: *Session) void {
    var entries_to_keep: usize = 0;
    var idx: usize = self.entries.items.len;
    while (idx > 0) {
        idx -= 1;
        entries_to_keep += 1;
        if (self.entries.items[idx] == .run_end) break;
    }
    if (entries_to_keep >= self.entries.items.len) return;

    const start_of_keep = self.entries.items.len - entries_to_keep;
    for (self.entries.items[0..start_of_keep]) |*old_entry| {
        old_entry.deinit(self.allocator);
    }
    var kept: std.ArrayList(Entry) = .empty;
    for (self.entries.items[start_of_keep..]) |*entry| {
        kept.append(self.allocator, entry.*) catch {
            kept.deinit(self.allocator);
            return;
        };
    }
    self.entries.deinit(self.allocator);
    self.entries = kept;
    if (self.runs.items.len > 1) {
        const last_idx = self.runs.items.len - 1;
        const last_run = self.runs.items[last_idx];
        for (self.runs.items[0..last_idx]) |*old_run| {
            old_run.deinit();
        }
        self.runs.items.len = 0;
        self.runs.append(self.allocator, last_run) catch return;
        self.current_run_index = 0;
    }
    self.revision +%= 1;
}

/// Rebuilds the derived state from the owned trace.
///
/// Use this after loading or compacting trace records. It keeps `State`
/// explicitly derived from history rather than making it the source of truth.
pub fn rebuildState(self: *Session) !void {
    try self.state.rebuild(self.trace.records.items);
}

/// Commits one borrowed loop event into owned session state.
///
/// The session owns several projections of the same event stream. This
/// function prepares the next trace/history/state payloads before replacing the
/// current ones so allocation failure cannot leave top-level state, run state,
/// and trace out of sync.
fn emit(ctx: *anyopaque, new_event: event.Event) !void {
    const self: *Session = @ptrCast(@alignCast(ctx));
    var record = try Trace.Record.clone(self.allocator, new_event);
    var record_owned = true;
    defer if (record_owned) record.deinit(self.allocator);

    const starts_new_run = std.meta.activeTag(record) == .agent_start;
    const existing_run = self.currentRunMut();
    const needs_new_run = starts_new_run or existing_run == null;

    var entry = try Entry.cloneFromTrace(self.allocator, record);
    errdefer if (entry) |value| value.deinit(self.allocator);
    var run_entry = try Entry.cloneFromTrace(self.allocator, record);
    errdefer if (run_entry) |value| value.deinit(self.allocator);
    var run_record = try Trace.Record.clone(self.allocator, new_event);
    var run_record_owned = true;
    defer if (run_record_owned) run_record.deinit(self.allocator);

    var next_state = if (needs_new_run) State.init(self.allocator) else try self.state.clone(self.allocator);
    var next_state_owned = true;
    defer if (next_state_owned) next_state.deinit();
    try next_state.apply(record);

    var next_run_state = if (needs_new_run) State.init(self.allocator) else try existing_run.?.state.clone(self.allocator);
    var next_run_state_owned = true;
    defer if (next_run_state_owned) next_run_state.deinit();
    try next_run_state.apply(record);

    if (needs_new_run) {
        var next_trace = Trace.init(self.allocator);
        var next_trace_owned = true;
        defer if (next_trace_owned) next_trace.deinit();
        try next_trace.records.ensureUnusedCapacity(self.allocator, 1);
        var next_run_trace = Trace.init(self.allocator);
        var next_run_trace_owned = true;
        defer if (next_run_trace_owned) next_run_trace.deinit();
        try next_run_trace.records.ensureUnusedCapacity(self.allocator, 1);

        var next_entries: std.ArrayList(Entry) = .empty;
        var next_entries_owned = true;
        defer if (next_entries_owned) {
            for (next_entries.items) |item| item.deinit(self.allocator);
            next_entries.deinit(self.allocator);
        };
        if (entry != null) try next_entries.ensureUnusedCapacity(self.allocator, 1);

        var next_run_entries: std.ArrayList(Entry) = .empty;
        var next_run_entries_owned = true;
        defer if (next_run_entries_owned) {
            for (next_run_entries.items) |item| item.deinit(self.allocator);
            next_run_entries.deinit(self.allocator);
        };
        if (run_entry != null) try next_run_entries.ensureUnusedCapacity(self.allocator, 1);

        try self.runs.ensureUnusedCapacity(self.allocator, 1);
        if (entry) |value| {
            next_entries.appendAssumeCapacity(value);
            entry = null;
        }
        if (run_entry) |value| {
            next_run_entries.appendAssumeCapacity(value);
            run_entry = null;
        }

        var next_run = Run{
            .allocator = self.allocator,
            .index = self.runs.items.len,
            .entries = next_run_entries,
            .trace = next_run_trace,
            .state = next_run_state,
        };
        next_run_trace_owned = false;
        var next_run_owned = true;
        defer if (next_run_owned) next_run.deinit();
        next_run.trace.appendOwnedAssumeCapacity(run_record);
        run_record_owned = false;

        self.state.deinit();
        self.state = next_state;
        next_state_owned = false;
        next_run_state_owned = false;
        next_run_entries_owned = false;

        self.clearEntries();
        self.entries.deinit(self.allocator);
        self.entries = next_entries;
        next_entries_owned = false;

        self.trace.deinit();
        next_trace.appendOwnedAssumeCapacity(record);
        self.trace = next_trace;
        next_trace_owned = false;
        record_owned = false;

        self.runs.appendAssumeCapacity(next_run);
        self.current_run_index = next_run.index;
        next_run_owned = false;
    } else {
        try self.trace.records.ensureUnusedCapacity(self.allocator, 1);
        if (entry != null) try self.entries.ensureUnusedCapacity(self.allocator, 1);
        const run = existing_run.?;
        try run.trace.records.ensureUnusedCapacity(self.allocator, 1);
        if (run_entry != null) try run.entries.ensureUnusedCapacity(self.allocator, 1);

        self.state.deinit();
        self.state = next_state;
        next_state_owned = false;
        run.state.deinit();
        run.state = next_run_state;
        next_run_state_owned = false;
        if (entry) |value| {
            self.entries.appendAssumeCapacity(value);
            entry = null;
        }
        if (run_entry) |value| {
            run.entries.appendAssumeCapacity(value);
            run_entry = null;
        }
        self.trace.appendOwnedAssumeCapacity(record);
        record_owned = false;
        run.trace.appendOwnedAssumeCapacity(run_record);
        run_record_owned = false;
    }
    self.revision +%= 1;

    // Best-effort persistence: state is already committed.
    if (self.save_state) |save| {
        const last = self.trace.records.items[self.trace.records.items.len - 1];
        persistence.appendRecord(save.file, last, self.allocator) catch {};
    }
}

fn currentRunMut(self: *Session) ?*Run {
    const index = self.current_run_index orelse return null;
    if (index >= self.runs.items.len) return null;
    return &self.runs.items[index];
}

fn clearEntries(self: *Session) void {
    for (self.entries.items) |entry| entry.deinit(self.allocator);
    self.entries.clearRetainingCapacity();
}

fn clearRuns(self: *Session) void {
    for (self.runs.items) |*run| run.deinit();
    self.runs.clearRetainingCapacity();
}

/// One agent loop run inside a longer-lived session.
///
/// A run starts at `.agent_start` and ends at `.agent_end`. The TUI can render
/// the latest run as the active left-side panel while listing previous runs on
/// the right without losing their durable messages or end state.
pub const Run = struct {
    allocator: std.mem.Allocator,
    index: usize,
    entries: std.ArrayList(Entry) = .empty,
    trace: Trace,
    state: State,

    /// Initializes an empty run projection.
    pub fn init(allocator: std.mem.Allocator, index: usize) Run {
        return .{
            .allocator = allocator,
            .index = index,
            .trace = Trace.init(allocator),
            .state = State.init(allocator),
        };
    }

    /// Releases entries, trace records, and derived state owned by this run.
    pub fn deinit(self: *Run) void {
        for (self.entries.items) |entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.trace.deinit();
        self.state.deinit();
    }

    /// Returns durable conversation facts for this run.
    pub fn history(self: *const Run) []const Entry {
        return self.entries.items;
    }
};

/// Summary produced by context compaction, stored as a durable session entry.
///
/// When the session's estimated token count exceeds the model's context window,
/// the agent runner compacts older entries into a single summary. The assembler
/// recognizes compaction entries and replaces all prior entries with the summary
/// text when building provider context.
pub const CompactionSummary = struct {
    summary: []const u8,
    tokens_before: usize,
    run_count: usize,
    message_count: usize,

    pub fn deinit(self: CompactionSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.summary);
    }

    pub fn clone(self: *const CompactionSummary, allocator: std.mem.Allocator) !CompactionSummary {
        return .{
            .summary = try allocator.dupe(u8, self.summary),
            .tokens_before = self.tokens_before,
            .run_count = self.run_count,
            .message_count = self.message_count,
        };
    }
};

///
/// `Entry` is intentionally thin: `message` and `run_end` are the only facts
/// that matter for durable replay and memory recall right now. The agent loop
/// currently has no mid-run model change, context compaction, or
/// branch/fork mechanism, so entries like `model_change`, `compaction`, or
/// `branch_summary` are not added until those features land.
///
/// `Trace.Record` carries the full lifecycle stream (tool_start/tool_end,
/// turn boundaries, errors) and is the source of truth for session recovery
/// via `session_persistence.zig`. `Entry` is a derived projection, not a
/// replacement for the trace.
pub const Entry = union(enum) {
    message: transcript.Message,
    run_end: transcript.EndReason,
    compaction: CompactionSummary,
    /// Clones the trace record if it carries durable session meaning.
    ///
    /// Runtime-only records such as `turn_start`, `tool_start`, and `turn_end`
    /// return null because they describe execution progress, not conversation
    /// history.
    pub fn cloneFromTrace(
        allocator: std.mem.Allocator,
        record: Trace.Record,
    ) !?Entry {
        return switch (record) {
            .message_append => |message| .{ .message = try cloneMessageAppend(allocator, message) },
            .agent_end => |value| .{ .run_end = value.reason },
            .agent_start,
            .turn_start,
            .tool_start,
            .tool_end,
            .turn_end,
            .run_error,
            => null,
        };
    }

    /// Releases any payload owned by this session entry.
    /// Releases any payload owned by this session entry.
    pub fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        switch (self) {
            .message => |message| transcript.deinitMessage(message, allocator),
            .run_end => {},
            .compaction => |c| c.deinit(allocator),
        }
    }

    /// Returns an owned copy of this entry.
    pub fn clone(self: *const Entry, allocator: std.mem.Allocator) !Entry {
        return switch (self.*) {
            .message => |message| .{ .message = try transcript.cloneMessage(allocator, message) },
            .run_end => |reason| .{ .run_end = reason },
            .compaction => |c| .{ .compaction = try c.clone(allocator) },
        };
    }
};

fn cloneMessageAppend(
    allocator: std.mem.Allocator,
    message: Trace.MessageAppend,
) !transcript.Message {
    return switch (message) {
        .user => |value| transcript.cloneMessage(allocator, .{ .user = .{ .content = value.content } }),
        .assistant => |value| transcript.cloneMessage(allocator, .{ .assistant = .{
            .content = value.content,
            .tool_calls = value.tool_calls,
        } }),
        .tool_result => |value| transcript.cloneMessage(allocator, .{ .tool_result = .{
            .tool_call_id = value.tool_call_id,
            .content = value.content,
            .is_error = value.is_error,
        } }),
    };
}

/// Current-state projection derived from agent trace records.
///
/// `Trace` preserves the raw event stream. `State` is the small, mutable
/// projection that a TUI or RPC surface can render without understanding every
/// lifecycle event: whether the session is active, which turn is current, what
/// the latest assistant text is, and which tools are running or finished.
pub const State = struct {
    allocator: std.mem.Allocator,
    status: Status = .idle,
    current_turn_index: ?usize = null,
    message_count: usize = 0,
    latest_user_content: []const u8 = "",
    latest_assistant_content: []const u8 = "",
    end_reason: ?transcript.EndReason = null,
    tools: std.ArrayList(ToolRun) = .empty,

    /// Initializes a mutable projection for one active or replayed session.
    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator };
    }

    /// Releases all strings copied from trace records.
    pub fn deinit(self: *State) void {
        self.clear();
        self.tools.deinit(self.allocator);
    }

    /// Returns an owned copy suitable for transactional projection updates.
    ///
    /// `Session.emit` builds the next projection before committing an event to
    /// trace and history. Cloning keeps allocation failure from leaving the
    /// current projection half-updated.
    pub fn clone(self: *const State, allocator: std.mem.Allocator) !State {
        var out = State.init(allocator);
        errdefer out.deinit();
        out.status = self.status;
        out.current_turn_index = self.current_turn_index;
        out.message_count = self.message_count;
        out.latest_user_content = if (self.latest_user_content.len == 0) "" else try allocator.dupe(u8, self.latest_user_content);
        out.latest_assistant_content = if (self.latest_assistant_content.len == 0) "" else try allocator.dupe(u8, self.latest_assistant_content);
        out.end_reason = self.end_reason;
        try out.tools.ensureTotalCapacity(allocator, self.tools.items.len);
        for (self.tools.items) |item| {
            out.tools.appendAssumeCapacity(try item.clone(allocator));
        }
        return out;
    }
    /// Clears run state while keeping allocated list capacity for reuse.
    pub fn reset(self: *State) void {
        self.clear();
        self.status = .idle;
        self.current_turn_index = null;
        self.message_count = 0;
        self.end_reason = null;
    }

    /// Rebuilds this projection from a complete trace snapshot.
    ///
    /// This is the boundary used when UI code receives a trace from another
    /// worker: the projection owns its copied strings, so the source trace may
    /// be dropped or compacted after rebuilding.
    pub fn rebuild(self: *State, records: []const Trace.Record) !void {
        self.reset();
        for (records) |record| try self.apply(record);
    }

    /// Applies one trace record to the mutable projection.
    ///
    /// `State` intentionally reduces an append-only event stream into the
    /// latest status, latest user/assistant text, and per-tool status rows. It
    /// is therefore a derived view, not the authoritative session history.
    pub fn apply(self: *State, record: Trace.Record) !void {
        switch (record) {
            .agent_start => {
                self.reset();
                self.status = .running;
            },
            .turn_start => |value| {
                self.status = .running;
                self.current_turn_index = value.turn_index;
            },
            .message_append => |message| try self.applyMessage(message),
            .tool_start => |call| try self.startTool(call),
            .tool_end => |value| try self.endTool(value),
            .turn_end => |value| {
                self.current_turn_index = value.turn_index;
                try self.replaceString(&self.latest_assistant_content, value.assistant.content);
            },
            .run_error => {},
            .agent_end => |value| {
                self.message_count = value.message_count;
                self.end_reason = value.reason;
                self.status = .{ .ended = value.reason };
            },
        }
    }

    fn clear(self: *State) void {
        self.allocator.free(self.latest_user_content);
        self.latest_user_content = "";
        self.allocator.free(self.latest_assistant_content);
        self.latest_assistant_content = "";
        for (self.tools.items) |tool_run| tool_run.deinit(self.allocator);
        self.tools.clearRetainingCapacity();
    }

    fn applyMessage(self: *State, message: Trace.MessageAppend) !void {
        self.message_count += 1;
        switch (message) {
            .user => |value| try self.replaceString(&self.latest_user_content, value.content),
            .assistant => |value| try self.replaceString(&self.latest_assistant_content, value.content),
            .tool_result => |value| try self.applyToolResultMessage(value),
        }
    }

    fn applyToolResultMessage(self: *State, result: Trace.ToolResultMessage) !void {
        if (self.findTool(result.tool_call_id)) |item| {
            try item.replaceResult(self.allocator, result.content);
            item.status = if (result.is_error) .err else .ok;
        }
    }

    fn startTool(self: *State, call: Trace.ToolStart) !void {
        if (self.findTool(call.id)) |item| {
            try item.replaceStart(self.allocator, call);
            item.status = .running;
            item.control = .continue_run;
            return;
        }

        const item = try ToolRun.cloneStart(self.allocator, call);
        errdefer item.deinit(self.allocator);
        try self.tools.append(self.allocator, item);
    }

    fn endTool(self: *State, value: Trace.ToolEnd) !void {
        const item = self.findTool(value.call.id) orelse item: {
            const created = try ToolRun.cloneStart(self.allocator, value.call);
            errdefer created.deinit(self.allocator);
            try self.tools.append(self.allocator, created);
            break :item &self.tools.items[self.tools.items.len - 1];
        };

        try item.replaceResult(self.allocator, value.result.content);
        item.status = if (value.result.is_error) .err else .ok;
        item.control = value.result.control;
    }

    fn findTool(self: *State, id: []const u8) ?*ToolRun {
        for (self.tools.items) |*item| {
            if (std.mem.eql(u8, item.id, id)) return item;
        }
        return null;
    }

    fn replaceString(self: *State, target: *[]const u8, value: []const u8) !void {
        const owned = try self.allocator.dupe(u8, value);
        self.allocator.free(target.*);
        target.* = owned;
    }
};

pub const Status = union(enum) {
    idle,
    running,
    ended: transcript.EndReason,
};

pub const ToolStatus = enum {
    running,
    ok,
    err,
};

pub const ToolRun = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
    result_content: []const u8 = "",
    status: ToolStatus = .running,
    control: tool.Control = .continue_run,

    /// Clones the provider-requested call into projection-owned tool state.
    fn cloneStart(allocator: std.mem.Allocator, call: Trace.ToolStart) !ToolRun {
        const id = try allocator.dupe(u8, call.id);
        errdefer allocator.free(id);
        const name = try allocator.dupe(u8, call.name);
        errdefer allocator.free(name);
        const arguments = try allocator.dupe(u8, call.arguments);
        return .{
            .id = id,
            .name = name,
            .arguments = arguments,
        };
    }

    fn clone(self: ToolRun, allocator: std.mem.Allocator) !ToolRun {
        const id = try allocator.dupe(u8, self.id);
        errdefer allocator.free(id);
        const name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(name);
        const arguments = try allocator.dupe(u8, self.arguments);
        errdefer allocator.free(arguments);
        const result_content = if (self.result_content.len == 0) "" else try allocator.dupe(u8, self.result_content);
        return .{
            .id = id,
            .name = name,
            .arguments = arguments,
            .result_content = result_content,
            .status = self.status,
            .control = self.control,
        };
    }

    fn deinit(self: ToolRun, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.arguments);
        allocator.free(self.result_content);
    }

    fn replaceStart(self: *ToolRun, allocator: std.mem.Allocator, call: Trace.ToolStart) !void {
        const id = try allocator.dupe(u8, call.id);
        errdefer allocator.free(id);
        const name = try allocator.dupe(u8, call.name);
        errdefer allocator.free(name);
        const arguments = try allocator.dupe(u8, call.arguments);
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.arguments);
        self.id = id;
        self.name = name;
        self.arguments = arguments;
    }

    fn replaceResult(self: *ToolRun, allocator: std.mem.Allocator, content: []const u8) !void {
        const owned = try allocator.dupe(u8, content);
        allocator.free(self.result_content);
        self.result_content = owned;
    }
};

const testing = std.testing;

test "session records events and updates derived state" {
    var session = Session.init(testing.allocator);
    defer session.deinit();

    const event_sink = session.sink();
    try event_sink.emit(.agent_start);
    try event_sink.emit(.{ .turn_start = .{ .turn_index = 0 } });
    try event_sink.emit(.{ .message_append = .{ .user = .{ .content = "fix tests" } } });
    try event_sink.emit(.{ .message_append = .{ .assistant = .{
        .content = "I will inspect the failure.",
        .tool_calls = &.{.{ .id = "call_1", .name = "Bash" }},
    } } });
    try event_sink.emit(.{ .tool_start = .{
        .id = "call_1",
        .name = "Bash",
        .arguments = "{\"command\":\"zig test src/root.zig\"}",
    } });
    try event_sink.emit(.{ .tool_end = .{
        .call = .{
            .id = "call_1",
            .name = "Bash",
            .arguments = "{\"command\":\"zig test src/root.zig\"}",
        },
        .result = .{
            .content = "{\"status\":\"ok\",\"exit_code\":0}",
            .is_error = false,
            .control = .continue_run,
        },
    } });
    try event_sink.emit(.{ .agent_end = .{
        .reason = .complete,
        .message_count = 3,
    } });

    try testing.expectEqual(@as(usize, 7), session.trace.records.items.len);
    try testing.expectEqual(@as(usize, 3), session.history().len);
    try testing.expectEqualStrings("fix tests", session.history()[0].message.user.content);
    try testing.expectEqualStrings("call_1", session.history()[1].message.assistant.tool_calls[0].id);
    try testing.expectEqual(transcript.EndReason.complete, session.history()[2].run_end);
    try testing.expectEqualStrings("call_1", session.trace.records.items[3].message_append.assistant.tool_calls[0].id);
    try testing.expectEqual(Status{ .ended = .complete }, session.state.status);
    try testing.expectEqual(@as(usize, 0), session.state.current_turn_index.?);
    try testing.expectEqual(@as(usize, 3), session.state.message_count);
    try testing.expectEqualStrings("fix tests", session.state.latest_user_content);
    try testing.expectEqualStrings("I will inspect the failure.", session.state.latest_assistant_content);
    try testing.expectEqual(@as(usize, 1), session.state.tools.items.len);
    try testing.expectEqual(ToolStatus.ok, session.state.tools.items[0].status);
    try testing.expectEqualStrings("Bash", session.state.tools.items[0].name);
    try testing.expectEqualStrings("{\"status\":\"ok\",\"exit_code\":0}", session.state.tools.items[0].result_content);
    try testing.expectEqual(@as(u64, 7), session.revision);
}

test "session keeps multiple runs while current view follows latest run" {
    var session = Session.init(testing.allocator);
    defer session.deinit();

    const event_sink = session.sink();
    try event_sink.emit(.agent_start);
    try event_sink.emit(.{ .message_append = .{ .user = .{ .content = "first run" } } });
    try event_sink.emit(.{ .agent_end = .{
        .reason = .complete,
        .message_count = 1,
    } });
    try event_sink.emit(.agent_start);
    try event_sink.emit(.{ .message_append = .{ .user = .{ .content = "second run" } } });

    try testing.expectEqual(@as(usize, 2), session.runsView().len);
    try testing.expectEqualStrings("first run", session.runsView()[0].history()[0].message.user.content);
    try testing.expectEqual(transcript.EndReason.complete, session.runsView()[0].history()[1].run_end);
    try testing.expectEqual(@as(usize, 3), session.runsView()[0].trace.records.items.len);
    try testing.expectEqual(Trace.Record.agent_start, session.runsView()[0].trace.records.items[0]);
    try testing.expectEqualStrings("first run", session.runsView()[0].trace.records.items[1].message_append.user.content);
    try testing.expectEqualStrings("second run", session.runsView()[1].history()[0].message.user.content);
    try testing.expectEqual(@as(usize, 2), session.runsView()[1].trace.records.items.len);
    try testing.expectEqual(@as(usize, 2), session.trace.records.items.len);
    try testing.expectEqualStrings("second run", session.trace.records.items[1].message_append.user.content);
    try testing.expectEqualStrings("second run", session.history()[0].message.user.content);
    try testing.expectEqual(@as(usize, 1), session.history().len);
    try testing.expectEqual(@as(usize, 1), session.currentRun().?.index);
}

test "session rebuilds state from trace" {
    var session = Session.init(testing.allocator);
    defer session.deinit();

    const event_sink = session.sink();
    try event_sink.emit(.agent_start);
    try event_sink.emit(.{ .message_append = .{ .user = .{ .content = "read file" } } });

    session.state.reset();
    try session.rebuildState();

    try testing.expectEqualStrings("read file", session.state.latest_user_content);
    try testing.expectEqualStrings("read file", session.history()[0].message.user.content);
}

test "session entry keeps durable messages and run end only" {
    const assistant_record: Trace.Record = .{ .message_append = .{ .assistant = .{
        .content = "I will inspect it.",
        .tool_calls = &.{.{ .id = "call_1", .name = "Read", .arguments = "{\"path\":\"src/root.zig\"}" }},
    } } };
    const entry = (try Entry.cloneFromTrace(testing.allocator, assistant_record)).?;
    defer entry.deinit(testing.allocator);

    try testing.expectEqualStrings("call_1", entry.message.assistant.tool_calls[0].id);

    const runtime_record: Trace.Record = .{ .tool_start = .{
        .id = "call_1",
        .name = "Read",
        .arguments = "{\"path\":\"src/root.zig\"}",
    } };
    try testing.expectEqual(@as(?Entry, null), try Entry.cloneFromTrace(testing.allocator, runtime_record));
}

test "session state aggregates lifecycle records" {
    var state = State.init(testing.allocator);
    defer state.deinit();

    try state.apply(.agent_start);
    try state.apply(.{ .turn_start = .{ .turn_index = 0 } });
    try state.apply(.{ .message_append = .{ .user = .{ .content = "fix tests" } } });
    try state.apply(.{ .message_append = .{ .assistant = .{
        .content = "I will inspect the failure.",
        .tool_calls = &.{.{ .id = "call_1", .name = "Bash" }},
    } } });
    try state.apply(.{ .tool_start = .{
        .id = "call_1",
        .name = "Bash",
        .arguments = "{\"command\":\"zig test src/root.zig\"}",
    } });
    try state.apply(.{ .tool_end = .{
        .call = .{
            .id = "call_1",
            .name = "Bash",
            .arguments = "{\"command\":\"zig test src/root.zig\"}",
        },
        .result = .{
            .content = "{\"status\":\"ok\",\"exit_code\":0}",
            .is_error = false,
            .control = .continue_run,
        },
    } });
    try state.apply(.{ .agent_end = .{
        .reason = .complete,
        .message_count = 3,
    } });

    try testing.expectEqual(Status{ .ended = .complete }, state.status);
    try testing.expectEqual(@as(usize, 0), state.current_turn_index.?);
    try testing.expectEqual(@as(usize, 3), state.message_count);
    try testing.expectEqualStrings("fix tests", state.latest_user_content);
    try testing.expectEqualStrings("I will inspect the failure.", state.latest_assistant_content);
    try testing.expectEqual(@as(usize, 1), state.tools.items.len);
    try testing.expectEqual(ToolStatus.ok, state.tools.items[0].status);
    try testing.expectEqualStrings("Bash", state.tools.items[0].name);
    try testing.expectEqualStrings("{\"status\":\"ok\",\"exit_code\":0}", state.tools.items[0].result_content);
}

test "session state rebuild owns data independently of trace" {
    var trace = Trace.init(testing.allocator);
    defer trace.deinit();
    try trace.sink().emit(.agent_start);
    try trace.sink().emit(.{ .message_append = .{ .user = .{ .content = "read file" } } });

    var state = State.init(testing.allocator);
    defer state.deinit();
    try state.rebuild(trace.records.items);

    trace.deinit();
    trace = Trace.init(testing.allocator);

    try testing.expectEqual(Status.running, state.status);
    try testing.expectEqualStrings("read file", state.latest_user_content);
}

test "session state clone owns projected strings and tools" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    try state.apply(.agent_start);
    try state.apply(.{ .message_append = .{ .user = .{ .content = "fix tui" } } });
    try state.apply(.{ .tool_start = .{
        .id = "call_1",
        .name = "Read",
        .arguments = "{\"path\":\"src/client/tui/features/agent/root.zig\"}",
    } });

    var cloned = try state.clone(testing.allocator);
    defer cloned.deinit();
    state.reset();

    try testing.expectEqual(Status.running, cloned.status);
    try testing.expectEqualStrings("fix tui", cloned.latest_user_content);
    try testing.expectEqual(@as(usize, 1), cloned.tools.items.len);
    try testing.expectEqualStrings("Read", cloned.tools.items[0].name);
}
