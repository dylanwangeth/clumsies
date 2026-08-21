CREATE TABLE review_drafts (
    review_id TEXT NOT NULL REFERENCES reviews(review_id) ON DELETE CASCADE,
    draft_id TEXT NOT NULL UNIQUE REFERENCES drafts(draft_id) ON DELETE RESTRICT,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    PRIMARY KEY (review_id, draft_id),
    UNIQUE (review_id, ordinal)
);

INSERT INTO review_drafts (review_id, draft_id, ordinal)
SELECT review_id, draft_id, 0
FROM reviews;
