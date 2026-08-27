---
layout: home

hero:
  name: clumsies
  text: Collaborative external memory for coding agents
  tagline: Distribute project context and constraints, keep local drafts automatic, and publish changes through review.
  image:
    src: /logo.png
    alt: clumsies
  actions:
    - theme: brand
      text: Get Started
      link: /guides/how-to-use-clumsies
    - theme: alt
      text: Architecture
      link: /architecture

features:
  - icon: 🧠
    title: One Memory model
    details: Rules, workflows, and context are one Markdown-backed Organization Memory object with a semantic description and stable IDs; Projects select resources and carry private Draft overlays.
  - icon: 📝
    title: Automatic drafts
    details: Desktop and MCP write to the same always-on daemon; local changes synchronize without a manual push step.
  - icon: ✅
    title: Reviewed authority
    details: Project-carried Drafts become authoritative only through review and a Commit that advances the Organization Ref.
  - icon: 🗂️
    title: Agent-native Kanban
    details: Agents claim, pause, and propose closure of native Issues through typed kanban operations; only the user's Approve gate makes an Issue Done.
  - icon: 🔌
    title: Host adapters
    details: Codex, Claude Code, opencode, and the DeepSeek Harness share one App-bundled Rust runtime with release-identity checks.
  - icon: 🏠
    title: Self-hosted Server
    details: Run the Rust authority service and PostgreSQL in your own infrastructure with organization OIDC.
---
