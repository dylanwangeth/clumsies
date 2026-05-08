[features]
hooks = true

[mcp_servers.clumsies]
command = "clumsies"
args = ["mcp", "serve"]

[mcp_servers.clumsies.tools."memsetup"]
approval_mode = "approve"

[mcp_servers.clumsies.tools."memdisc"]
approval_mode = "approve"

[mcp_servers.clumsies.tools."memload"]
approval_mode = "approve"

[mcp_servers.clumsies.tools."memref"]
approval_mode = "approve"

[mcp_servers.clumsies.tools."agentreport"]
approval_mode = "approve"

[mcp_servers.clumsies.tools."agentrejected"]
approval_mode = "approve"

[mcp_servers.clumsies.tools."artifact"]
approval_mode = "approve"
