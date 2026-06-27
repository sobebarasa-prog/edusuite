-- ══════════════════════════════════════════════════════════════════════════════
-- JSMS PORTAL — SUPABASE SETUP SCRIPT  V29
-- Junior School Management System — Kopiya / Atiaket Junior School
--
-- HOW TO RUN:
--   Supabase Dashboard → SQL Editor → paste this entire file → Run
--   Safe to re-run at any time: every statement uses IF NOT EXISTS / OR REPLACE.
--
-- WHAT THIS CREATES:
--   1. Table     : school_data          (one row per section per school)
--   2. RLS       : Row Level Security   (enabled; anon key allowed via policies)
--   3. Function  : jsms_push_school_data  (SECURITY DEFINER — write one section)
--   4. Function  : jsms_fetch_school_data (SECURITY DEFINER — read one section)
--
-- V29 SECTIONED ARCHITECTURE (no schema change needed):
--   Data is split into logical sections, each stored as a separate row.
--   The school_id column holds a composite key:  <schoolId>__<section>
--
--   Examples for school ID "kopiya2026":
--     kopiya2026__core        → learners, staff, credentials, school setup
--     kopiya2026__finance     → payments, fee structure
--     kopiya2026__events      → school events / calendar
--     kopiya2026__timetable   → timetable assignments
--     kopiya2026__cc          → co-curricular activities
--     kopiya2026__att         → attendance records (all classes)
--     kopiya2026__scores      → exam configs + summative scores + remarks
--     kopiya2026__library     → books, shelves, loans
--
--   Future granularity (no SQL change needed — just use a longer key):
--     kopiya2026__att__G7A            → Grade 7A attendance only
--     kopiya2026__scores__G7__english → Grade 7 English scores only
--
-- THE SQL TABLE IS IDENTICAL TO V27/V28.
-- Only the portal JavaScript changed to write/read per-section keys.
-- If you already ran the old setup script, you do NOT need to drop and recreate.
-- Just re-run this script — it will add any missing pieces safely.
-- ══════════════════════════════════════════════════════════════════════════════


-- ══════════════════════════════════════════════════════════════════════════════
-- SECTION A — TABLE: school_data
-- ══════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS school_data (
    school_id   TEXT        PRIMARY KEY,
    payload     JSONB       NOT NULL DEFAULT '{}',
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Unique constraint on school_id (needed for ON CONFLICT upsert in the push RPC)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE  table_name      = 'school_data'
    AND    constraint_type = 'UNIQUE'
    AND    constraint_name = 'school_data_school_id_unique'
  ) THEN
    ALTER TABLE school_data
      ADD CONSTRAINT school_data_school_id_unique UNIQUE (school_id);
  END IF;
END $$;

-- Index for fast lookup by recency (useful when listing all sections for a school)
CREATE INDEX IF NOT EXISTS idx_school_data_updated_at ON school_data (updated_at DESC);

-- Optional: index to support prefix queries on school_id
-- e.g.  SELECT * FROM school_data WHERE school_id LIKE 'kopiya2026__%'
CREATE INDEX IF NOT EXISTS idx_school_data_school_id ON school_data (school_id text_pattern_ops);


-- ══════════════════════════════════════════════════════════════════════════════
-- SECTION B — ROW LEVEL SECURITY (RLS)
-- ══════════════════════════════════════════════════════════════════════════════

ALTER TABLE school_data ENABLE ROW LEVEL SECURITY;

-- Drop old policies before recreating (safe to re-run)
DROP POLICY IF EXISTS jsms_school_data_service_all  ON school_data;
DROP POLICY IF EXISTS jsms_school_data_anon_read    ON school_data;
DROP POLICY IF EXISTS jsms_school_data_anon_insert  ON school_data;
DROP POLICY IF EXISTS jsms_school_data_anon_update  ON school_data;

-- service_role key (Supabase dashboard / admin) can do anything
CREATE POLICY jsms_school_data_service_all ON school_data
    FOR ALL
    TO service_role
    USING (TRUE)
    WITH CHECK (TRUE);

-- anon (publishable) key: SELECT allowed
-- Note: actual data access goes through SECURITY DEFINER RPCs which bypass RLS
-- entirely, so these policies are a belt-and-suspenders safety net.
CREATE POLICY jsms_school_data_anon_read ON school_data
    FOR SELECT
    TO anon
    USING (TRUE);

-- anon key: INSERT allowed (for first-time upsert of a new section row)
CREATE POLICY jsms_school_data_anon_insert ON school_data
    FOR INSERT
    TO anon
    WITH CHECK (TRUE);

-- anon key: UPDATE allowed (for subsequent syncs of existing section rows)
CREATE POLICY jsms_school_data_anon_update ON school_data
    FOR UPDATE
    TO anon
    USING (TRUE)
    WITH CHECK (TRUE);


-- ══════════════════════════════════════════════════════════════════════════════
-- SECTION C — RPC: jsms_push_school_data
-- Upserts one section payload into school_data.
-- Called by the portal whenever any data section changes.
-- p_school_id is the full section key, e.g. "kopiya2026__att"
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION jsms_push_school_data(
    p_school_id   TEXT,
    p_payload     JSONB,
    p_updated_at  TEXT  DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_updated_at TIMESTAMPTZ;
BEGIN
    -- Parse timestamp safely; fall back to NOW() if malformed or omitted
    BEGIN
        v_updated_at := COALESCE(p_updated_at::TIMESTAMPTZ, NOW());
    EXCEPTION WHEN OTHERS THEN
        v_updated_at := NOW();
    END;

    INSERT INTO school_data (school_id, payload, updated_at)
    VALUES (p_school_id, p_payload, v_updated_at)
    ON CONFLICT (school_id) DO UPDATE
        SET payload    = EXCLUDED.payload,
            updated_at = EXCLUDED.updated_at;
END;
$$;

GRANT EXECUTE ON FUNCTION jsms_push_school_data(TEXT, JSONB, TEXT) TO anon, authenticated;


-- ══════════════════════════════════════════════════════════════════════════════
-- SECTION D — RPC: jsms_fetch_school_data
-- Returns the payload JSONB for a given section key.
-- Returns NULL if the section has never been pushed (handled gracefully by portal).
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION jsms_fetch_school_data(
    p_school_id TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_payload JSONB;
BEGIN
    SELECT payload INTO v_payload
    FROM   school_data
    WHERE  school_id = p_school_id
    LIMIT  1;

    RETURN v_payload; -- NULL if row not found; portal handles this gracefully
END;
$$;

GRANT EXECUTE ON FUNCTION jsms_fetch_school_data(TEXT) TO anon, authenticated;


-- ══════════════════════════════════════════════════════════════════════════════
-- SECTION E — OPTIONAL HELPER: jsms_fetch_all_school_sections
-- Returns all rows for a school as a JSON object keyed by section suffix.
-- Useful for admin bulk pull or debugging.
-- Usage: SELECT jsms_fetch_all_school_sections('kopiya2026');
-- Returns: {"core": {...}, "att": {...}, "scores": {...}, ...}
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION jsms_fetch_all_school_sections(
    p_school_id TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_prefix TEXT;
    v_result JSONB := '{}';
    v_row    RECORD;
    v_suffix TEXT;
BEGIN
    v_prefix := p_school_id || '__';

    FOR v_row IN
        SELECT school_id, payload
        FROM   school_data
        WHERE  school_id LIKE v_prefix || '%'
        ORDER  BY updated_at DESC
    LOOP
        -- Extract section suffix, e.g. "kopiya2026__att" → "att"
        v_suffix := substring(v_row.school_id FROM length(v_prefix) + 1);
        v_result := v_result || jsonb_build_object(v_suffix, v_row.payload);
    END LOOP;

    RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION jsms_fetch_all_school_sections(TEXT) TO anon, authenticated;


-- ══════════════════════════════════════════════════════════════════════════════
-- SECTION F — VERIFICATION QUERIES
-- Uncomment and run these after setup to confirm everything is working.
-- ══════════════════════════════════════════════════════════════════════════════

-- 1. Check RPCs exist:
-- SELECT routine_name
-- FROM   information_schema.routines
-- WHERE  routine_schema = 'public'
-- AND    routine_name IN (
--          'jsms_push_school_data',
--          'jsms_fetch_school_data',
--          'jsms_fetch_all_school_sections'
--        );

-- 2. Check table + constraints:
-- SELECT constraint_name, constraint_type
-- FROM   information_schema.table_constraints
-- WHERE  table_name = 'school_data';

-- 3. Check RLS policies:
-- SELECT policyname, cmd, roles
-- FROM   pg_policies
-- WHERE  tablename = 'school_data';

-- 4. Test push of a single section (replace 'kopiya2026' with your School ID):
-- SELECT jsms_push_school_data('kopiya2026__att', '{"_test":true,"edu2_att":"{}"}', NULL);

-- 5. Test fetch of that section:
-- SELECT jsms_fetch_school_data('kopiya2026__att');

-- 6. Fetch ALL sections for a school at once:
-- SELECT jsms_fetch_all_school_sections('kopiya2026');

-- 7. List all section rows currently stored for a school:
-- SELECT school_id, updated_at, length(payload::text) AS payload_bytes
-- FROM   school_data
-- WHERE  school_id LIKE 'kopiya2026__%'
-- ORDER  BY updated_at DESC;


-- ══════════════════════════════════════════════════════════════════════════════
-- END OF JSMS SUPABASE SETUP SCRIPT V29
-- ══════════════════════════════════════════════════════════════════════════════
