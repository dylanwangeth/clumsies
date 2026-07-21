[features]
hooks = true

[mcp_servers.clumsies]
command = "clumsies"
args = ["mcp", "serve"]

[mcp_servers.clumsies.tools."activate"]
approval_mode = "approve"

[mcp_servers.clumsies.tools."load"]
approval_mode = "approve"

[mcp_servers.clumsies.tools."store"]
approval_mode = "approve"
