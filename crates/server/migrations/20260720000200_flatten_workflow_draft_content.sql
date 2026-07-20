WITH workflow_draft_markdown AS (
    SELECT
        operation.operation_id,
        concat_ws(
            E'\n\n',
            CASE
                WHEN NULLIF(operation.content->>'name', '') IS NOT NULL
                    THEN '# ' || (operation.content->>'name')
            END,
            NULLIF(operation.content->>'description', ''),
            NULLIF((
                SELECT string_agg(
                    step.ordinality::text || '. ' || CASE
                        WHEN NULLIF(step.value->>'rule_id', '') IS NOT NULL
                            THEN 'Apply rule `' || (step.value->>'rule_id') || '`.'
                        ELSE COALESCE(step.value->>'body', '')
                    END,
                    E'\n' ORDER BY step.ordinality
                )
                FROM jsonb_array_elements(
                    COALESCE(operation.content->'steps', '[]'::jsonb)
                ) WITH ORDINALITY AS step(value, ordinality)
            ), '')
        ) AS content
    FROM draft_operations AS operation
    WHERE operation.resource_kind = 'workflow'
      AND operation.content->>'kind' = 'workflow'
      AND operation.content ? 'steps'
)
UPDATE draft_operations AS operation
SET content = jsonb_build_object(
    'kind', 'workflow',
    'content', workflow_draft_markdown.content
)
FROM workflow_draft_markdown
WHERE workflow_draft_markdown.operation_id = operation.operation_id;
