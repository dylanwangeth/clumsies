---
name: setup
description: Bootstrap the clumsies protocol and re-import META_PROMPT
user-invocable: true
---
Call the `memsetup` MCP tool once for the current host session to bootstrap
the protocol. Pass the exact host session id and an explicit META_PROMPT hash
entry:

```json
{
  "session_id": "<session_id>",
  "knownHashes": {
    "META_PROMPT.md": "<remembered_hash_or_empty_string>"
  }
}
```

Use an empty string when you do not know the current META_PROMPT hash. If you
already remember the last returned `mpf.hash`, pass it so setup can return
`changed:false` without re-sending META_PROMPT content.

Read the returned `mpf.content` field carefully when present — it is the
META_PROMPT that governs how you interact with the clumsies constraint system.

After loading, briefly summarize the key protocol rules (search → load → refer → submit cycle and the priority model) to confirm the bootstrap succeeded.
