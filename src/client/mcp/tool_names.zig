//! MCP tool name constants (memory.setup/search/load/refer/submit/reject,
//! context.propose_*/prompt.propose_*). Shared by tools.zig (dispatch),
//! tool_result.zig (refer reminder text), and server.zig (instruction string)
//! to keep tool identity consistent across the protocol.
pub const setup = "memory.setup";
pub const search = "memory.search";
pub const load = "memory.load";
pub const refer = "memory.refer";
pub const submit = "memory.submit";
pub const reject = "memory.reject";

pub const context_propose_create = "context.propose_create";
pub const context_propose_update = "context.propose_update";
pub const context_propose_rename = "context.propose_rename";
pub const context_propose_delete = "context.propose_delete";

pub const prompt_propose_create = "prompt.propose_create";
pub const prompt_propose_update = "prompt.propose_update";
pub const prompt_propose_rename = "prompt.propose_rename";
pub const prompt_propose_delete = "prompt.propose_delete";
