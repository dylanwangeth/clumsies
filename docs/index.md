---
layout: home

hero:
  name: clumsies
  text: Collaborative external memory for coding agents
  tagline: Distribute project context and constraints, keep local drafts automatic, and publish changes through review.
  actions:
    - theme: brand
      text: Get Started
      link: /guides/how-to-use-clumsies
    - theme: alt
      text: Architecture
      link: /architecture

features:
  - title: One Memory model
    details: Rules, workflows, and context are a single Markdown-backed Memory object with a semantic description and stable IDs, in organization or project scope.
  - title: Automatic drafts
    details: Desktop and MCP write to the same always-on daemon; local changes synchronize without a manual push step.
  - title: Reviewed authority
    details: Drafts become authoritative only through review and a Commit that advances the organization or project Ref.
  - title: Agent-native Kanban
    details: Agents claim, pause, and propose closure of native Issues through typed kanban operations; only the user's Approve gate makes an Issue Done.
  - title: Host adapters
    details: Codex, Claude Code, opencode, and the DeepSeek Harness share one App-bundled Rust runtime with release-identity checks.
  - title: Self-hosted Server
    details: Run the Rust authority service and PostgreSQL in your own infrastructure with organization OIDC.
---
