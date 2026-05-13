---
layout: home

hero:
  name: clumsies
  text: persistent, observable, collaborative
  tagline: Building the context infrastructure that coexists with agents' self-managed memory.
  actions:
    - theme: brand
      text: Get Started
      link: /guides/how-to-use-clumsies
    - theme: alt
      text: Architecture
      link: /architecture
---

<div class="home-hero-shell">
  <div class="home-hero-field" aria-hidden="true">
    <span class="home-hero-ring is-large"></span>
    <span class="home-hero-ring is-medium"></span>
    <span class="home-hero-ring is-small"></span>
    <span class="home-hero-beam"></span>
    <span class="home-hero-noise"></span>
  </div>
  <div class="home-terminal">
    <div class="home-terminal-chrome">
      <div class="home-terminal-lights">
        <span class="home-terminal-dot is-red"></span>
        <span class="home-terminal-dot is-yellow"></span>
        <span class="home-terminal-dot is-green"></span>
      </div>
    </div>
    <div class="home-terminal-body">
      <div class="home-terminal-meta">Last login: Wed Apr 22 21:18:11 on ttys003</div>
      <div class="home-terminal-line is-command">
        <span class="home-terminal-host">lilhammer@longde</span>
        <span class="home-terminal-path">clumsies</span>
        <span class="home-terminal-prompt">%</span>
        <span class="home-terminal-text">clumsies -h</span>
      </div>
      <div class="home-terminal-line is-output">
        <span class="home-terminal-output"><span class="home-terminal-token is-orange">clumsies</span> - Building the persistent, observable, and collaborative context infrastructure that coexists with agents' self-managed memory.</span>
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
        <span class="home-terminal-output">    <span class="home-terminal-token is-cyan">clumsies sync</span>         Sync local cache from Hub</span>
      </div>
      <div class="home-terminal-line is-output">
        <span class="home-terminal-output">    <span class="home-terminal-token is-cyan">clumsies adapt</span>        Install, update, remove, or list agent adapters</span>
      </div>
      <div class="home-terminal-line is-output">
        <span class="home-terminal-output">    <span class="home-terminal-token is-cyan">clumsies hub</span>          Start Hub server</span>
      </div>
      <div class="home-terminal-line is-output">
        <span class="home-terminal-output">    <span class="home-terminal-token is-cyan">clumsies mcp serve</span>    Start MCP server for AI agents</span>
      </div>
      <div class="home-terminal-line is-output">
        <span class="home-terminal-output is-dim">Run clumsies &lt;command&gt; -h for details.</span>
      </div>
      <div class="home-terminal-line is-command">
        <span class="home-terminal-host">lilhammer@longde</span>
        <span class="home-terminal-path">clumsies</span>
        <span class="home-terminal-prompt">%</span>
        <span class="home-terminal-text">clumsies login --hub-url localhost:8400 -u lilhammer</span>
      </div>
      <div class="home-terminal-line is-output">
        <span class="home-terminal-output is-dim">Password:</span>
      </div>
      <div class="home-terminal-line is-output">
        <span class="home-terminal-output is-success">Logged in as <span class="home-terminal-token is-cyan">admin</span></span>
      </div>
      <div class="home-terminal-line is-command">
        <span class="home-terminal-host">lilhammer@longde</span>
        <span class="home-terminal-path">clumsies</span>
        <span class="home-terminal-prompt">%</span>
        <span class="home-terminal-text">clumsies adapt --agent codex --scope workspace --yes</span>
      </div>
      <div class="home-terminal-line is-output">
        <span class="home-terminal-output"><span class="home-terminal-token is-orange">Workspace setup</span></span>
      </div>
      <div class="home-terminal-line is-output">
        <span class="home-terminal-output is-success">  Workspace "clumsiesws" bound to current directory (ws_id: ws-0f6a12ce83db4a7fb2d4e9aa38e1b6c2)</span>
      </div>
      <div class="home-terminal-line is-output">
        <span class="home-terminal-output is-success">  Synced: 0 rules, 0 context files into local cache</span>
      </div>
      <div class="home-terminal-line is-output">
        <span class="home-terminal-output"><span class="home-terminal-token is-orange">Clumsies Adapt</span></span>
      </div>
      <div class="home-terminal-line is-output">
        <span class="home-terminal-output">Agent: <span class="home-terminal-token is-cyan">Codex</span></span>
      </div>
      <div class="home-terminal-line is-output">
        <span class="home-terminal-output">Target: <span class="home-terminal-token is-cyan">Workspace (/Users/lilhammer/workspace/clumsies/.codex)</span></span>
      </div>
      <div class="home-terminal-line is-output">
        <span class="home-terminal-output">Mode: <span class="home-terminal-token is-cyan">install</span></span>
      </div>
      <div class="home-terminal-line is-output">
        <span class="home-terminal-output is-success">Clumsies adapted Codex. Wrote 10 file(s), left 0 unchanged.</span>
      </div>
      <div class="home-terminal-line is-command is-idle">
        <span class="home-terminal-host">lilhammer@longde</span>
        <span class="home-terminal-path">clumsies</span>
        <span class="home-terminal-prompt">%</span>
        <span class="home-terminal-text home-terminal-disclaimer">echo "draft docs by Codex, not authored by lilhammer"</span><span class="home-terminal-cursor"></span>
      </div>
    </div>
  </div>
</div>
