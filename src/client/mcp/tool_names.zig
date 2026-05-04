//! MCP tool name constants. Shared by tools.zig (dispatch),
//! tool_result.zig (refer reminder text), and server.zig (instruction string)
//! to keep tool identity consistent across the protocol.
pub const setup = "memsetup";
pub const discover = "memdisc";
pub const load = "memload";
pub const refer = "memref";
pub const submit = "agentreport";
pub const reject = "agentrejected";

pub const artifact = "artifact";
