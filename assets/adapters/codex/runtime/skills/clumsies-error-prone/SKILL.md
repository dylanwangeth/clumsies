---
name: clumsies-error-prone
description: Load and follow the CLUMSIES_ERROR_PRONE workflow
argument-hint: "[pitfall description]"
user-invocable: true
---

Call the `memload` MCP tool with ids: ["workflow:CLUMSIES_ERROR_PRONE"] and
knownHashes: {"workflow:CLUMSIES_ERROR_PRONE": "<remembered_hash_or_empty_string>"}.
Use the last hash you remember for this workflow when available; otherwise use
an empty string. If memload returns changed:false without content, continue from
the workflow content you already remember. Then follow the loaded workflow
carefully.

$ARGUMENTS
