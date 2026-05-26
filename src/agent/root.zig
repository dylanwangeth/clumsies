//! Agent runtime primitives shared by future CLI, TUI, and adapter surfaces.

pub const event = @import("event.zig");
pub const loop = @import("loop.zig");
pub const Provider = @import("provider.zig");
pub const providers = @import("providers/root.zig");
pub const tool = @import("tool.zig");
pub const transcript = @import("transcript.zig");

test {
    _ = event;
    _ = loop;
    _ = Provider;
    _ = providers;
    _ = tool;
    _ = transcript;
}
