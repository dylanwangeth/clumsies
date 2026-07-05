---
name: activate
description: Activate available managed agent memory
argument-hint: "[kind/group/query filters]"
user-invocable: true
---
Call the `activate` MCP tool to activate candidate rules, workflows, and
context. This is the memory activation step, not a content load.

Use any user-provided arguments as filters (`kind`, `group`, or `query`) when
they are clear; otherwise call `activate` broadly.

$ARGUMENTS
