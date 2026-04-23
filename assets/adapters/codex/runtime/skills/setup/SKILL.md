---
name: setup
description: Load and follow the clumsies setup protocol to re-import META_PROMPT
metadata:
  short-description: Re-import META_PROMPT
---
Call the `memory.setup` MCP tool to bootstrap the protocol. Read the returned `mpf.content` field carefully — it is the META_PROMPT that governs how you interact with the clumsies constraint system.

After loading, briefly summarize the key protocol rules (search → load → refer → submit cycle and the priority model) to confirm the bootstrap succeeded.
