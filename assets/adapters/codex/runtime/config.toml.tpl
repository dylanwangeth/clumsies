[features]
codex_hooks = true

[mcp_servers.clumsies]
command = "clumsies"
args = ["mcp", "serve"]

[mcp_servers.clumsies.tools."memory.setup"]
approval_mode = "approve"

[mcp_servers.clumsies.tools."memory.discover"]
approval_mode = "approve"

[mcp_servers.clumsies.tools."memory.load"]
approval_mode = "approve"

[mcp_servers.clumsies.tools."memory.refer"]
approval_mode = "approve"

[mcp_servers.clumsies.tools."memory.submit"]
approval_mode = "approve"

[mcp_servers.clumsies.tools."memory.reject"]
approval_mode = "approve"

[mcp_servers.clumsies.tools."context.propose_create"]
approval_mode = "approve"

[mcp_servers.clumsies.tools."context.propose_update"]
approval_mode = "approve"

[mcp_servers.clumsies.tools."context.propose_rename"]
approval_mode = "approve"

[mcp_servers.clumsies.tools."context.propose_delete"]
approval_mode = "approve"

[mcp_servers.clumsies.tools."rule.propose_create"]
approval_mode = "approve"

[mcp_servers.clumsies.tools."rule.propose_update"]
approval_mode = "approve"

[mcp_servers.clumsies.tools."rule.propose_rename"]
approval_mode = "approve"

[mcp_servers.clumsies.tools."rule.propose_delete"]
approval_mode = "approve"
