//! MCP tool name constants. Shared by tools.zig (dispatch),
//! tool_result.zig (refer reminder text), and server.zig (instruction string)
//! to keep tool identity consistent across the protocol.
pub const setup = "memory.setup";
pub const discover = "memory.discover";
pub const load = "memory.load";
pub const refer = "memory.refer";
pub const submit = "memory.submit";
pub const reject = "memory.reject";

pub const artifact = "artifact";
