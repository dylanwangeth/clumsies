ALTER TABLE review_comments
    ADD COLUMN review_version BIGINT;

UPDATE review_comments
SET anchor_path = NULL, anchor_line = NULL
WHERE (anchor_path IS NULL) <> (anchor_line IS NULL)
   OR anchor_line < 1;

UPDATE review_comments AS comment
SET review_version = review.version
FROM reviews AS review
WHERE review.review_id = comment.review_id;

ALTER TABLE review_comments
    ALTER COLUMN review_version SET NOT NULL,
    ADD CONSTRAINT review_comments_review_version_positive CHECK (review_version > 0),
    ADD CONSTRAINT review_comments_anchor_pair
        CHECK ((anchor_path IS NULL) = (anchor_line IS NULL)),
    ADD CONSTRAINT review_comments_anchor_line_positive
        CHECK (anchor_line IS NULL OR anchor_line > 0);

-- Decision actors are audit data. Users are disabled rather than hard-deleted, so
-- RESTRICT keeps the human attribution intact instead of silently orphaning it.
ALTER TABLE reviews
    ADD COLUMN decided_by_user_id TEXT REFERENCES users(user_id) ON DELETE RESTRICT,
    ADD COLUMN decided_at TIMESTAMPTZ;

ALTER TABLE reviews
    ADD CONSTRAINT reviews_decision_metadata_pair
    CHECK ((decided_by_user_id IS NULL) = (decided_at IS NULL));
