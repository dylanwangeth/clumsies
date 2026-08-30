# Engineering documentation

This site is the versioned source of truth for the current clumsies architecture and engineering decisions. Documentation describes the implementation in the same revision; plans and known gaps are labeled explicitly.

## Authority boundary

- `docs/` owns current product, architecture, runtime, data, and operational documentation.
- Code, schemas, migrations, tests, and deployment configuration are the final evidence when prose and implementation disagree.
- Memory stores reusable working rules and procedures, not a second copy of the system design.
- Historical material is evidence, not the current contract.

## Documentation map

- [Architecture](/architecture) explains boundaries and data flow.
- [Unified Memory model](/unified-memory-model) defines authority, overlays, and publication.
- [Runtime](/runtime), [Server](/server), and [MCP](/mcp) describe execution boundaries.
- [Retrieval and evaluation](/retrieval-evaluation) defines search evidence.
- [Performance and validation](/performance/) records methods, experiments, and dated results.

## Update and publication

Material architecture changes update the affected document in the same pull request. State facts, decisions, constraints, failure modes, and a repeatable verification path. Before publication, build the site, check links, and verify English routes stay under `/` while Chinese routes stay under `/zh/`.
