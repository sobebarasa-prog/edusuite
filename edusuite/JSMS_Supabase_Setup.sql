-- ═══════════════════════════════════════════════════════════════════════════
--  JSMS PORTAL — SUPABASE SETUP SQL  v2.6
--  Run this in Supabase SQL Editor for the JSMS Portal built-in cloud sync.
--
--  What this creates:
--    1. school_data  — one row per school, stores complete localStorage snapshot
--
--  How the JSMS sync works:
--    PUSH: Collects all edu2_* and jsms_* keys from localStorage, builds one
--          JSON payload object, POSTs to school_data with on_conflict=school_id.
--          Uses PostgREST upsert directly — NO RPC needed.
--
--    PULL: Fetches school_data row for this school_id, restores all keys
--          back to localStorage, then reloads the page.
--
--  The JSMS portal does NOT use RPC functions — it talks to the REST table
--  directly via PostgREST with anon key. RLS is open (school_id is the
--  logical separator, enforced in the app, not at DB level).
--
--  Safe to re-run — all statements are idempotent (IF NOT EXISTS / OR REPLACE).
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 0. Extension ──────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";


-- ═══════════════════════════════════════════════════════════════════════════
-- TABLE: school_data
--
--  Purpose: Stores the entire JSMS localStorage as one JSONB blob per school.
--           school_id is a TEXT identifier chosen by the user in JSMS Setup
--           (not a UUID — it's whatever string the school admin entered,
--            e.g. "KOPIYA-001" or "15310208").
--
--  Push request (exact PostgREST call from portal):
--    POST /rest/v1/school_data?on_conflict=school_id
--    Prefer: resolution=merge-duplicates,return=minimal
--    Body: { school_id: cfg.schoolId, payload: {...all edu2_keys...}, updated_at: "..." }
--
--  Pull request:
--    GET /rest/v1/school_data?school_id=eq.{schoolId}&order=updated_at.desc&limit=1
--
--  Payload structure:
--    {
--      edu2_l:             [...learners],
--      edu2_ec:            {...exam configs},
--      edu2_s:             {...summative scores},
--      edu2_rem:           {...remarks},
--      edu2_fs:            [...fee structure],
--      edu2_pays:          {...payments by adm},
--      edu2_att:           {...attendance by date},
--      edu2_cal:           [...calendar events},    ← note: this is school calendar
--      edu2_schoolName:    "string",
--      edu2_exam_periods:  {...},
--      edu2_events:        [...],
--      edu2_lib_shelves:   [...],
--      edu2_lib_books:     [...],
--      edu2_lib_loans:     [...],
--      edu2_tt_periods:    [...],
--      edu2_tt_subjects:   [...],
--      edu2_tt_grades:     [...],
--      edu2_tt_teachers:   [...],
--      edu2_tt_assignments:[...],
--      edu2_tt_timetable:  [...],
--      edu2_school_setup:  {...},
--      edu2_staff:         [...],
--      edu2_notifications: [...],
--      edu2_drafts:        {...},
--      edu2_rcpt_seq:      number,
--      edu2_school_depts:  [...],
--      edu2_school_stamp_img: "base64...",
--      edu2_signatures:    {...},
--      edu2_stamp:         {...},
--      edu2_parent_creds:  {...},     ← parent portal passwords
--      edu2_teacher_creds: {...},     ← teacher portal passwords
--      edu2_admin_username:"string",
--      edu2_admin_recovery_email: "string",
--      edu2_cred_hash:     "sha256hex",
--      edu2_pending_pays:  [...],
--      jsms_cocurricular_assignments: [...],
--      jsms_cocurricular_items:       [...],
--      jsms_cc_clubs_list:            [...],
--      jsms_cc_leadership_list:       [...],
--      _pushed:   "2026-06-18T...",   ← push timestamp
--      _version:  "15"                ← portal version
--    }
--
--  NOT synced (SB_EXCLUDE_KEYS):
--    edu2_supabase_cfg      — Supabase credentials, never leave device
--    edu2_last_backup_time  — device-local timestamp
--    edu2_auth              — session token
--    edu2_auth_ts           — session timestamp
--    edu2_current_user      — active session
--    edu2_dark_mode         — UI preference
--    jsms_apk_tip_shown     — UI preference
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS school_data (
  id          UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id   TEXT        NOT NULL UNIQUE,    -- user-chosen school identifier
  payload     JSONB       NOT NULL DEFAULT '{}',
  version     TEXT,                           -- portal version string (from payload._version)
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE school_data IS
  'JSMS full-payload cloud sync. One row per school. '
  'Contains all edu2_* and jsms_* localStorage keys as nested JSONB. '
  'school_id is a TEXT string (not UUID) chosen by the admin in JSMS Setup.';

CREATE INDEX IF NOT EXISTS idx_school_data_school_id ON school_data(school_id);
CREATE INDEX IF NOT EXISTS idx_school_data_updated   ON school_data(updated_at DESC);

-- Auto-update updated_at on every push
CREATE OR REPLACE FUNCTION _jsms_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS jsms_school_data_updated_at ON school_data;
CREATE TRIGGER jsms_school_data_updated_at
  BEFORE UPDATE ON school_data
  FOR EACH ROW EXECUTE FUNCTION _jsms_set_updated_at();


-- ═══════════════════════════════════════════════════════════════════════════
-- ROW LEVEL SECURITY
--
--  The JSMS portal uses anon key for direct PostgREST REST calls (no RPC).
--  We need SELECT and INSERT/UPDATE to work for the anon role.
--  school_id is the logical separator but enforced in the app, not via JWT.
--  Open policies allow the push/pull to work correctly.
--
--  For tighter security in production: replace with JWT-claim-based policies
--  once you move to Supabase Auth with custom claims.
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE school_data ENABLE ROW LEVEL SECURITY;
ALTER TABLE school_data FORCE  ROW LEVEL SECURITY;

-- SELECT: anon can read (needed for pull)
DROP POLICY IF EXISTS school_data_select ON school_data;
CREATE POLICY school_data_select ON school_data FOR SELECT USING (true);

-- INSERT: anon can insert new schools
DROP POLICY IF EXISTS school_data_insert ON school_data;
CREATE POLICY school_data_insert ON school_data FOR INSERT WITH CHECK (true);

-- UPDATE: anon can update (the on_conflict upsert becomes an UPDATE)
DROP POLICY IF EXISTS school_data_update ON school_data;
CREATE POLICY school_data_update ON school_data FOR UPDATE USING (true) WITH CHECK (true);

-- DELETE: blocked for anon
DROP POLICY IF EXISTS school_data_delete ON school_data;
CREATE POLICY school_data_delete ON school_data FOR DELETE USING (false);


-- ═══════════════════════════════════════════════════════════════════════════
-- HELPER: extract_jsms_learner_count
--
--  Utility function to count learners in a school's payload
--  without pulling the entire blob into application code.
--  Useful for analytics queries in the Platform Hub.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION jsms_learner_count(p_school_id TEXT)
RETURNS INT AS $$
DECLARE v_count INT;
BEGIN
  SELECT JSONB_ARRAY_LENGTH(payload->'edu2_l')
  INTO   v_count
  FROM   school_data
  WHERE  school_id = p_school_id;

  RETURN COALESCE(v_count, 0);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

COMMENT ON FUNCTION jsms_learner_count IS
  'Returns the number of learners stored in a school payload. '
  'Avoids pulling the full blob just for a count.';


-- ═══════════════════════════════════════════════════════════════════════════
-- HELPER: jsms_last_push
--
--  Returns the last push timestamp for a school.
--  Used by Platform Hub v_sync_health view.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION jsms_last_push(p_school_id TEXT)
RETURNS TIMESTAMPTZ AS $$
DECLARE v_ts TIMESTAMPTZ;
BEGIN
  SELECT updated_at INTO v_ts
  FROM   school_data
  WHERE  school_id = p_school_id;
  RETURN v_ts;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;


-- ═══════════════════════════════════════════════════════════════════════════
-- VIEW: v_jsms_school_summary
--
--  Gives a quick summary of each school's data without pulling
--  the entire payload blob. Used for super-admin analytics.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW v_jsms_school_summary AS
SELECT
  school_id,
  version,
  updated_at                                                  AS last_push,
  JSONB_ARRAY_LENGTH(payload->'edu2_l')                       AS learner_count,
  JSONB_ARRAY_LENGTH(payload->'edu2_staff')                   AS staff_count,
  JSONB_ARRAY_LENGTH(payload->'edu2_lib_books')               AS book_count,
  JSONB_ARRAY_LENGTH(payload->'edu2_lib_loans')               AS loan_count,
  JSONB_ARRAY_LENGTH(payload->'edu2_events')                  AS event_count,
  payload->>'_version'                                        AS payload_version,
  payload->>'_pushed'                                         AS payload_push_ts
FROM school_data;

COMMENT ON VIEW v_jsms_school_summary IS
  'Quick summary of JSMS data per school. Avoids loading the full payload.';


-- ═══════════════════════════════════════════════════════════════════════════
-- VERIFICATION
-- ═══════════════════════════════════════════════════════════════════════════
SELECT
  obj_type,
  obj_name
FROM (
  SELECT 'TABLE'    AS obj_type, table_name    AS obj_name
  FROM   information_schema.tables
  WHERE  table_schema = 'public'
    AND  table_name   = 'school_data'

  UNION ALL

  SELECT 'FUNCTION', routine_name
  FROM   information_schema.routines
  WHERE  routine_schema = 'public'
    AND  routine_name   IN ('jsms_learner_count','jsms_last_push')

  UNION ALL

  SELECT 'VIEW', table_name
  FROM   information_schema.views
  WHERE  table_schema = 'public'
    AND  table_name   = 'v_jsms_school_summary'
) x
ORDER BY obj_type, obj_name;

-- Expected output (4 rows):
--   FUNCTION  jsms_last_push
--   FUNCTION  jsms_learner_count
--   TABLE     school_data
--   VIEW      v_jsms_school_summary

-- ═══════════════════════════════════════════════════════════════════════════
-- QUICK-START GUIDE
-- ═══════════════════════════════════════════════════════════════════════════
--
--  After running this SQL:
--
--  1. Open JSMS Portal → Setup tab → Cloud Backup section
--  2. Enter:
--       Supabase URL:   https://xxxx.supabase.co
--       Anon Key:       eyJhbG...  (from Supabase → Settings → API → anon public)
--       School ID:      KOPIYA-001 (any unique string for your school — write it down!)
--  3. Click Save Settings
--  4. Click ⬆️ Push to Supabase
--  5. Status should show: ✅ All data synced! (N keys)
--
--  To restore on a new device:
--  1. Enter same URL, key, school_id
--  2. Click ⬇️ Pull from Supabase
--  3. Confirm the overwrite prompt
--  4. Page reloads with all your data
--
--  IMPORTANT: The school_id string must be IDENTICAL on every device.
--             "KOPIYA-001" ≠ "kopiya-001" ≠ "KOPIYA 001"
--             It is case-sensitive and whitespace-sensitive.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- END OF JSMS SUPABASE SETUP
-- ═══════════════════════════════════════════════════════════════════════════
