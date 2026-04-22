-- One-time migration: add description column to prompts and context_files.
-- Run against existing databases. New deployments get the column from
-- CREATE TABLE IF NOT EXISTS in db.zig.
--
-- Usage:
--   docker compose exec -T postgres psql -U clumsies -d clumsies \
--     < scripts/dev/migrate-add-description.sql
--   (adjust user/database for your environment)

ALTER TABLE prompts ADD COLUMN IF NOT EXISTS description TEXT NOT NULL DEFAULT '';
ALTER TABLE context_files ADD COLUMN IF NOT EXISTS description TEXT NOT NULL DEFAULT '';

-- Backfill: remove heading line, then take the first non-empty line.
-- Uses POSIX ERE (no PCRE non-capturing groups).
UPDATE prompts
SET description = COALESCE(
    substring(
        regexp_replace(content, E'^#[^\n]*\n+', ''),
        E'^([^\n]+)'
    ),
    '')
WHERE description = '' AND content != '';

UPDATE context_files
SET description = COALESCE(
    substring(
        regexp_replace(content, E'^#[^\n]*\n+', ''),
        E'^([^\n]+)'
    ),
    '')
WHERE description = '' AND content != '';
