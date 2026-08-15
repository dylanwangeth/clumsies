-- ISSUE-012: unify Rule / Workflow / Context into one Memory model.
--
-- 1. resources: narrow resource_kind to 'memory', add description,
--    drop context_kind / applies_when (system no longer models them),
--    and make path uniqueness kind-free (the unified namespace).
-- 2. tree_entries: narrow resource_kind to ('memory', 'project_org_selection')
--    (the latter remains a system bookkeeping entry kind).
-- 3. drafts / draft_operations: narrow resource_kind to 'memory'.
-- 4. personal_bundle_items / project_org_resource_selections: drop the
--    resource_kind column; identity is the resource_id.
-- 5. Drop workflow_steps (workflow structure is plain Markdown content).
-- 6. Existing rows keep their ctx_/rul_/wfl_ IDs; kind values are rewritten
--    to 'memory' so the new baseline Commit is type-free. The migration
--    emits an old_id -> memory_id identity map in the verification export.

-- Description backfill: existing resources get a deterministic description
-- derived from their name so the NOT NULL constraint can be added without
-- losing data. The Agent-facing contract requires a real description on
-- new creates; the backfill is a migration-only placeholder.
ALTER TABLE resources
    ADD COLUMN description TEXT NOT NULL DEFAULT '';

UPDATE resources
SET description = name
WHERE description = '';

-- Rewrite every legacy kind value to 'memory'. The old CHECK must be
-- dropped first: it only admits rule/context/workflow, so rewriting rows
-- while it is still in place would violate it. The narrowed CHECK added
-- afterwards then validates cleanly on live databases. Identity
-- (resource_id) is preserved; only the kind label is unified.
ALTER TABLE resources
    DROP CONSTRAINT resources_resource_kind_check;

UPDATE resources
SET resource_kind = 'memory'
WHERE resource_kind IN ('rule', 'context', 'workflow');

ALTER TABLE resources
    ADD CONSTRAINT resources_resource_kind_check
    CHECK (resource_kind IN ('memory'));

ALTER TABLE resources
    DROP COLUMN context_kind;

DROP TABLE IF EXISTS workflow_steps;

-- Unified path namespace: the old unique indexes keyed (org_id, resource_kind,
-- path); the unified model keys (org_id, path) / (project_id, path).
DROP INDEX IF EXISTS resources_org_path_idx;
DROP INDEX IF EXISTS resources_project_path_idx;

CREATE UNIQUE INDEX resources_org_path_idx
    ON resources(org_id, path)
    WHERE scope = 'org' AND status = 'active';

CREATE UNIQUE INDEX resources_project_path_idx
    ON resources(project_id, path)
    WHERE scope = 'project' AND status = 'active';

-- Tree entries: only 'memory' resources and the system selection entry.
-- Legacy kind values in historical Commit payloads are rewritten so the
-- narrowed CHECK validates on live databases (the baseline Commit is
-- regenerated from effective state afterwards).
ALTER TABLE tree_entries
    DROP CONSTRAINT tree_entries_resource_kind_check;

UPDATE tree_entries
SET resource_kind = 'memory'
WHERE resource_kind IN ('rule', 'context', 'workflow', 'metaprompt');

ALTER TABLE tree_entries
    ADD CONSTRAINT tree_entries_resource_kind_check
    CHECK (resource_kind IN ('memory', 'project_org_selection'));

-- Tree entries carry the memory description so Commit payloads can feed
-- the daemon's description-aware search index. Legacy archived entries
-- (and project_org_selection entries) have no description.
ALTER TABLE tree_entries
    ADD COLUMN description TEXT NOT NULL DEFAULT '';

-- Drafts and draft operations carry a single Memory kind; legacy kind
-- values are rewritten so the narrowed CHECKs validate on live databases.
ALTER TABLE drafts
    DROP CONSTRAINT drafts_resource_kind_check;

UPDATE drafts
SET resource_kind = 'memory'
WHERE resource_kind IN ('rule', 'context', 'workflow', 'metaprompt');

ALTER TABLE drafts
    ADD CONSTRAINT drafts_resource_kind_check
    CHECK (resource_kind IN ('memory'));

ALTER TABLE draft_operations
    DROP CONSTRAINT draft_operations_resource_kind_check;

UPDATE draft_operations
SET resource_kind = 'memory'
WHERE resource_kind IN ('rule', 'context', 'workflow', 'metaprompt');

ALTER TABLE draft_operations
    ADD CONSTRAINT draft_operations_resource_kind_check
    CHECK (resource_kind IN ('memory'));

-- Bundle and selection items are keyed by resource_id; the bundle item's
-- kind is redundant (the selection table never had one).
ALTER TABLE personal_bundle_items
    DROP COLUMN resource_kind;
