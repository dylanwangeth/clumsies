//! Concrete provider adapters for the agent runtime.

pub const OpenAICompatible = @import("openai_compatible.zig");

test {
    _ = OpenAICompatible;
}
