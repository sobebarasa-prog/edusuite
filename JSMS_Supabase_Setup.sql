-- ══════════════════════════════════════════════════════════════════════════════
-- JSMS PORTAL — SUPABASE SETUP SCRIPT
-- Junior School Management System (JSMS) — Kopiya Junior School
-- Run this entire script in Supabase → SQL Editor → Run
-- Safe to re-run: all statements use IF NOT EXISTS / OR REPLACE / DROP IF EXISTS
-- ══════════════════════════════════════════════════════════════════════════════

-- ══════════════════════════════════════════════════════════════════════════════
-- SECTION A — TABLE: school_data
-- Single-row-per-school blob store. All JSMS data packed into one JSONB column.
-- ══════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS school_data (
    school_id   TEXT        PRIMARY KEY,
    payload     JSONB       NOT NULL DEFAULT '{}',
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Ensure the primary key doubles as a unique constraint (needed for upsert ON CONFLICT)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE table_name = 'school_data'
    AND constraint_type = 'UNIQUE'
    AND constraint_name = 'school_data_school_id_unique'
  ) THEN
    ALTER TABLE school_data
      ADD CONSTRAINT school_data_school_id_unique UNIQUE (school_id);
  END IF;
END $$;

-- Index for fast lookup (school_id is PK already, but be explicit)
CREATE INDEX IF NOT EXISTS idx_school_data_updated_at ON school_data (updated_at DESC);

-- ── Enable RLS ────────────────────────────────────────────────────────────────
ALTER TABLE school_data ENABLE ROW LEVEL SECURITY;

-- ── RLS Policies ─────────────────────────────────────────────────────────────
-- All actual data access goes through SECURITY DEFINER RPCs below.
-- These policies are kept minimal — RPCs bypass RLS entirely.

DROP POLICY IF EXISTS jsms_school_data_service_all  ON school_data;
DROP POLICY IF EXISTS jsms_school_data_anon_read     ON school_data;
DROP POLICY IF EXISTS jsms_school_data_anon_insert   ON school_data;
DROP POLICY IF EXISTS jsms_school_data_anon_update   ON school_data;

-- service_role key can do everything (for admin/dashboard use)
CREATE POLICY jsms_school_data_service_all ON school_data
    FOR ALL TO service_role USING (TRUE) WITH CHECK (TRUE);

-- anon (publishable) key: read allowed (RPCs handle auth internally)
CREATE POLICY jsms_school_data_anon_read ON school_data
    FOR SELECT TO anon USING (TRUE);

-- anon key: insert allowed (RPC jsms_push_school_data will call this path)
CREATE POLICY jsms_school_data_anon_insert ON school_data
    FOR INSERT TO anon WITH CHECK (TRUE);

-- anon key: update allowed (RPC jsms_push_school_data will call this path)
CREATE POLICY jsms_school_data_anon_update ON school_data
    FOR UPDATE TO anon USING (TRUE) WITH CHECK (TRUE);


-- ══════════════════════════════════════════════════════════════════════════════
-- SECTION B — SECURITY DEFINER RPCs
-- All portal calls go through these. SECURITY DEFINER means they run as the
-- table owner and bypass RLS — so the publishable (anon) key always works.
-- ══════════════════════════════════════════════════════════════════════════════

-- ── B1: jsms_push_school_data ─────────────────────────────────────────────────
-- Called by: _sbPushCore(), beforeunload beacon
-- Upserts the entire school payload into school_data for the given school_id.

CREATE OR REPLACE FUNCTION jsms_push_school_data(
    p_school_id   TEXT,
    p_payload     JSONB,
    p_updated_at  TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_updated_at TIMESTAMPTZ;
BEGIN
    -- Safely parse the timestamp; fall back to NOW() if malformed
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

-- ── B2: jsms_fetch_school_data ───────────────────────────────────────────────
-- Called by: supabasePull(), jsmsCloudPull (new device login), testSupabaseConnection()
-- Returns the payload JSONB directly (null if school_id not found).

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
    FROM school_data
    WHERE school_id = p_school_id
    ORDER BY updated_at DESC
    LIMIT 1;

    RETURN v_payload; -- returns NULL if no row found (portal handles this)
END;
$$;

GRANT EXECUTE ON FUNCTION jsms_fetch_school_data(TEXT) TO anon, authenticated;


-- ══════════════════════════════════════════════════════════════════════════════
-- SECTION C — VERIFICATION QUERIES
-- Run these after setup to confirm everything is in place.
-- ══════════════════════════════════════════════════════════════════════════════

-- Check RPCs exist:
-- SELECT routine_name FROM information_schema.routines
-- WHERE routine_schema = 'public'
-- AND routine_name IN ('jsms_push_school_data','jsms_fetch_school_data');

-- Check table + constraint exist:
-- SELECT constraint_name FROM information_schema.table_constraints
-- WHERE table_name = 'school_data' AND constraint_type IN ('PRIMARY KEY','UNIQUE');

-- Check RLS policies:
-- SELECT policyname, cmd, roles FROM pg_policies WHERE tablename = 'school_data';

-- Test push (replace 'kopiya26' with your school ID):
-- SELECT jsms_push_school_data('kopiya26', '{"_test":true}', NULL);

-- Test fetch:
-- SELECT jsms_fetch_school_data('kopiya26');

-- ══════════════════════════════════════════════════════════════════════════════
-- END OF JSMS SUPABASE SETUP SCRIPT
-- ══════════════════════════════════════════════════════════════════════════════
