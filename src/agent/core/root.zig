//! Provider-neutral agent core contracts and runtime.
//!
//! Core modules define the loop, transcript, provider port, tool contract,
//! memory port, event types, and inference request assembler. Concrete provider
//! adapters, native workspace tool catalogs, UI policy, and persistence-backed
//! memory implementations live outside this directory.

pub const Assembler = @import("assembler.zig");
pub const event = @import("event.zig");
pub const loop = @import("loop.zig");
pub const Memory = @import("memory.zig");
pub const Provider = @import("provider.zig");
pub const tool = @import("tool.zig");
pub const Trace = @import("trace.zig");
pub const transcript = @import("transcript.zig");

test {
    _ = Assembler;
    _ = event;
    _ = loop;
    _ = Memory;
    _ = Provider;
    _ = tool;
    _ = Trace;
    _ = transcript;
}
