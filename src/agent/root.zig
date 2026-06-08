//! Agent runtime primitives shared by future CLI, TUI, and adapter surfaces.

pub const core = @import("core/root.zig");
pub const providers = @import("providers/root.zig");
pub const tools = @import("tools/root.zig");

pub const Assembler = core.Assembler;
pub const event = core.event;
pub const loop = core.loop;
pub const Memory = core.Memory;
pub const Provider = core.Provider;
pub const Session = core.Session;
pub const SessionEntry = Session.Entry;
pub const SessionState = Session.State;
pub const tool = core.tool;
pub const Trace = core.Trace;
pub const session_persistence = core.session_persistence;
pub const runtime_log = core.runtime_log;
pub const transcript = core.transcript;

test {
    _ = core;
    _ = Assembler;
    _ = event;
    _ = loop;
    _ = Memory;
    _ = Provider;
    _ = Session;
    _ = SessionEntry;
    _ = SessionState;
    _ = providers;
    _ = tools;
    _ = tool;
    _ = Trace;
    _ = transcript;
    _ = session_persistence;
    _ = providers;
}