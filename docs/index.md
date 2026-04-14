---
layout: home

hero:
  name: clumsies
  text: turn prompts into organizational infrastructure
  tagline: Library, Workspace, and Trace define how prompts are created, consumed, and improved across teams.
  actions:
    - theme: brand
      text: Start with the Overview
      link: /overview
    - theme: alt
      text: Read the Architecture
      link: /architecture

features:
  - title: Library
    details: The organization-level source of prompts, bundles, and proposal flow starts here.
  - title: Workspace
    details: This is where a project binds prompt selection, local context, override, and sync into real work.
  - title: Trace
    details: Reference data is not decoration. It is the signal that turns prompt iteration from instinct into evidence.
---

<div class="home-ledger">
  <div class="home-ledger-row">
    <span class="home-ledger-key">Docs writer</span>
    <span class="home-ledger-value">Codex ChatGPT 5.4</span>
  </div>
  <div class="home-ledger-row">
    <span class="home-ledger-key">Implementation nudges</span>
    <span class="home-ledger-value">lilhammerfun</span>
  </div>
  <div class="home-ledger-row">
    <span class="home-ledger-key">Primary repo</span>
    <span class="home-ledger-value">clumsies</span>
  </div>
  <div class="home-ledger-row">
    <span class="home-ledger-key">Core objects</span>
    <span class="home-ledger-value">library / workspace / trace</span>
  </div>
</div>

<div class="home-terminal">
  <div class="home-terminal-chrome">
    <div class="home-terminal-lights">
      <span class="home-terminal-dot is-red"></span>
      <span class="home-terminal-dot is-yellow"></span>
      <span class="home-terminal-dot is-green"></span>
    </div>
    <div class="home-terminal-title">ghostty</div>
  </div>
  <div class="home-terminal-body">
    <div class="home-terminal-line is-command">
      <span class="home-terminal-host">lilhammerfun@longde</span>
      <span class="home-terminal-path">~/src/clumsies</span>
      <span class="home-terminal-prompt">%</span>
      <span class="home-terminal-text">clumsies login -u lilhammerfun</span>
    </div>
    <div class="home-terminal-line is-output">
      <span class="home-terminal-output is-dim">Password:</span>
    </div>
    <div class="home-terminal-line is-output">
      <span class="home-terminal-output is-success"><span class="home-terminal-token is-green">Logged in</span> as <span class="home-terminal-token is-cyan">lilhammerfun</span></span>
    </div>
    <div class="home-terminal-line is-command">
      <span class="home-terminal-host">lilhammerfun@longde</span>
      <span class="home-terminal-path">~/src/clumsies</span>
      <span class="home-terminal-prompt">%</span>
      <span class="home-terminal-text">clumsies init --create clumsies-docs</span>
    </div>
    <div class="home-terminal-line is-output">
      <span class="home-terminal-output is-success">Workspace clumsies-docs bound to current directory (ws_id: ws-0f6a12ce83db4a7fb2d4e9aa38e1b6c2)</span>
    </div>
    <div class="home-terminal-line is-command">
      <span class="home-terminal-host">lilhammerfun@longde</span>
      <span class="home-terminal-path">~/src/clumsies</span>
      <span class="home-terminal-prompt">%</span>
      <span class="home-terminal-text">clumsies sync</span>
    </div>
    <div class="home-terminal-line is-output">
      <span class="home-terminal-output is-success">Synced: 24 prompts, 6 context files</span>
    </div>
    <div class="home-terminal-line is-command">
      <span class="home-terminal-host">lilhammerfun@longde</span>
      <span class="home-terminal-path">~/src/clumsies</span>
      <span class="home-terminal-prompt">%</span>
      <span class="home-terminal-text">clumsies</span>
    </div>
    <div class="home-terminal-line is-output">
      <span class="home-terminal-output"><span class="home-terminal-token is-orange">clumsies</span> 0.18.0-alpha</span>
    </div>
    <div class="home-terminal-line is-output">
      <span class="home-terminal-output">TUI Dashboard is not yet available.</span>
    </div>
    <div class="home-terminal-line is-output">
      <span class="home-terminal-output"><span class="home-terminal-token is-orange">clumsies</span> - Prompt + context management for AI agents</span>
    </div>
    <div class="home-terminal-line is-output">
      <span class="home-terminal-output"><span class="home-terminal-token is-orange">Usage:</span></span>
    </div>
    <div class="home-terminal-line is-output">
      <span class="home-terminal-output">    <span class="home-terminal-token is-cyan">clumsies</span>            Launch TUI Dashboard</span>
    </div>
    <div class="home-terminal-line is-output">
      <span class="home-terminal-output">    <span class="home-terminal-token is-cyan">clumsies login</span>      Authenticate with Hub</span>
    </div>
    <div class="home-terminal-line is-output">
      <span class="home-terminal-output">    <span class="home-terminal-token is-cyan">clumsies init</span>       Bind workspace to current directory</span>
    </div>
    <div class="home-terminal-line is-output">
      <span class="home-terminal-output">    <span class="home-terminal-token is-cyan">clumsies sync</span>       Sync local cache from Hub</span>
    </div>
    <div class="home-terminal-line is-output">
      <span class="home-terminal-output">    <span class="home-terminal-token is-cyan">clumsies mcp serve</span>  Start MCP server for AI agents</span>
    </div>
    <div class="home-terminal-line is-output">
      <span class="home-terminal-output is-dim">Run clumsies &lt;command&gt; -h for details.</span>
    </div>
    <div class="home-terminal-line is-command is-idle">
      <span class="home-terminal-host">lilhammerfun@longde</span>
      <span class="home-terminal-path">~/src/clumsies</span>
      <span class="home-terminal-prompt">%</span>
      <span class="home-terminal-cursor"></span>
    </div>
  </div>
</div>

<div class="home-strip">
  <span class="home-strip-label">objects</span>
  <span>library</span>
  <span>workspace</span>
  <span>trace</span>
  <span>context</span>
  <span>override</span>
</div>
