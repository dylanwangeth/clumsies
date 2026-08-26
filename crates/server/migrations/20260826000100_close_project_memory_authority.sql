-- Project remains the carrier for local Draft overlays and keeps its Ref for
-- selected Organization Memory. It is no longer a Memory authority scope.
--
-- NOT VALID preserves historical rows while immediately rejecting new or
-- updated active Project authority. The explicit migration command archives
-- the remaining resources, discards active legacy Drafts, and then validates
-- both constraints.
ALTER TABLE resources
    ADD CONSTRAINT resources_no_active_project_authority
    CHECK (scope <> 'project' OR status <> 'active') NOT VALID;

ALTER TABLE drafts
    ADD CONSTRAINT drafts_no_active_project_authority
    CHECK (
        resource_scope <> 'project'
        OR status NOT IN ('open', 'submitted')
    ) NOT VALID;
