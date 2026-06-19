-- ═══════════════════════════════════════════════════════════════════════════
--  TPDS PORTAL — SUPABASE SETUP SQL  v1.44
--  Run this in Supabase SQL Editor for the TPDS Portal built-in cloud sync.
--
--  What this creates:
--    1. tpds_sync          — one row per (teacher_id, data_key)
--    2. tpds_users_cloud   — teacher cloud accounts for cross-device login
--    3. tpds_upsert()      — RPC called after every save (exact portal signature)
--    4. tpds_fetch()       — RPC called on login / pull (exact portal signature)
--    5. tpds_fetch_cloud_user() — RPC for teacher cloud login
--    6. tpds_upsert_teacher()   — RPC for teacher cloud account registration
--
--  IMPORTANT: The portal calls RPCs with these EXACT parameter names.
--  Do not rename parameters or the portal will silently fail.
--
--  Safe to re-run — all statements are idempotent (IF NOT EXISTS / OR REPLACE).
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 0. Extension (needed for uuid_generate_v4) ────────────────────────────
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";


-- ═══════════════════════════════════════════════════════════════════════════
-- TABLE 1: tpds_sync
--
--  Purpose: Stores every teacher's data keyed by (user_id, data_key).
--           user_id  = sbUserId() = lowercase username / TSC slug / 'tpds_default'
--           data_key = one of: setup | lessons | ieps | cal | deleted |
--                              submitted_docs | iep_logs | admin_config |
--                              letterhead | sow_taught | users | uploads_meta
--
--  The portal uses a composite id string: user_id + '__' + data_key
--  as the logical primary lookup key (passed as p_id to RPCs).
--  We store it in the `row_id` column for fast lookup without joining two cols.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS tpds_sync (
  row_id      TEXT        PRIMARY KEY,          -- '{user_id}__{data_key}'
  user_id     TEXT        NOT NULL,             -- sbUserId() value
  data_key    TEXT        NOT NULL,             -- one of the SB_DATA_KEYS keys
  payload     JSONB,                            -- the full data array / object
  school_id   TEXT,                             -- optional school identifier
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE tpds_sync IS
  'TPDS cloud sync storage. One row per teacher per data type. '
  'row_id = user_id||''__''||data_key — the portal uses this composite as its primary key.';

CREATE INDEX IF NOT EXISTS idx_tpds_sync_user_id   ON tpds_sync(user_id);
CREATE INDEX IF NOT EXISTS idx_tpds_sync_data_key  ON tpds_sync(data_key);
CREATE INDEX IF NOT EXISTS idx_tpds_sync_school_id ON tpds_sync(school_id);
CREATE INDEX IF NOT EXISTS idx_tpds_sync_updated   ON tpds_sync(updated_at DESC);

-- Auto-update updated_at
CREATE OR REPLACE FUNCTION _tpds_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS tpds_sync_updated_at ON tpds_sync;
CREATE TRIGGER tpds_sync_updated_at
  BEFORE UPDATE ON tpds_sync
  FOR EACH ROW EXECUTE FUNCTION _tpds_set_updated_at();


-- ═══════════════════════════════════════════════════════════════════════════
-- TABLE 2: tpds_users_cloud
--
--  Purpose: Teacher cloud accounts. Created when a teacher clicks
--           "Register Cloud Account" in TPDS Setup.
--           Used for cross-device login — teacher enters username + password
--           and their data is fetched from tpds_sync.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS tpds_users_cloud (
  id            UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  username      TEXT        NOT NULL UNIQUE,   -- always stored lowercase
  password_hash TEXT        NOT NULL,          -- SHA-256 hex (same as portal)
  name          TEXT,                          -- teacher display name
  tsc           TEXT,                          -- TSC number
  school        TEXT,                          -- school name string
  school_id     TEXT,                          -- school identifier
  role          TEXT        NOT NULL DEFAULT 'teacher',
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE tpds_users_cloud IS
  'TPDS teacher cloud accounts. Separate from Platform Hub auth. '
  'Teachers register here via Setup → Cloud Sync to enable cross-device access.';

CREATE INDEX IF NOT EXISTS idx_tpds_users_username  ON tpds_users_cloud(username);
CREATE INDEX IF NOT EXISTS idx_tpds_users_school_id ON tpds_users_cloud(school_id);
CREATE INDEX IF NOT EXISTS idx_tpds_users_tsc       ON tpds_users_cloud(tsc);

DROP TRIGGER IF EXISTS tpds_users_updated_at ON tpds_users_cloud;
CREATE TRIGGER tpds_users_updated_at
  BEFORE UPDATE ON tpds_users_cloud
  FOR EACH ROW EXECUTE FUNCTION _tpds_set_updated_at();


-- ═══════════════════════════════════════════════════════════════════════════
-- RPC 1: tpds_upsert
--
--  Called by: _sbUpsert(dataKey, payload) in TPDSPortalV144.html
--  Exact call:
--    fetch('/rest/v1/rpc/tpds_upsert', {
--      body: JSON.stringify({
--        p_id:         uid + '__' + dataKey,   ← composite row key
--        p_user_id:    uid,
--        p_data_key:   dataKey,
--        p_payload:    payload,
--        p_updated_at: new Date().toISOString()
--      })
--    })
--
--  Parameters must match EXACTLY — PostgREST maps JSON keys to param names.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION tpds_upsert(
  p_id         TEXT,                   -- uid + '__' + dataKey composite
  p_user_id    TEXT,
  p_data_key   TEXT,
  p_payload    JSONB,
  p_updated_at TIMESTAMPTZ DEFAULT NOW(),
  p_school_id  TEXT        DEFAULT NULL
)
RETURNS VOID AS $$
BEGIN
  -- Validate required fields
  IF p_id IS NULL OR p_user_id IS NULL OR p_data_key IS NULL THEN
    RAISE EXCEPTION 'tpds_upsert: p_id, p_user_id, and p_data_key are all required';
  END IF;

  INSERT INTO tpds_sync(row_id, user_id, data_key, payload, school_id, updated_at)
  VALUES (
    p_id,
    LOWER(TRIM(p_user_id)),
    p_data_key,
    COALESCE(p_payload, '[]'::JSONB),
    p_school_id,
    COALESCE(p_updated_at, NOW())
  )
  ON CONFLICT (row_id)
  DO UPDATE SET
    payload    = COALESCE(EXCLUDED.payload, '[]'::JSONB),
    school_id  = COALESCE(EXCLUDED.school_id, tpds_sync.school_id),
    updated_at = COALESCE(EXCLUDED.updated_at, NOW());
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION tpds_upsert IS
  'Called by TPDS portal _sbUpsert(). '
  'p_id = uid__dataKey. SECURITY DEFINER bypasses RLS for reliable writes.';


-- ═══════════════════════════════════════════════════════════════════════════
-- RPC 2: tpds_fetch
--
--  Called by: _sbFetch(dataKey) in TPDSPortalV144.html
--  Exact call:
--    fetch('/rest/v1/rpc/tpds_fetch', {
--      body: JSON.stringify({ p_id: uid + '__' + dataKey })
--    })
--
--  Returns: the payload JSONB directly (not a table row) — null if not found.
--           The portal checks: if(result !== null && result !== undefined)
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION tpds_fetch(p_id TEXT)
RETURNS JSONB AS $$
DECLARE
  v_payload JSONB;
BEGIN
  SELECT payload INTO v_payload
  FROM   tpds_sync
  WHERE  row_id = p_id
  LIMIT  1;

  RETURN v_payload;  -- returns NULL if not found; portal handles this correctly
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

COMMENT ON FUNCTION tpds_fetch IS
  'Called by TPDS portal _sbFetch(dataKey). '
  'p_id = uid__dataKey. Returns the payload JSONB directly or NULL if not found.';


-- ═══════════════════════════════════════════════════════════════════════════
-- RPC 3: tpds_fetch_cloud_user
--
--  Called by: _sbFetchCloudUser(username, password) in TPDSPortalV144.html
--  Exact call:
--    fetch('/rest/v1/rpc/tpds_fetch_cloud_user', {
--      body: JSON.stringify({ p_username: username.toLowerCase() })
--    })
--
--  Returns one row with all teacher fields.
--  The portal verifies the password_hash client-side after receiving the row.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION tpds_fetch_cloud_user(p_username TEXT)
RETURNS TABLE (
  id            UUID,
  username      TEXT,
  password_hash TEXT,
  name          TEXT,
  tsc           TEXT,
  school        TEXT,
  school_id     TEXT,
  role          TEXT
) AS $$
BEGIN
  RETURN QUERY
  SELECT  u.id,
          u.username,
          u.password_hash,
          u.name,
          u.tsc,
          u.school,
          u.school_id,
          u.role
  FROM    tpds_users_cloud u
  WHERE   u.username = LOWER(TRIM(p_username))
  LIMIT 1;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

COMMENT ON FUNCTION tpds_fetch_cloud_user IS
  'Called by TPDS login screen. Returns teacher row for password verification. '
  'Password check is done client-side (SHA-256 comparison).';


-- ═══════════════════════════════════════════════════════════════════════════
-- RPC 4: tpds_upsert_teacher
--
--  Called by: sbRegisterCloudUser() in TPDSPortalV144.html
--  Exact call:
--    fetch('/rest/v1/rpc/tpds_upsert_teacher', {
--      body: JSON.stringify({
--        p_username, p_password_hash, p_name, p_tsc,
--        p_school, p_school_id, p_role
--      })
--    })
--
--  Returns: the UUID of the created/updated user row.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION tpds_upsert_teacher(
  p_username      TEXT,
  p_password_hash TEXT,
  p_name          TEXT    DEFAULT NULL,
  p_tsc           TEXT    DEFAULT NULL,
  p_school        TEXT    DEFAULT NULL,
  p_school_id     TEXT    DEFAULT NULL,
  p_role          TEXT    DEFAULT 'teacher'
)
RETURNS UUID AS $$
DECLARE
  v_id UUID;
BEGIN
  IF p_username IS NULL OR p_password_hash IS NULL THEN
    RAISE EXCEPTION 'tpds_upsert_teacher: username and password_hash are required';
  END IF;

  INSERT INTO tpds_users_cloud(
    username, password_hash, name, tsc, school, school_id, role
  )
  VALUES (
    LOWER(TRIM(p_username)),
    p_password_hash,
    p_name,
    p_tsc,
    p_school,
    p_school_id,
    COALESCE(p_role, 'teacher')
  )
  ON CONFLICT (username)
  DO UPDATE SET
    -- Only update password if a new one is provided (non-empty)
    password_hash = CASE
      WHEN LENGTH(COALESCE(EXCLUDED.password_hash, '')) > 0
      THEN EXCLUDED.password_hash
      ELSE tpds_users_cloud.password_hash
    END,
    name          = COALESCE(EXCLUDED.name,      tpds_users_cloud.name),
    tsc           = COALESCE(EXCLUDED.tsc,       tpds_users_cloud.tsc),
    school        = COALESCE(EXCLUDED.school,    tpds_users_cloud.school),
    school_id     = COALESCE(EXCLUDED.school_id, tpds_users_cloud.school_id),
    role          = COALESCE(EXCLUDED.role,      tpds_users_cloud.role),
    updated_at    = NOW()
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION tpds_upsert_teacher IS
  'Called by TPDS Setup → Cloud Sync → Register Account. '
  'Creates or updates a teacher cloud account. Returns the user UUID.';


-- ═══════════════════════════════════════════════════════════════════════════
-- ROW LEVEL SECURITY
--
--  Both tables use SECURITY DEFINER RPCs as the gate — anon key can only
--  reach data through the functions above, not by direct table access.
--  We enable RLS and add open SELECT policies so the portal's direct
--  tpds_sync GET (for submitted_docs admin view) still works.
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE tpds_sync        ENABLE ROW LEVEL SECURITY;
ALTER TABLE tpds_sync        FORCE  ROW LEVEL SECURITY;
ALTER TABLE tpds_users_cloud ENABLE ROW LEVEL SECURITY;
ALTER TABLE tpds_users_cloud FORCE  ROW LEVEL SECURITY;

-- Allow reads (RPCs + admin submitted_docs view use direct GET)
DROP POLICY IF EXISTS tpds_sync_select        ON tpds_sync;
CREATE POLICY tpds_sync_select        ON tpds_sync        FOR SELECT USING (true);

-- Block direct INSERT/UPDATE/DELETE — force through RPCs only
DROP POLICY IF EXISTS tpds_sync_insert        ON tpds_sync;
CREATE POLICY tpds_sync_insert        ON tpds_sync        FOR INSERT WITH CHECK (false);
DROP POLICY IF EXISTS tpds_sync_update        ON tpds_sync;
CREATE POLICY tpds_sync_update        ON tpds_sync        FOR UPDATE USING (false);
DROP POLICY IF EXISTS tpds_sync_delete        ON tpds_sync;
CREATE POLICY tpds_sync_delete        ON tpds_sync        FOR DELETE USING (false);

-- tpds_users_cloud: read-only via anon key (RPCs handle writes)
DROP POLICY IF EXISTS tpds_users_select       ON tpds_users_cloud;
CREATE POLICY tpds_users_select       ON tpds_users_cloud FOR SELECT USING (true);
DROP POLICY IF EXISTS tpds_users_insert       ON tpds_users_cloud;
CREATE POLICY tpds_users_insert       ON tpds_users_cloud FOR INSERT WITH CHECK (false);
DROP POLICY IF EXISTS tpds_users_update       ON tpds_users_cloud;
CREATE POLICY tpds_users_update       ON tpds_users_cloud FOR UPDATE USING (false);


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
    AND  table_name   IN ('tpds_sync','tpds_users_cloud')

  UNION ALL

  SELECT 'FUNCTION', routine_name
  FROM   information_schema.routines
  WHERE  routine_schema = 'public'
    AND  routine_name   IN (
      'tpds_upsert','tpds_fetch',
      'tpds_fetch_cloud_user','tpds_upsert_teacher'
    )
) x
ORDER BY obj_type, obj_name;

-- Expected output (6 rows):
--   FUNCTION  tpds_fetch
--   FUNCTION  tpds_fetch_cloud_user
--   FUNCTION  tpds_upsert
--   FUNCTION  tpds_upsert_teacher
--   TABLE     tpds_sync
--   TABLE     tpds_users_cloud

-- ═══════════════════════════════════════════════════════════════════════════
-- END OF TPDS SUPABASE SETUP
-- ═══════════════════════════════════════════════════════════════════════════
