//! MCP tool name constants (memory.setup/search/load/refer/submit). Shared by tools.zig (dispatch),
//! tool_result.zig (refer reminder text), and server.zig (instruction string) to keep tool
//! identity consistent across the protocol.
pub const setup = "memory.setup";
pub const search = "memory.search";
pub const load = "memory.load";
pub const refer = "memory.refer";
pub const submit = "memory.submit";
