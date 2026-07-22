CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Metaprompt was an obsolete MCP bootstrap protocol, not an authoritative
-- memory resource. Rewrite every affected Commit chain instead of mutating an
-- existing content-addressed Tree in place.
CREATE TEMP TABLE metaprompt_tree_map (
    old_tree_id TEXT PRIMARY KEY,
    new_tree_id TEXT NOT NULL
) ON COMMIT DROP;

WITH serialized_trees AS (
    SELECT
        entry.tree_id AS old_tree_id,
        '[' || COALESCE(
            string_agg(
                '{"item_id":' || to_json(entry.item_id)::text
                || ',"resource_kind":' || to_json(entry.resource_kind)::text
                || ',"scope":' || to_json(entry.scope)::text
                || ',"project_id":' || COALESCE(to_json(entry.project_id)::text, 'null')
                || ',"path":' || COALESCE(to_json(entry.path)::text, 'null')
                || ',"blob_id":' || to_json(entry.blob_id)::text
                || ',"source":' || to_json(entry.source)::text
                || '}',
                ',' ORDER BY entry.resource_kind, entry.path NULLS LAST, entry.item_id
            ) FILTER (WHERE entry.resource_kind <> 'metaprompt'),
            ''
        ) || ']' AS encoded
    FROM tree_entries AS entry
    WHERE EXISTS (
        SELECT 1
        FROM tree_entries AS candidate
        WHERE candidate.tree_id = entry.tree_id
          AND candidate.resource_kind = 'metaprompt'
    )
    GROUP BY entry.tree_id
)
INSERT INTO metaprompt_tree_map (old_tree_id, new_tree_id)
SELECT
    old_tree_id,
    encode(
        digest(
            convert_to('tree', 'UTF8') || decode('00', 'hex') || convert_to(encoded, 'UTF8'),
            'sha256'
        ),
        'hex'
    )
FROM serialized_trees;

INSERT INTO trees (tree_id)
SELECT DISTINCT new_tree_id
FROM metaprompt_tree_map
ON CONFLICT DO NOTHING;

INSERT INTO tree_entries (
    tree_id, item_id, resource_kind, scope, project_id, path, blob_id, source
)
SELECT
    tree_map.new_tree_id,
    entry.item_id,
    entry.resource_kind,
    entry.scope,
    entry.project_id,
    entry.path,
    entry.blob_id,
    entry.source
FROM metaprompt_tree_map AS tree_map
JOIN tree_entries AS entry ON entry.tree_id = tree_map.old_tree_id
WHERE entry.resource_kind <> 'metaprompt'
ON CONFLICT DO NOTHING;

CREATE TEMP TABLE metaprompt_commit_candidates (
    commit_id TEXT PRIMARY KEY
) ON COMMIT DROP;

WITH RECURSIVE affected_commits AS (
    SELECT commit.commit_id
    FROM commits AS commit
    JOIN metaprompt_tree_map AS tree_map ON tree_map.old_tree_id = commit.tree_id

    UNION

    SELECT child.commit_id
    FROM commits AS child
    JOIN affected_commits AS parent ON parent.commit_id = child.parent_commit_id
)
INSERT INTO metaprompt_commit_candidates (commit_id)
SELECT commit_id FROM affected_commits;

CREATE TEMP TABLE metaprompt_commit_map (
    old_commit_id TEXT PRIMARY KEY,
    new_commit_id TEXT NOT NULL UNIQUE
) ON COMMIT DROP;

DO $$
DECLARE
    candidate RECORD;
    new_parent_commit_id TEXT;
    new_tree_id TEXT;
    encoded_commit TEXT;
    new_commit_id TEXT;
    created_at_nanos BIGINT;
    inserted_count INTEGER;
BEGIN
    LOOP
        inserted_count := 0;

        FOR candidate IN
            SELECT commit.*
            FROM commits AS commit
            JOIN metaprompt_commit_candidates AS affected
                ON affected.commit_id = commit.commit_id
            LEFT JOIN metaprompt_commit_map AS mapped
                ON mapped.old_commit_id = commit.commit_id
            WHERE mapped.old_commit_id IS NULL
            ORDER BY commit.scope, commit.project_id NULLS FIRST, commit.version, commit.created_at
        LOOP
            IF candidate.parent_commit_id IS NOT NULL
               AND EXISTS (
                   SELECT 1
                   FROM metaprompt_commit_candidates
                   WHERE commit_id = candidate.parent_commit_id
               )
               AND NOT EXISTS (
                   SELECT 1
                   FROM metaprompt_commit_map
                   WHERE old_commit_id = candidate.parent_commit_id
               ) THEN
                CONTINUE;
            END IF;

            SELECT mapped.new_commit_id
            INTO new_parent_commit_id
            FROM metaprompt_commit_map AS mapped
            WHERE mapped.old_commit_id = candidate.parent_commit_id;
            new_parent_commit_id := COALESCE(new_parent_commit_id, candidate.parent_commit_id);

            SELECT tree_map.new_tree_id
            INTO new_tree_id
            FROM metaprompt_tree_map AS tree_map
            WHERE tree_map.old_tree_id = candidate.tree_id;
            new_tree_id := COALESCE(new_tree_id, candidate.tree_id);

            created_at_nanos := (extract(epoch FROM candidate.created_at) * 1000000000)::bigint;
            encoded_commit := '['
                || to_json(candidate.scope)::text || ','
                || to_json(candidate.org_id)::text || ','
                || COALESCE(to_json(candidate.project_id)::text, 'null') || ','
                || to_json(new_tree_id)::text || ','
                || COALESCE(to_json(new_parent_commit_id)::text, 'null') || ','
                || candidate.version::text || ','
                || created_at_nanos::text
                || ']';
            new_commit_id := encode(
                digest(
                    convert_to('commit', 'UTF8')
                    || decode('00', 'hex')
                    || convert_to(encoded_commit, 'UTF8'),
                    'sha256'
                ),
                'hex'
            );

            INSERT INTO commits (
                commit_id, scope, org_id, project_id, tree_id,
                parent_commit_id, version, created_at
            ) VALUES (
                new_commit_id,
                candidate.scope,
                candidate.org_id,
                candidate.project_id,
                new_tree_id,
                new_parent_commit_id,
                candidate.version,
                candidate.created_at
            );

            INSERT INTO metaprompt_commit_map (old_commit_id, new_commit_id)
            VALUES (candidate.commit_id, new_commit_id);
            inserted_count := inserted_count + 1;
        END LOOP;

        EXIT WHEN inserted_count = 0;
    END LOOP;

    IF EXISTS (
        SELECT 1
        FROM metaprompt_commit_candidates AS remaining_candidate
        LEFT JOIN metaprompt_commit_map AS mapped
            ON mapped.old_commit_id = remaining_candidate.commit_id
        WHERE mapped.old_commit_id IS NULL
    ) THEN
        RAISE EXCEPTION 'failed to rewrite every Metaprompt Commit';
    END IF;
END
$$;

UPDATE refs AS reference
SET commit_id = commit_map.new_commit_id
FROM metaprompt_commit_map AS commit_map
WHERE reference.commit_id = commit_map.old_commit_id;

UPDATE drafts AS draft
SET base_commit_id = commit_map.new_commit_id
FROM metaprompt_commit_map AS commit_map
WHERE draft.base_commit_id = commit_map.old_commit_id;

UPDATE review_merges AS review_merge
SET commit_id = commit_map.new_commit_id
FROM metaprompt_commit_map AS commit_map
WHERE review_merge.commit_id = commit_map.old_commit_id;

UPDATE draft_conflicts AS conflict
SET base_commit_id = commit_map.new_commit_id
FROM metaprompt_commit_map AS commit_map
WHERE conflict.base_commit_id = commit_map.old_commit_id;

UPDATE draft_conflicts AS conflict
SET current_commit_id = commit_map.new_commit_id
FROM metaprompt_commit_map AS commit_map
WHERE conflict.current_commit_id = commit_map.old_commit_id;

DO $$
DECLARE
    deleted_count INTEGER;
BEGIN
    LOOP
        DELETE FROM commits AS commit
        USING metaprompt_commit_map AS commit_map
        WHERE commit.commit_id = commit_map.old_commit_id
          AND NOT EXISTS (
              SELECT 1
              FROM commits AS child
              WHERE child.parent_commit_id = commit.commit_id
          );
        GET DIAGNOSTICS deleted_count = ROW_COUNT;
        EXIT WHEN deleted_count = 0;
    END LOOP;

    IF EXISTS (
        SELECT 1
        FROM commits AS commit
        JOIN metaprompt_commit_map AS commit_map
            ON commit_map.old_commit_id = commit.commit_id
    ) THEN
        RAISE EXCEPTION 'failed to remove rewritten Metaprompt Commit chain';
    END IF;
END
$$;

CREATE TEMP TABLE metaprompt_blob_ids (
    blob_id TEXT PRIMARY KEY
) ON COMMIT DROP;

INSERT INTO metaprompt_blob_ids (blob_id)
SELECT DISTINCT entry.blob_id
FROM tree_entries AS entry
WHERE entry.resource_kind = 'metaprompt';

DELETE FROM trees AS tree
USING metaprompt_tree_map AS tree_map
WHERE tree.tree_id = tree_map.old_tree_id
  AND NOT EXISTS (
      SELECT 1 FROM commits AS commit WHERE commit.tree_id = tree.tree_id
  );

CREATE TEMP TABLE metaprompt_draft_ids (
    draft_id TEXT PRIMARY KEY
) ON COMMIT DROP;

INSERT INTO metaprompt_draft_ids (draft_id)
SELECT draft_id FROM drafts WHERE resource_kind = 'metaprompt';

DELETE FROM review_comments AS comment
USING reviews AS review, metaprompt_draft_ids AS metaprompt_draft
WHERE comment.review_id = review.review_id
  AND review.draft_id = metaprompt_draft.draft_id;

DELETE FROM review_merges AS review_merge
USING reviews AS review, metaprompt_draft_ids AS metaprompt_draft
WHERE review_merge.review_id = review.review_id
  AND review.draft_id = metaprompt_draft.draft_id;

DELETE FROM reviews AS review
USING metaprompt_draft_ids AS metaprompt_draft
WHERE review.draft_id = metaprompt_draft.draft_id;

DELETE FROM draft_conflicts AS conflict
USING metaprompt_draft_ids AS metaprompt_draft
WHERE conflict.draft_id = metaprompt_draft.draft_id;

DELETE FROM draft_events AS event
USING metaprompt_draft_ids AS metaprompt_draft
WHERE event.draft_id = metaprompt_draft.draft_id;

DELETE FROM draft_operations AS operation
USING metaprompt_draft_ids AS metaprompt_draft
WHERE operation.draft_id = metaprompt_draft.draft_id;

DELETE FROM drafts AS draft
USING metaprompt_draft_ids AS metaprompt_draft
WHERE draft.draft_id = metaprompt_draft.draft_id;

ALTER TABLE drafts DROP CONSTRAINT drafts_resource_kind_check;
ALTER TABLE drafts ADD CONSTRAINT drafts_resource_kind_check
    CHECK (resource_kind IN ('rule', 'context', 'workflow'));

ALTER TABLE draft_operations DROP CONSTRAINT draft_operations_resource_kind_check;
ALTER TABLE draft_operations ADD CONSTRAINT draft_operations_resource_kind_check
    CHECK (resource_kind IN ('rule', 'context', 'workflow'));

ALTER TABLE tree_entries DROP CONSTRAINT tree_entries_resource_kind_check;
ALTER TABLE tree_entries ADD CONSTRAINT tree_entries_resource_kind_check
    CHECK (resource_kind IN ('rule', 'context', 'workflow', 'project_org_selection'));

DROP TABLE metaprompts;

DELETE FROM blobs AS blob
USING metaprompt_blob_ids AS metaprompt_blob
WHERE blob.blob_id = metaprompt_blob.blob_id
  AND NOT EXISTS (
    SELECT 1 FROM tree_entries AS entry WHERE entry.blob_id = blob.blob_id
  );
