# Archived Zig client

This directory preserves the former standalone Zig `clumsies` CLI, TUI, MCP
server, Agent hook bridge, and direct Adapter installer as historical source.
It is **not an active product surface**.

Source snapshot provenance: last active code commit
`809e7955412cc62194c94bbabab43c9f960926f0`, reported version
`0.19.2-alpha`. The final Adapter output topology was established in
`d3224b` and its final Claude SessionStart asset in `81b3fac`; those exact
outputs, rather than the broad `adapter-install/v1` label, define the narrow
native import generation.

The active Agent runtime is the signed Rust `clumsiesd` executable in the
macOS app. Agent hosts start short-lived `clumsiesd mcp serve` or
`clumsiesd _agent issue-run-event ...` proxy processes; those proxies use the
resident daemon over typed XPC. The native daemon Adapter is the sole writer
of supported host integrations.

## Deliberate archive boundary

- Nothing in this directory is built by the repository root, CI, release
  workflows, or the macOS app.
- No active Adapter, hook resolver, or installation script may fall back to an
  archived binary, `zig-out/bin/clumsies`, `PATH`, or `~/.clumsies/bin/clumsies`.
- The archived `build.zig` and installer retain their original relative-path
  assumptions. They are intentionally not maintained or supported in place.
- Existing copies of the old executable are not deleted from user machines,
  but new App-managed integrations must not reference them.
- The active Rust daemon may inspect bounded `adapter-install/v1` manifests to
  surface a review-and-reinstall warning. It does not adopt those manifests as
  native ownership or mutate their host entries. This advisory inspection is
  best-effort and cannot block App-owned integration reconciliation. Historical
  `repo` scope is reported as unsupported; user-wide installs require manual
  removal of global entries followed by per-repository App installation. This
  archive is never read or executed at runtime.

## Restoring this code

Do not selectively copy an archived command back into production. A future
restoration requires an explicit product decision and a dedicated migration:

1. move `build.zig`, `build.zig.zon`, `src/`, both installers (`install.sh`
   and `dev/install-cli-macos.sh`), and the complete archived
   `assets/adapters/` snapshot back to their active repository locations (the
   archived build still imports all 13 Adapter templates and skill files);
2. reconcile the MCP schemas, Hook normalization/privacy rules, typed daemon
   IPC, release identity, and Adapter ownership with the current Rust runtime;
3. add cross-runtime parity and stale-process rejection tests;
4. deliberately restore CI, signing, packaging, release, and documentation
   surfaces; and
5. provide an atomic migration and rollback path for every supported host.

Git history remains the authority for why individual files changed. This
snapshot exists only to make the retired implementation discoverable without
making it look supported.
