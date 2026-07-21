# Reference

Reference is for lookup, not for first-pass reading.

Use this part of the docs when you already understand the system shape and need an exact term, path, or protocol detail without rereading the narrative pages.

## When to use reference

| If you need to answer | Read |
| --- | --- |
| what a project term means right now | [Glossary](/glossary) |
| which local files clumsies writes | [Runtime surfaces](/runtime) |
| how login, token refresh, and local credential storage work | [Auth and sessions](/reference/auth) |
| which MCP tools are part of the current implementation | [MCP](/mcp) |
| which commands and flags exist today | [CLI reference](/guides/cli-commands) |
| which directories in the repository own which responsibilities | [Codebase map](/repos) |

## What belongs here

Reference pages should do one of two jobs.

First, they can stabilize terminology. That is the role of [Glossary](/glossary). It exists so the rest of the docs do not need to keep redefining `rule`, `project`, `Commit`, `Draft`, or `adapter`.

Second, they can answer exact lookup questions that are easy to forget but expensive to rediscover in code. Runtime paths, MCP tool names, and command flags belong in that class of material.

Reference should not try to mirror the whole docs site. If a page only repeats the main navigation or recommended reading order, it is noise rather than reference.
