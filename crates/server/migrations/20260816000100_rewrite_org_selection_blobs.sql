-- ISSUE-012 follow-up: rewrite historical org-selection Blobs to the unified
-- Memory shape.
--
-- The unify migration (20260815000100) narrowed kind CHECKs, added the
-- description column and rewrote kind labels, but historical Commit payloads
-- still store the project org selection in the legacy shape:
--
--     {project_id, rules: [{rule_id, ...}], context: [{context_id, kind,
--      size, ...}], workflows: [{workflow_id, ...}], revision}
--
-- New Server code deserializes every Commit payload into the unified
-- ProjectOrgSelection {project_id, memories: [MemoryMeta], revision}, so
-- reading an archived Commit fails with "missing field 'memories'". This
-- migration rewrites those Blobs once, in place: identity is preserved
-- (rule_id/context_id/workflow_id -> memory_id), the obsolete context
-- kind/size keys are dropped, and description is backfilled from the
-- resources table exactly like the unify migration backfilled it from name.
--
-- Idempotent: only Blobs that still lack a 'memories' key are rewritten,
-- and only Blobs referenced as org-selection tree entries are touched.

UPDATE blobs
SET content = rewritten.content
FROM (
    SELECT
        b.blob_id,
        jsonb_build_object(
            'project_id', parsed -> 'project_id',
            'revision', parsed -> 'revision',
            'memories', COALESCE(merged.memories, '[]'::jsonb)
        )::text AS content
    FROM blobs b
    CROSS JOIN LATERAL (SELECT b.content::jsonb AS parsed) p
    CROSS JOIN LATERAL (
        SELECT jsonb_agg(
            jsonb_build_object(
                'memory_id', item -> id_key,
                'scope', item -> 'scope',
                'project_id', item -> 'project_id',
                'path', item -> 'path',
                'name', item -> 'name',
                'description', COALESCE(
                    (SELECT description
                     FROM resources r
                     WHERE r.resource_id = item ->> id_key),
                    item ->> 'name',
                    ''
                ),
                'content_hash', item -> 'content_hash',
                'status', item -> 'status',
                'updated_at', item -> 'updated_at'
            )
            ORDER BY item ->> id_key
        ) AS memories
        FROM (
            SELECT value AS item,
                   CASE
                       WHEN value ? 'rule_id' THEN 'rule_id'
                       WHEN value ? 'context_id' THEN 'context_id'
                       WHEN value ? 'workflow_id' THEN 'workflow_id'
                   END AS id_key
            FROM jsonb_array_elements(
                COALESCE(parsed -> 'rules', '[]'::jsonb)
                    || COALESCE(parsed -> 'context', '[]'::jsonb)
                    || COALESCE(parsed -> 'workflows', '[]'::jsonb)
            ) AS items(value)
        ) legacy_items
        WHERE id_key IS NOT NULL
    ) merged
    WHERE NOT parsed ? 'memories'
) rewritten
WHERE blobs.blob_id = rewritten.blob_id
  AND blobs.blob_id IN (
      SELECT blob_id FROM tree_entries WHERE resource_kind = 'project_org_selection'
  );
