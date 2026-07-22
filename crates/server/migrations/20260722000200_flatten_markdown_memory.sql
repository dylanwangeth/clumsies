CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Rule and Workflow bodies are complete Markdown documents. Remove their old
-- JSON envelopes from historical Trees while preserving Commit topology.
CREATE FUNCTION pg_temp.render_legacy_rule(
    content JSONB,
    fallback_name TEXT,
    fallback_applies_when TEXT,
    fallback_tags TEXT[]
) RETURNS TEXT
LANGUAGE SQL
IMMUTABLE
AS $function$
    WITH fields AS (
        SELECT
            CASE
                WHEN NULLIF(btrim(content->>'name'), '') IS NOT NULL
                    THEN content->>'name'
                WHEN NULLIF(btrim(fallback_name), '') IS NOT NULL
                    THEN fallback_name
                ELSE 'Rule'
            END AS name,
            COALESCE(content->>'applies_when', fallback_applies_when, '') AS applies_when,
            content->>'constraint' AS rule_body,
            CASE
                WHEN jsonb_typeof(content->'tags') = 'array' THEN content->'tags'
                ELSE to_jsonb(COALESCE(fallback_tags, '{}'::TEXT[]))
            END AS tags
    ), rendered AS (
        SELECT
            fields.*,
            (
                SELECT string_agg(tag.value, ', ' ORDER BY tag.ordinality)
                FROM jsonb_array_elements_text(fields.tags)
                    WITH ORDINALITY AS tag(value, ordinality)
            ) AS tags_text
        FROM fields
    )
    SELECT concat_ws(
        E'\n\n',
        '# ' || name,
        '## Applies when',
        applies_when,
        '## Constraint',
        rule_body,
        'Tags: ' || COALESCE(tags_text, 'None')
    )
    FROM rendered
$function$;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM tree_entries AS entry
        JOIN blobs AS blob ON blob.blob_id = entry.blob_id
        WHERE entry.resource_kind = 'rule'
          AND blob.content NOT LIKE '{"format":"clumsies.rule.v1"%'
    ) THEN
        RAISE EXCEPTION 'Rule Blob is not encoded as clumsies.rule.v1';
    END IF;
END
$$;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM tree_entries AS entry
        JOIN blobs AS blob ON blob.blob_id = entry.blob_id
        WHERE entry.resource_kind = 'rule'
          -- The planner may inspect joined non-Rule rows before applying the
          -- resource_kind predicate. Guard the cast inside CASE so ordinary
          -- Markdown Blobs can never be parsed as JSON.
          AND CASE
              WHEN blob.content LIKE '{"format":"clumsies.rule.v1"%'
                  THEN NULLIF(
                      btrim(blob.content::jsonb #>> '{content,constraint}'),
                      ''
                  ) IS NULL
              ELSE FALSE
          END
    ) THEN
        RAISE EXCEPTION 'Rule Blob has an empty Markdown body';
    END IF;
END
$$;

CREATE TEMP TABLE markdown_blob_map (
    old_blob_id TEXT NOT NULL,
    resource_kind TEXT NOT NULL,
    new_blob_id TEXT NOT NULL,
    markdown TEXT NOT NULL,
    PRIMARY KEY (old_blob_id, resource_kind)
) ON COMMIT DROP;

WITH markdown_content AS (
    SELECT DISTINCT
        blob.blob_id AS old_blob_id,
        entry.resource_kind,
        CASE
            WHEN entry.resource_kind = 'rule'
             AND blob.content LIKE '{"format":"clumsies.rule.v1"%'
            THEN pg_temp.render_legacy_rule(
                blob.content::jsonb->'content',
                NULL,
                NULL,
                NULL
            )
            WHEN entry.resource_kind = 'workflow'
             AND blob.content LIKE '{"format":"clumsies.workflow.v1"%'
            THEN concat_ws(
                E'\n\n',
                CASE
                    WHEN NULLIF(blob.content::jsonb #>> '{content,name}', '') IS NOT NULL
                        THEN '# ' || (blob.content::jsonb #>> '{content,name}')
                END,
                NULLIF(blob.content::jsonb #>> '{content,description}', ''),
                NULLIF((
                    SELECT string_agg(
                        COALESCE(
                            NULLIF(step.value->>'order', ''),
                            step.ordinality::text
                        ) || '. ' || CASE
                            WHEN NULLIF(step.value->>'rule_id', '') IS NOT NULL
                                THEN 'Apply rule `' || (step.value->>'rule_id') || '`.'
                            ELSE COALESCE(step.value->>'body', '')
                        END,
                        E'\n' ORDER BY step.ordinality
                    )
                    FROM jsonb_array_elements(
                        COALESCE(blob.content::jsonb #> '{content,steps}', '[]'::jsonb)
                    ) WITH ORDINALITY AS step(value, ordinality)
                ), '')
            )
        END AS markdown
    FROM tree_entries AS entry
    JOIN blobs AS blob ON blob.blob_id = entry.blob_id
    WHERE entry.resource_kind = 'rule'
       OR (
           entry.resource_kind = 'workflow'
           AND blob.content LIKE '{"format":"clumsies.workflow.v1"%'
       )
)
INSERT INTO markdown_blob_map (old_blob_id, resource_kind, new_blob_id, markdown)
SELECT
    old_blob_id,
    resource_kind,
    encode(
        digest(
            convert_to('blob', 'UTF8')
            || decode('00', 'hex')
            || convert_to(markdown, 'UTF8'),
            'sha256'
        ),
        'hex'
    ),
    markdown
FROM markdown_content;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM markdown_blob_map WHERE NULLIF(btrim(markdown), '') IS NULL
    ) THEN
        RAISE EXCEPTION 'structured memory Blob has an empty Markdown body';
    END IF;
END
$$;

INSERT INTO blobs (blob_id, content)
SELECT DISTINCT new_blob_id, markdown
FROM markdown_blob_map
ON CONFLICT DO NOTHING;

CREATE TEMP TABLE markdown_tree_map (
    old_tree_id TEXT PRIMARY KEY,
    new_tree_id TEXT NOT NULL
) ON COMMIT DROP;

WITH mapped_entries AS (
    SELECT
        entry.tree_id,
        entry.item_id,
        entry.resource_kind,
        entry.scope,
        entry.project_id,
        entry.path,
        COALESCE(blob_map.new_blob_id, entry.blob_id) AS blob_id,
        entry.source
    FROM tree_entries AS entry
    LEFT JOIN markdown_blob_map AS blob_map
        ON blob_map.old_blob_id = entry.blob_id
       AND blob_map.resource_kind = entry.resource_kind
    WHERE EXISTS (
        SELECT 1
        FROM tree_entries AS candidate
        JOIN markdown_blob_map AS candidate_blob
            ON candidate_blob.old_blob_id = candidate.blob_id
           AND candidate_blob.resource_kind = candidate.resource_kind
        WHERE candidate.tree_id = entry.tree_id
    )
),
serialized_trees AS (
    SELECT
        entry.tree_id AS old_tree_id,
        '[' || string_agg(
            '{"item_id":' || to_json(entry.item_id)::text
            || ',"resource_kind":' || to_json(entry.resource_kind)::text
            || ',"scope":' || to_json(entry.scope)::text
            || ',"project_id":' || COALESCE(to_json(entry.project_id)::text, 'null')
            || ',"path":' || COALESCE(to_json(entry.path)::text, 'null')
            || ',"blob_id":' || to_json(entry.blob_id)::text
            || ',"source":' || to_json(entry.source)::text
            || '}',
            ',' ORDER BY entry.resource_kind, entry.path NULLS LAST, entry.item_id
        ) || ']' AS encoded
    FROM mapped_entries AS entry
    GROUP BY entry.tree_id
)
INSERT INTO markdown_tree_map (old_tree_id, new_tree_id)
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
FROM markdown_tree_map
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
    COALESCE(blob_map.new_blob_id, entry.blob_id),
    entry.source
FROM markdown_tree_map AS tree_map
JOIN tree_entries AS entry ON entry.tree_id = tree_map.old_tree_id
LEFT JOIN markdown_blob_map AS blob_map
    ON blob_map.old_blob_id = entry.blob_id
   AND blob_map.resource_kind = entry.resource_kind
ON CONFLICT DO NOTHING;

CREATE TEMP TABLE markdown_commit_candidates (
    commit_id TEXT PRIMARY KEY
) ON COMMIT DROP;

WITH RECURSIVE affected_commits AS (
    SELECT commit.commit_id
    FROM commits AS commit
    JOIN markdown_tree_map AS tree_map ON tree_map.old_tree_id = commit.tree_id

    UNION

    SELECT child.commit_id
    FROM commits AS child
    JOIN affected_commits AS parent ON parent.commit_id = child.parent_commit_id
)
INSERT INTO markdown_commit_candidates (commit_id)
SELECT commit_id FROM affected_commits;

CREATE TEMP TABLE markdown_commit_map (
    old_commit_id TEXT PRIMARY KEY,
    new_commit_id TEXT NOT NULL
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
            JOIN markdown_commit_candidates AS affected
                ON affected.commit_id = commit.commit_id
            LEFT JOIN markdown_commit_map AS mapped
                ON mapped.old_commit_id = commit.commit_id
            WHERE mapped.old_commit_id IS NULL
            ORDER BY commit.scope, commit.project_id NULLS FIRST, commit.version, commit.created_at
        LOOP
            IF candidate.parent_commit_id IS NOT NULL
               AND EXISTS (
                   SELECT 1
                   FROM markdown_commit_candidates
                   WHERE commit_id = candidate.parent_commit_id
               )
               AND NOT EXISTS (
                   SELECT 1
                   FROM markdown_commit_map
                   WHERE old_commit_id = candidate.parent_commit_id
               ) THEN
                CONTINUE;
            END IF;

            SELECT mapped.new_commit_id
            INTO new_parent_commit_id
            FROM markdown_commit_map AS mapped
            WHERE mapped.old_commit_id = candidate.parent_commit_id;
            new_parent_commit_id := COALESCE(new_parent_commit_id, candidate.parent_commit_id);

            SELECT tree_map.new_tree_id
            INTO new_tree_id
            FROM markdown_tree_map AS tree_map
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
            ) ON CONFLICT DO NOTHING;

            INSERT INTO markdown_commit_map (old_commit_id, new_commit_id)
            VALUES (candidate.commit_id, new_commit_id);
            inserted_count := inserted_count + 1;
        END LOOP;

        EXIT WHEN inserted_count = 0;
    END LOOP;

    IF EXISTS (
        SELECT 1
        FROM markdown_commit_candidates AS remaining_candidate
        LEFT JOIN markdown_commit_map AS mapped
            ON mapped.old_commit_id = remaining_candidate.commit_id
        WHERE mapped.old_commit_id IS NULL
    ) THEN
        RAISE EXCEPTION 'failed to rewrite every structured memory Commit';
    END IF;
END
$$;

UPDATE refs AS reference
SET commit_id = commit_map.new_commit_id
FROM markdown_commit_map AS commit_map
WHERE reference.commit_id = commit_map.old_commit_id;

UPDATE drafts AS draft
SET base_commit_id = commit_map.new_commit_id
FROM markdown_commit_map AS commit_map
WHERE draft.base_commit_id = commit_map.old_commit_id;

UPDATE review_merges AS review_merge
SET commit_id = commit_map.new_commit_id
FROM markdown_commit_map AS commit_map
WHERE review_merge.commit_id = commit_map.old_commit_id;

UPDATE draft_conflicts AS conflict
SET base_commit_id = commit_map.new_commit_id
FROM markdown_commit_map AS commit_map
WHERE conflict.base_commit_id = commit_map.old_commit_id;

UPDATE draft_conflicts AS conflict
SET current_commit_id = commit_map.new_commit_id
FROM markdown_commit_map AS commit_map
WHERE conflict.current_commit_id = commit_map.old_commit_id;

DO $$
DECLARE
    deleted_count INTEGER;
BEGIN
    LOOP
        DELETE FROM commits AS commit
        USING markdown_commit_map AS commit_map
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
        JOIN markdown_commit_map AS commit_map
            ON commit_map.old_commit_id = commit.commit_id
    ) THEN
        RAISE EXCEPTION 'failed to remove rewritten structured memory Commit chain';
    END IF;
END
$$;

DELETE FROM trees AS tree
USING markdown_tree_map AS tree_map
WHERE tree.tree_id = tree_map.old_tree_id
  AND NOT EXISTS (
      SELECT 1 FROM commits AS commit WHERE commit.tree_id = tree.tree_id
  );

WITH legacy_rule_operations AS (
    SELECT
        operation.operation_id,
        pg_temp.render_legacy_rule(
            operation.content,
            COALESCE(
                resource.name,
                regexp_replace(
                    regexp_replace(COALESCE(operation.path, draft.path, 'Rule'), '^.*/', ''),
                    '\.[^.]*$',
                    ''
                )
            ),
            resource.applies_when,
            resource.tags
        ) AS content
    FROM draft_operations AS operation
    JOIN drafts AS draft ON draft.draft_id = operation.draft_id
    LEFT JOIN resources AS resource
        ON resource.resource_id = COALESCE(operation.target_id, draft.target_id)
    WHERE operation.resource_kind = 'rule'
      AND operation.content->>'kind' = 'rule'
      AND operation.content ? 'constraint'
)
UPDATE draft_operations AS operation
SET content = jsonb_build_object('kind', 'rule', 'content', legacy.content)
FROM legacy_rule_operations AS legacy
WHERE legacy.operation_id = operation.operation_id;

WITH rule_markdown AS (
    SELECT
        resource.resource_id,
        pg_temp.render_legacy_rule(
            jsonb_build_object(
                'name', resource.name,
                'applies_when', resource.applies_when,
                'constraint', resource.body,
                'tags', to_jsonb(resource.tags)
            ),
            NULL,
            NULL,
            NULL
        ) AS content
    FROM resources AS resource
    WHERE resource.resource_kind = 'rule'
)
UPDATE resources AS resource
SET
    body = rule_markdown.content,
    content_hash = 'sha256:' || encode(digest(rule_markdown.content, 'sha256'), 'hex'),
    revision = resource.revision + 1,
    updated_at = now()
FROM rule_markdown
WHERE rule_markdown.resource_id = resource.resource_id;

ALTER TABLE resources DROP COLUMN applies_when;
ALTER TABLE resources DROP COLUMN tags;

DELETE FROM blobs AS blob
USING markdown_blob_map AS blob_map
WHERE blob.blob_id = blob_map.old_blob_id
  AND NOT EXISTS (
      SELECT 1 FROM tree_entries AS entry WHERE entry.blob_id = blob.blob_id
  );
