# Archived Zig CLI

The standalone `clumsies` CLI is not an active product or runtime surface. Its
source is preserved under `archive/zig-cli/` for historical reference and is
not built, tested, packaged, installed, or released.

Current human workflows use the macOS Desktop. Supported Agent hosts are wired
by native Project Management to the App-bundled Rust runtime:

```text
clumsiesd mcp serve
clumsiesd _agent issue-run-event --host <host>
```

These are adapter-managed proxy modes, not a replacement general-purpose CLI.
See [Agent runtime](/guides/agent-runtime) and [Adapter](/adapter).
