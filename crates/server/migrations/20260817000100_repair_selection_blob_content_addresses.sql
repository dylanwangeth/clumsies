-- Repair content-address integrity for org-selection Blobs rewritten in place
-- by 20260816000100_rewrite_org_selection_blobs.sql.
--
-- That migration changed Blob CONTENT (legacy -> unified Memory shape) while
-- preserving blob_id. blob_id is a git-style content address
-- (sha256("blob" || 0x00 || content)); the daemon rejects any Commit payload
-- containing a Blob whose content does not hash to its id (content-address
-- verification), which blocked Commit sync and Project Ref installation for
-- every project with a legacy selection (ISSUE-062).
--
-- This migration repairs the addressing without rewriting ids of Trees or
-- Commits: for every Blob whose content does not match its blob_id it inserts
-- the correctly-addressed row (same content, correct id) and re-points all
-- tree_entries to the new id. Payloads are reconstructed from tree_entries +
-- blobs at read time, and neither the server nor the daemon re-verifies
-- tree/commit hash identity, so all existing Tree/Commit/Ref ids stay valid.
--
-- Idempotent: mismatched rows are detected by hashing, so a second run is a
-- no-op. Old broken rows are kept (no longer referenced) for auditability.

INSERT INTO blobs (blob_id, content)
SELECT new_id, content
FROM (
    SELECT blob_id AS old_id,
           encode(sha256(convert_to('blob', 'UTF8') || decode('00', 'hex') || convert_to(content, 'UTF8')), 'hex') AS new_id,
           content
    FROM blobs
) broken
WHERE new_id <> old_id
ON CONFLICT (blob_id) DO NOTHING;

UPDATE tree_entries e
SET blob_id = broken.new_id
FROM (
    SELECT blob_id AS old_id,
           encode(sha256(convert_to('blob', 'UTF8') || decode('00', 'hex') || convert_to(content, 'UTF8')), 'hex') AS new_id
    FROM blobs
) broken
WHERE e.blob_id = broken.old_id
  AND broken.new_id <> broken.old_id;
