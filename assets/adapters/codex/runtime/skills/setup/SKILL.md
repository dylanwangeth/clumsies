---
name: setup
description: Load and follow the clumsies setup protocol to re-import META_PROMPT
metadata:
  short-description: Re-import META_PROMPT
---
Call the `retrieve` MCP tool with the Codex session id from the
SessionStart hook context once for the current host session:

```json
{
  "session_id": "<session_id>",
  "knownHashes": {
    "META_PROMPT.md": "<remembered_hash_or_empty_string>"
  }
}
```

If the hook context is unavailable, first read `CODEX_THREAD_ID` from the
shell environment and use that exact value as `session_id`.

Use an empty string when you do not know the current META_PROMPT hash. If you
already remember the last returned `mpf.hash`, pass it so retrieve can return
`changed:false` without re-sending META_PROMPT content.

Read the returned `mpf.content` field carefully when present — it is the
META_PROMPT that governs how you interact with the clumsies constraint system.

After setup succeeds, reuse the bound session for later clumsies MCP calls in
the same host session. Briefly summarize the key protocol rules (activate →
retrieve → store cycle and the priority model) to confirm the bootstrap
succeeded.
