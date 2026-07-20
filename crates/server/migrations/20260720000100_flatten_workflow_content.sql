CREATE EXTENSION IF NOT EXISTS pgcrypto;

WITH workflow_steps_markdown AS (
    SELECT
        resource_id,
        string_agg(
            step_order::text || '. ' || CASE
                WHEN rule_id IS NOT NULL THEN 'Apply rule `' || rule_id || '`.'
                ELSE COALESCE(body, '')
            END,
            E'\n' ORDER BY step_order
        ) AS content
    FROM workflow_steps
    GROUP BY resource_id
),
workflow_markdown AS (
    SELECT
        resource.resource_id,
        concat_ws(
            E'\n\n',
            '# ' || resource.name,
            NULLIF(resource.body, ''),
            NULLIF(workflow_steps_markdown.content, '')
        ) AS content
    FROM resources AS resource
    LEFT JOIN workflow_steps_markdown
        ON workflow_steps_markdown.resource_id = resource.resource_id
    WHERE resource.resource_kind = 'workflow'
)
UPDATE resources AS resource
SET
    body = workflow_markdown.content,
    content_hash = 'sha256:' || encode(digest(workflow_markdown.content, 'sha256'), 'hex'),
    revision = resource.revision + 1,
    updated_at = now()
FROM workflow_markdown
WHERE workflow_markdown.resource_id = resource.resource_id;

DROP TABLE workflow_steps;
