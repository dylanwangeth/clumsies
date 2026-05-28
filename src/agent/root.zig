//! Agent runtime primitives shared by future CLI, TUI, and adapter surfaces.

pub const core = @import("core/root.zig");
pub const providers = @import("providers/root.zig");
pub const tools = @import("tools/root.zig");

pub const Assembler = core.Assembler;
pub const event = core.event;
pub const loop = core.loop;
pub const Memory = core.Memory;
pub const Provider = core.Provider;
pub const tool = core.tool;
pub const transcript = core.transcript;

test {
    _ = core;
    _ = Assembler;
    _ = event;
    _ = loop;
    _ = Memory;
    _ = Provider;
    _ = providers;
    _ = tools;
    _ = tool;
    _ = transcript;
}
