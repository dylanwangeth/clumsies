//! MCP tool name constants (memory.setup/discover/load/refer/submit/reject,
//! context.propose_*/rule.propose_*). Shared by tools.zig (dispatch),
//! tool_result.zig (refer reminder text), and server.zig (instruction string)
//! to keep tool identity consistent across the protocol.
pub const setup = "memory.setup";
pub const discover = "memory.discover";
pub const load = "memory.load";
pub const refer = "memory.refer";
pub const submit = "memory.submit";
pub const reject = "memory.reject";

pub const context_propose_create = "context.propose_create";
pub const context_propose_update = "context.propose_update";
pub const context_propose_rename = "context.propose_rename";
pub const context_propose_delete = "context.propose_delete";

pub const rule_propose_create = "rule.propose_create";
pub const rule_propose_update = "rule.propose_update";
pub const rule_propose_rename = "rule.propose_rename";
pub const rule_propose_delete = "rule.propose_delete";
