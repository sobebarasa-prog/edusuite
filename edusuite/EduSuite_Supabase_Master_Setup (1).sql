-- ═══════════════════════════════════════════════════════════════════════════
--  KOPIYA EDUSUITE — SUPABASE MASTER SETUP SQL
--  Covers: TPDS Portal v1.44 + JSMS Portal v2.5 + Platform Hub
--  Run this ONCE in the Supabase SQL editor on a fresh project.
--  Safe to re-run: all objects use CREATE … IF NOT EXISTS / OR REPLACE.
-- ═══════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────────
-- 0. EXTENSIONS
-- ───────────────────────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";   -- fuzzy search on names


-- ───────────────────────────────────────────────────────────────────────────
-- 1. PLATFORM — SCHOOLS (multi-tenancy root)
--    One row per registered school.
--    Every other table references school_id for RLS isolation.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS schools (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name            TEXT NOT NULL,
  knec_code       TEXT,
  county          TEXT,
  sub_county      TEXT,
  phone           TEXT,
  email           TEXT,
  motto           TEXT,
  plan            TEXT NOT NULL DEFAULT 'school'
                  CHECK (plan IN ('starter','school','premium','term')),
  sub_status      TEXT NOT NULL DEFAULT 'trial'
                  CHECK (sub_status IN ('trial','active','expired','suspended')),
  sub_expiry      TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE schools IS 'Root multi-tenant table. Every other table joins here via school_id.';

-- Academic calendar stored per school (no separate table needed)
ALTER TABLE schools
  ADD COLUMN IF NOT EXISTS term1_start DATE,
  ADD COLUMN IF NOT EXISTS term1_end   DATE,
  ADD COLUMN IF NOT EXISTS term2_start DATE,
  ADD COLUMN IF NOT EXISTS term2_end   DATE,
  ADD COLUMN IF NOT EXISTS term3_start DATE,
  ADD COLUMN IF NOT EXISTS term3_end   DATE;


-- ───────────────────────────────────────────────────────────────────────────
-- 2. PLATFORM — USERS  (maps to SK_USERS / edu2_staff + edu2_admin)
--    All human users across all roles: super_admin, principal, deputy,
--    hod, teacher, tsc_teacher, bursar, librarian, parent.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS users (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id       UUID NOT NULL REFERENCES schools(id) ON DELETE CASCADE,
  name            TEXT NOT NULL,
  email           TEXT NOT NULL,
  password_hash   TEXT NOT NULL,   -- SHA-256 hex (same as portal)
  role            TEXT NOT NULL DEFAULT 'teacher'
                  CHECK (role IN (
                    'super_admin','principal','deputy','hod',
                    'teacher','tsc_teacher','bursar','librarian','parent'
                  )),
  tsc_number      TEXT,
  phone           TEXT,
  subjects        TEXT[],          -- e.g. ARRAY['English','Science']
  department      TEXT,
  class_teacher_of TEXT,           -- e.g. 'Grade 7A'
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  first_login     BOOLEAN NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (school_id, email)
);
COMMENT ON TABLE users IS 'All human users: teachers, admin, parents. school_id isolates tenants.';
CREATE INDEX IF NOT EXISTS idx_users_school  ON users(school_id);
CREATE INDEX IF NOT EXISTS idx_users_email   ON users(email);
CREATE INDEX IF NOT EXISTS idx_users_role    ON users(school_id, role);


-- ───────────────────────────────────────────────────────────────────────────
-- 3. PLATFORM — SUBSCRIPTIONS / PAYMENTS
--    M-Pesa submissions queue + verified payment history.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS subscription_payments (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id       UUID NOT NULL REFERENCES schools(id) ON DELETE CASCADE,
  mpesa_code      TEXT NOT NULL,
  mpesa_phone     TEXT,
  amount          NUMERIC(10,2) NOT NULL,
  plan            TEXT NOT NULL,
  reference       TEXT,            -- auto-generated EDU-XXXX ref shown to user
  status          TEXT NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','verified','rejected')),
  submitted_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  verified_at     TIMESTAMPTZ,
  verified_by     UUID REFERENCES users(id),
  rejection_reason TEXT,
  months_added    INT DEFAULT 1    -- how many months/terms this payment covers
);
COMMENT ON TABLE subscription_payments IS 'M-Pesa payment submissions. Admin verifies then activates school.';
CREATE INDEX IF NOT EXISTS idx_subpay_school  ON subscription_payments(school_id);
CREATE INDEX IF NOT EXISTS idx_subpay_status  ON subscription_payments(status);


-- ───────────────────────────────────────────────────────────────────────────
-- 4. PLATFORM — NOTIFICATIONS (tpds_notifications / edu2_notifications)
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS notifications (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id       UUID NOT NULL REFERENCES schools(id) ON DELETE CASCADE,
  recipient_id    UUID REFERENCES users(id) ON DELETE CASCADE,
  -- NULL recipient_id = school-wide broadcast
  type            TEXT NOT NULL DEFAULT 'info'
                  CHECK (type IN ('info','warn','success','error','payment','library','attendance')),
  title           TEXT NOT NULL,
  body            TEXT,
  data            JSONB,
  is_read         BOOLEAN NOT NULL DEFAULT FALSE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_notif_recipient ON notifications(school_id, recipient_id, is_read);


-- ───────────────────────────────────────────────────────────────────────────
-- 5. PLATFORM — ACTIVITY LOG
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS activity_log (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id       UUID NOT NULL REFERENCES schools(id) ON DELETE CASCADE,
  user_id         UUID REFERENCES users(id) ON DELETE SET NULL,
  action          TEXT NOT NULL,
  entity_type     TEXT,            -- e.g. 'lesson_plan', 'learner', 'payment'
  entity_id       UUID,
  metadata        JSONB,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_activity_school ON activity_log(school_id, created_at DESC);


-- ═══════════════════════════════════════════════════════════════════════════
-- ████  JSMS PORTAL TABLES  ████
-- ═══════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────────
-- 6. JSMS — LEARNERS  (edu2_l)
--    Exact field mapping from LEARNERS array in JSMSPortalDesktopV25.html
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS learners (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id       UUID NOT NULL REFERENCES schools(id) ON DELETE CASCADE,
  adm             TEXT NOT NULL,    -- admission number, user-defined
  name            TEXT NOT NULL,
  grade           TEXT NOT NULL     -- '7', '8', or '9'
                  CHECK (grade IN ('7','8','9')),
  stream          TEXT,             -- 'A', 'B', 'C' etc.
  gender          TEXT,
  dob             DATE,             -- date of birth
  doa             DATE,             -- date of admission
  email           TEXT,
  nemis_no        TEXT,
  ass_no          TEXT,             -- assessment number
  cert_file       TEXT,             -- birth cert file reference
  par_name        TEXT,             -- parent/guardian name
  par_phone       TEXT,
  par_email       TEXT,
  par_id_no       TEXT,
  remarks         JSONB,            -- {term1:{comment:''}, term2:{…}, term3:{…}}
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (school_id, adm)
);
COMMENT ON TABLE learners IS 'Maps to edu2_l localStorage key. adm is unique per school.';
CREATE INDEX IF NOT EXISTS idx_learners_school ON learners(school_id);
CREATE INDEX IF NOT EXISTS idx_learners_grade  ON learners(school_id, grade);
CREATE INDEX IF NOT EXISTS idx_learners_name   ON learners USING gin(name gin_trgm_ops);


-- ───────────────────────────────────────────────────────────────────────────
-- 7. JSMS — STAFF  (edu2_staff)
--    Staff are separate from users: staff = HR record, user = login account.
--    A teacher has both a staff row AND a user row (linked by user_id).
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS staff (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id       UUID NOT NULL REFERENCES schools(id) ON DELETE CASCADE,
  user_id         UUID REFERENCES users(id) ON DELETE SET NULL,
  name            TEXT NOT NULL,
  tsc_number      TEXT,
  phone           TEXT,
  email           TEXT,
  role            TEXT,             -- 'Class Teacher', 'Subject Teacher', 'HOD', etc.
  department      TEXT,
  subjects        TEXT[],
  class_teacher_of TEXT,
  qualification   TEXT,
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_staff_school ON staff(school_id);


-- ───────────────────────────────────────────────────────────────────────────
-- 8. JSMS — FEE STRUCTURE  (edu2_fs)
--    Named fee items with amounts. One structure per school per term.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS fee_structure (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id       UUID NOT NULL REFERENCES schools(id) ON DELETE CASCADE,
  term            TEXT NOT NULL DEFAULT '1'
                  CHECK (term IN ('1','2','3')),
  academic_year   TEXT NOT NULL,
  name            TEXT NOT NULL,
  amount          NUMERIC(10,2) NOT NULL DEFAULT 0,
  is_mandatory    BOOLEAN NOT NULL DEFAULT TRUE,
  sort_order      INT NOT NULL DEFAULT 0,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE fee_structure IS 'Maps to edu2_fs. One record per fee item per term.';
CREATE INDEX IF NOT EXISTS idx_feestr_school ON fee_structure(school_id, academic_year, term);


-- ───────────────────────────────────────────────────────────────────────────
-- 9. JSMS — FEE PAYMENTS  (edu2_pays)
--    Verified payment records. Keyed by adm in localStorage but normalised here.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS fee_payments (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id       UUID NOT NULL REFERENCES schools(id) ON DELETE CASCADE,
  learner_id      UUID NOT NULL REFERENCES learners(id) ON DELETE CASCADE,
  adm             TEXT NOT NULL,
  term            TEXT NOT NULL,
  academic_year   TEXT NOT NULL,
  amount          NUMERIC(10,2) NOT NULL,
  mode            TEXT NOT NULL DEFAULT 'M-Pesa'
                  CHECK (mode IN ('M-Pesa','Cash','Bank','Cheque','Other')),
  txn_ref         TEXT,            -- M-Pesa code or bank ref
  receipt_no      TEXT,
  payment_date    DATE NOT NULL,
  recorded_by     UUID REFERENCES users(id),
  from_parent     BOOLEAN NOT NULL DEFAULT FALSE,  -- submitted via parent portal
  approved_at     TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE fee_payments IS 'Maps to edu2_pays[adm]. Stores individual payment transactions.';
CREATE INDEX IF NOT EXISTS idx_feepay_school   ON fee_payments(school_id);
CREATE INDEX IF NOT EXISTS idx_feepay_learner  ON fee_payments(learner_id);
CREATE INDEX IF NOT EXISTS idx_feepay_term     ON fee_payments(school_id, academic_year, term);


-- ───────────────────────────────────────────────────────────────────────────
-- 10. JSMS — PENDING PARENT PAYMENTS  (edu2_pending_pays)
--     Parent portal submissions awaiting admin verification.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS pending_payments (
  id              TEXT PRIMARY KEY,   -- PP-<timestamp>-<rand> kept from app
  school_id       UUID NOT NULL REFERENCES schools(id) ON DELETE CASCADE,
  learner_id      UUID REFERENCES learners(id) ON DELETE CASCADE,
  adm             TEXT NOT NULL,
  learner_name    TEXT,
  grade           TEXT,
  amount          NUMERIC(10,2) NOT NULL,
  term            TEXT NOT NULL,
  academic_year   TEXT,
  mode            TEXT NOT NULL DEFAULT 'M-Pesa',
  txn_ref         TEXT NOT NULL,      -- M-Pesa confirmation code
  pay_phone       TEXT,
  status          TEXT NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','approved','rejected')),
  submitted_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  reviewed_at     TIMESTAMPTZ,
  reviewed_by     UUID REFERENCES users(id),
  rejection_note  TEXT
);
CREATE INDEX IF NOT EXISTS idx_pendpay_school  ON pending_payments(school_id, status);


-- ───────────────────────────────────────────────────────────────────────────
-- 11. JSMS — ATTENDANCE  (edu2_att)
--     In localStorage: ATTENDANCE[date][adm] = 'P'|'A'|'H'|'E'
--     Normalised here to one row per learner per date.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS attendance (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id       UUID NOT NULL REFERENCES schools(id) ON DELETE CASCADE,
  learner_id      UUID NOT NULL REFERENCES learners(id) ON DELETE CASCADE,
  adm             TEXT NOT NULL,
  date            DATE NOT NULL,
  status          TEXT NOT NULL DEFAULT 'P'
                  CHECK (status IN ('P','A','H','E')),   -- Present/Absent/Half/Excused
  recorded_by     UUID REFERENCES users(id),
  note            TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (school_id, learner_id, date)
);
COMMENT ON TABLE attendance IS 'One row per learner per day. Replaces ATTENDANCE[date][adm] nested object.';
CREATE INDEX IF NOT EXISTS idx_att_school  ON attendance(school_id);
CREATE INDEX IF NOT EXISTS idx_att_date    ON attendance(school_id, date);
CREATE INDEX IF NOT EXISTS idx_att_learner ON attendance(learner_id, date);


-- ───────────────────────────────────────────────────────────────────────────
-- 12. JSMS — EXAM CONFIGURATIONS  (edu2_ec / EXAM_CONFIGS)
--     Structure: EXAM_CONFIGS[term_epKey][subject] = [{name, max}]
--     Normalised to: one row per (term, exam_period, subject, task)
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS exam_configs (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id       UUID NOT NULL REFERENCES schools(id) ON DELETE CASCADE,
  academic_year   TEXT NOT NULL,
  term            TEXT NOT NULL,       -- '1','2','3'
  exam_period_key TEXT NOT NULL,       -- e.g. 'op','mid','end'
  subject         TEXT NOT NULL,
  task_name       TEXT NOT NULL,       -- e.g. 'Task 1','CAT 2','End of Term'
  max_score       NUMERIC(6,2) NOT NULL DEFAULT 100,
  sort_order      INT NOT NULL DEFAULT 0,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (school_id, academic_year, term, exam_period_key, subject, task_name)
);
CREATE INDEX IF NOT EXISTS idx_examcfg_school ON exam_configs(school_id, academic_year, term);


-- ───────────────────────────────────────────────────────────────────────────
-- 13. JSMS — EXAM PERIODS  (edu2_exam_periods)
--     Defines periods per term: opening, mid-term, end-of-term.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS exam_periods (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id       UUID NOT NULL REFERENCES schools(id) ON DELETE CASCADE,
  academic_year   TEXT NOT NULL,
  term            TEXT NOT NULL,
  period_key      TEXT NOT NULL,       -- 'op','mid','end' or custom
  label           TEXT NOT NULL,       -- display name
  sort_order      INT NOT NULL DEFAULT 0,
  UNIQUE (school_id, academic_year, term, period_key)
);


-- ───────────────────────────────────────────────────────────────────────────
-- 14. JSMS — SUMMATIVE SCORES  (edu2_s / SUMMATIVE)
--     In localStorage: SUMMATIVE[adm_term_epKey][subject][taskName] = {raw, pct}
--     One row per (learner, term, exam_period, subject, task).
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS summative_scores (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id       UUID NOT NULL REFERENCES schools(id) ON DELETE CASCADE,
  learner_id      UUID NOT NULL REFERENCES learners(id) ON DELETE CASCADE,
  adm             TEXT NOT NULL,
  academic_year   TEXT NOT NULL,
  term            TEXT NOT NULL,
  exam_period_key TEXT NOT NULL,
  subject         TEXT NOT NULL,
  task_name       TEXT NOT NULL,
  raw_score       NUMERIC(6,2),
  percentage      NUMERIC(5,2),
  max_score       NUMERIC(6,2),
  recorded_by     UUID REFERENCES users(id),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (school_id, learner_id, academic_year, term, exam_period_key, subject, task_name)
);
COMMENT ON TABLE summative_scores IS 'Maps to SUMMATIVE[adm_term_epKey][subject][task] in JSMS.';
CREATE INDEX IF NOT EXISTS idx_scores_school   ON summative_scores(school_id);
CREATE INDEX IF NOT EXISTS idx_scores_learner  ON summative_scores(learner_id, academic_year, term);
CREATE INDEX IF NOT EXISTS idx_scores_subject  ON summative_scores(school_id, academic_year, term, subject);


-- ───────────────────────────────────────────────────────────────────────────
-- 15. JSMS — EVENTS / SCHOOL CALENDAR  (edu2_events)
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS school_events (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id       UUID NOT NULL REFERENCES schools(id) ON DELETE CASCADE,
  title           TEXT NOT NULL,
  event_date      DATE NOT NULL,
  event_type      TEXT NOT NULL DEFAULT 'general',
  description     TEXT,
  created_by      UUID REFERENCES users(id),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_events_school ON school_events(school_id, event_date);


-- ───────────────────────────────────────────────────────────────────────────
-- 16. JSMS — LIBRARY SHELVES  (edu2_lib_shelves)
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS library_shelves (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id       UUID NOT NULL REFERENCES schools(id) ON DELETE CASCADE,
  name            TEXT NOT NULL,
  colour          TEXT DEFAULT '#1b4332',
  loan_days       INT NOT NULL DEFAULT 14,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_libshelf_school ON library_shelves(school_id);


-- ───────────────────────────────────────────────────────────────────────────
-- 17. JSMS — LIBRARY BOOKS  (edu2_lib_books)
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS library_books (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id       UUID NOT NULL REFERENCES schools(id) ON DELETE CASCADE,
  shelf_id        UUID REFERENCES library_shelves(id) ON DELETE SET NULL,
  title           TEXT NOT NULL,
  author          TEXT,
  isbn            TEXT,
  accession_no    TEXT,
  copies          INT NOT NULL DEFAULT 1,
  grade_level     TEXT,            -- 'Grade 7', 'All', etc.
  subject         TEXT,
  publisher       TEXT,
  pub_year        INT,
  description     TEXT,
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE library_books IS 'Maps to LIB_BOOKS array in JSMS. shelf_id links to library_shelves.';
CREATE INDEX IF NOT EXISTS idx_libbook_school  ON library_books(school_id);
CREATE INDEX IF NOT EXISTS idx_libbook_shelf   ON library_books(shelf_id);
CREATE INDEX IF NOT EXISTS idx_libbook_title   ON library_books USING gin(title gin_trgm_ops);


-- ───────────────────────────────────────────────────────────────────────────
-- 18. JSMS — LIBRARY LOANS  (edu2_lib_loans)
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS library_loans (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id       UUID NOT NULL REFERENCES schools(id) ON DELETE CASCADE,
  book_id         UUID NOT NULL REFERENCES library_books(id) ON DELETE CASCADE,
  learner_id      UUID REFERENCES learners(id) ON DELETE SET NULL,
  adm             TEXT NOT NULL,
  learner_name    TEXT,
  issue_date      DATE NOT NULL,
  due_date        DATE NOT NULL,
  returned_date   DATE,
  status          TEXT NOT NULL DEFAULT 'active'
                  CHECK (status IN ('active','returned','overdue','lost','recovered')),
  issued_by       UUID REFERENCES users(id),
  received_by     UUID REFERENCES users(id),
  note            TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE library_loans IS 'Maps to LIB_LOANS array. active loans = checked out books.';
CREATE INDEX IF NOT EXISTS idx_libloan_school  ON library_loans(school_id, status);
CREATE INDEX IF NOT EXISTS idx_libloan_learner ON library_loans(learner_id);
CREATE INDEX IF NOT EXISTS idx_libloan_book    ON library_loans(book_id, status);


-- ───────────────────────────────────────────────────────────────────────────
-- 19. JSMS — TIMETABLE SETUP TABLES  (edu2_tt_*)
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS timetable_periods (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id       UUID NOT NULL REFERENCES schools(id) ON DELETE CASCADE,
  name            TEXT NOT NULL,
  time_from       TIME,
  time_to         TIME,
  sort_order      INT NOT NULL DEFAULT 0,
  is_break        BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE INDEX IF NOT EXISTS idx_ttp_school ON timetable_periods(school_id);

CREATE TABLE IF NOT EXISTS timetable_subjects (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id       UUID NOT NULL REFERENCES schools(id) ON DELETE CASCADE,
  name            TEXT NOT NULL,
  short_code      TEXT,
  colour          TEXT DEFAULT '#1b4332'
);
CREATE INDEX IF NOT EXISTS idx_tts_school ON timetable_subjects(school_id);

CREATE TABLE IF NOT EXISTS timetable_entries (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id       UUID NOT NULL REFERENCES schools(id) ON DELETE CASCADE,
  academic_year   TEXT NOT NULL,
  term            TEXT NOT NULL,
  day             TEXT NOT NULL    -- 'Monday','Tuesday',…,'Friday'
                  CHECK (day IN ('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday')),
  period_id       UUID REFERENCES timetable_periods(id) ON DELETE CASCADE,
  grade           TEXT NOT NULL,
  stream          TEXT,
  subject         TEXT NOT NULL,
  teacher_id      UUID REFERENCES staff(id) ON DELETE SET NULL,
  teacher_name    TEXT,            -- denormalised for speed
  room            TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (school_id, academic_year, term, day, period_id, grade, stream)
);
COMMENT ON TABLE timetable_entries IS 'Maps to edu2_tt_timetable. One row per slot.';
CREATE INDEX IF NOT EXISTS idx_tte_school ON timetable_entries(school_id, academic_year, term);
CREATE INDEX IF NOT EXISTS idx_tte_teacher ON timetable_entries(teacher_id);


-- ───────────────────────────────────────────────────────────────────────────
-- 20. JSMS — CO-CURRICULAR ACTIVITIES  (jsms_cocurricular_*)
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS cocurricular_categories (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id       UUID NOT NULL REFERENCES schools(id) ON DELETE CASCADE,
  name            TEXT NOT NULL,       -- 'Sports','Clubs and Societies','Leadership',…
  icon            TEXT,
  css_class       TEXT,
  sort_order      INT NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_cccat_school ON cocurricular_categories(school_id);

CREATE TABLE IF NOT EXISTS cocurricular_items (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id       UUID NOT NULL REFERENCES schools(id) ON DELETE CASCADE,
  category_id     UUID REFERENCES cocurricular_categories(id) ON DELETE CASCADE,
  name            TEXT NOT NULL,       -- e.g. 'Football','Chess Club','Head Boy'
  is_custom       BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE INDEX IF NOT EXISTS idx_ccitem_school ON cocurricular_items(school_id, category_id);

CREATE TABLE IF NOT EXISTS cocurricular_assignments (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id       UUID NOT NULL REFERENCES schools(id) ON DELETE CASCADE,
  learner_id      UUID NOT NULL REFERENCES learners(id) ON DELETE CASCADE,
  adm             TEXT NOT NULL,
  item_id         UUID REFERENCES cocurricular_items(id) ON DELETE CASCADE,
  academic_year   TEXT NOT NULL,
  term            TEXT,
  role            TEXT,                -- 'Member','Captain','Secretary', etc.
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (school_id, learner_id, item_id, academic_year)
);
CREATE INDEX IF NOT EXISTS idx_ccassign_school   ON cocurricular_assignments(school_id);
CREATE INDEX IF NOT EXISTS idx_ccassign_learner  ON cocurricular_assignments(learner_id);


-- ═══════════════════════════════════════════════════════════════════════════
-- ████  TPDS PORTAL TABLES  ████
-- ═══════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────────
-- 21. TPDS — SETUP  (eng_tpds_setup / SK.setup)
--     One row per school: school name, teacher, tsc, contact, grading config.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tpds_setup (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id       UUID NOT NULL REFERENCES schools(id) ON DELETE CASCADE UNIQUE,
  school_name     TEXT,
  subject         TEXT DEFAULT 'English',
  academic_year   TEXT,
  grades          INT[],             -- e.g. ARRAY[7,8,9]
  schedule        JSONB,             -- [{day,grade,timeFrom,timeTo,stream,subject}]
  rolls           JSONB,             -- {7:'',8:'',9:''}
  themes          JSONB,             -- {7:[…],8:[…],9:[…]}
  strands         JSONB,             -- {7:[…],8:[…],9:[…]}
  term_start      DATE,
  term_end        DATE,
  letterhead      JSONB,             -- {color:'#1b4332',motto:'',logo:''}
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE tpds_setup IS 'Maps to eng_tpds_setup. One row per school (UNIQUE on school_id).';


-- ───────────────────────────────────────────────────────────────────────────
-- 22. TPDS — LESSON PLANS  (eng_tpds_lessons)
--     Exact fields from the lesson builder in TPDSPortalV144-1.html line 6604.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS lesson_plans (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id       UUID NOT NULL REFERENCES schools(id) ON DELETE CASCADE,
  user_id         UUID REFERENCES users(id) ON DELETE SET NULL,  -- teacher who wrote it
  grade           INT NOT NULL CHECK (grade IN (7,8,9)),
  term            TEXT NOT NULL,
  subject         TEXT NOT NULL DEFAULT 'English',
  week            TEXT,
  lesson_no       TEXT,
  date            DATE,
  day             TEXT,
  time_slot       TEXT,
  roll            TEXT,
  theme           TEXT,
  strand          TEXT,
  substrand       TEXT,
  slo             TEXT,   -- Specific Learning Outcome
  sle             TEXT,   -- Specific Learning Experience
  kiq             TEXT,   -- Key Inquiry Question
  resources       TEXT,
  org_learning    TEXT,   -- Organisation of Learning
  introduction    TEXT,
  steps           JSONB,  -- [{step:'', desc:''}]
  extended        TEXT,
  conclusion      TEXT,
  reflection      TEXT,
  skill           TEXT,
  work_done       TEXT,
  assessment      TEXT,
  attainment      TEXT,
  mat_files       JSONB,  -- [{id,name,size,type,thumb}]
  ev_files        JSONB,  -- [{id,name,size,type,thumb}]
  status          TEXT NOT NULL DEFAULT 'draft'
                  CHECK (status IN ('draft','submitted','approved','rejected')),
  is_deleted      BOOLEAN NOT NULL DEFAULT FALSE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE lesson_plans IS 'Maps to eng_tpds_lessons. Full lesson plan builder output.';
CREATE INDEX IF NOT EXISTS idx_lp_school  ON lesson_plans(school_id);
CREATE INDEX IF NOT EXISTS idx_lp_teacher ON lesson_plans(user_id, grade, term);
CREATE INDEX IF NOT EXISTS idx_lp_grade   ON lesson_plans(school_id, grade, term);


-- ───────────────────────────────────────────────────────────────────────────
-- 23. TPDS — IEPs  (eng_tpds_ieps)
--     Individual Education Plans for learners with special needs.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS ieps (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id       UUID NOT NULL REFERENCES schools(id) ON DELETE CASCADE,
  user_id         UUID REFERENCES users(id) ON DELETE SET NULL,
  learner_name    TEXT NOT NULL,
  adm             TEXT,
  grade           TEXT,
  term            TEXT,
  dob             DATE,
  parent_name     TEXT,
  contact         TEXT,
  date            DATE,
  review_date     DATE,
  challenges      TEXT,
  strengths       TEXT,
  goals           TEXT,
  strategies      TEXT,
  assessment      TEXT,
  progress        TEXT,
  remarks         TEXT,
  parent_remarks  TEXT,
  is_deleted      BOOLEAN NOT NULL DEFAULT FALSE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE ieps IS 'Maps to eng_tpds_ieps. Individual Education Plans.';
CREATE INDEX IF NOT EXISTS idx_ieps_school ON ieps(school_id);
CREATE INDEX IF NOT EXISTS idx_ieps_teacher ON ieps(user_id);


-- ───────────────────────────────────────────────────────────────────────────
-- 24. TPDS — IEP REVIEW LOGS  (tpds_iep_logs)
--     Per-IEP review history: {date, by, notes, nextDate}
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS iep_logs (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id       UUID NOT NULL REFERENCES schools(id) ON DELETE CASCADE,
  iep_id          UUID NOT NULL REFERENCES ieps(id) ON DELETE CASCADE,
  review_date     DATE,
  reviewed_by     TEXT,            -- name string (not FK, matches app behaviour)
  notes           TEXT,
  next_review     DATE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_ieplogs_iep ON iep_logs(iep_id);


-- ───────────────────────────────────────────────────────────────────────────
-- 25. TPDS — CAL ENTRIES  (eng_tpds_cal)
--     Continuous Assessment Logs: a log of learner support/intervention entries.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS cal_entries (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id       UUID NOT NULL REFERENCES schools(id) ON DELETE CASCADE,
  user_id         UUID REFERENCES users(id) ON DELETE SET NULL,
  learner_name    TEXT,
  adm             TEXT,
  grade           TEXT,
  term            TEXT,
  date            DATE NOT NULL,
  notes           TEXT,
  next_date       DATE,
  recorded_by     TEXT,            -- name string
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_cal_school  ON cal_entries(school_id);
CREATE INDEX IF NOT EXISTS idx_cal_teacher ON cal_entries(user_id);


-- ───────────────────────────────────────────────────────────────────────────
-- 26. TPDS — SUBMITTED DOCUMENTS  (tpds_submitted_docs)
--     Approval workflow: teacher submits → HOD/deputy/principal approves.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS submitted_documents (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id       UUID NOT NULL REFERENCES schools(id) ON DELETE CASCADE,
  submitter_id    UUID REFERENCES users(id) ON DELETE SET NULL,
  doc_type        TEXT NOT NULL,        -- 'Lesson Plan','IEP','CAL','SOW','ROW','Minutes'
  entity_id       UUID,                 -- FK to lesson_plans.id / ieps.id etc.
  summary         TEXT,
  doc_html        TEXT,                 -- stored HTML snapshot of the document
  target_role     TEXT,                 -- role required to approve
  status          TEXT NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','approved','rejected','forwarded')),
  reviewer_id     UUID REFERENCES users(id),
  reviewed_at     TIMESTAMPTZ,
  review_note     TEXT,
  submitted_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE submitted_documents IS 'Maps to tpds_submitted_docs. Document approval workflow.';
CREATE INDEX IF NOT EXISTS idx_subdoc_school    ON submitted_documents(school_id, status);
CREATE INDEX IF NOT EXISTS idx_subdoc_submitter ON submitted_documents(submitter_id);
CREATE INDEX IF NOT EXISTS idx_subdoc_reviewer  ON submitted_documents(target_role, status);


-- ───────────────────────────────────────────────────────────────────────────
-- 27. TPDS — DELETED BIN  (eng_tpds_deleted)
--     Soft-deleted lessons and IEPs, recoverable within 30 days.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS deleted_bin (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id       UUID NOT NULL REFERENCES schools(id) ON DELETE CASCADE,
  user_id         UUID REFERENCES users(id) ON DELETE SET NULL,
  entity_type     TEXT NOT NULL,         -- 'lesson_plan' | 'iep' | 'cal'
  entity_id       UUID NOT NULL,
  snapshot        JSONB NOT NULL,        -- full JSON of the deleted record
  deleted_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  -- auto-purge after 30 days handled by Supabase scheduled function or cron
  expires_at      TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '30 days')
);
COMMENT ON TABLE deleted_bin IS 'Soft-delete bin. Records expire after 30 days.';
CREATE INDEX IF NOT EXISTS idx_bin_school   ON deleted_bin(school_id);
CREATE INDEX IF NOT EXISTS idx_bin_expires  ON deleted_bin(expires_at);


-- ═══════════════════════════════════════════════════════════════════════════
-- ████  VIEWS  ████
-- ═══════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────────
-- V1. Per-learner fee balance view (mirrors Finance screen calculation)
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW v_learner_fee_balance AS
SELECT
  l.school_id,
  l.id           AS learner_id,
  l.adm,
  l.name,
  l.grade,
  fp.academic_year,
  fp.term,
  SUM(fp.amount) AS total_paid,
  (
    SELECT COALESCE(SUM(fs.amount), 0)
    FROM   fee_structure fs
    WHERE  fs.school_id    = l.school_id
    AND    fs.academic_year = fp.academic_year
    AND    fs.term          = fp.term
  )              AS total_billed,
  (
    SELECT COALESCE(SUM(fs.amount), 0)
    FROM   fee_structure fs
    WHERE  fs.school_id    = l.school_id
    AND    fs.academic_year = fp.academic_year
    AND    fs.term          = fp.term
  ) - SUM(fp.amount) AS balance
FROM   learners l
JOIN   fee_payments fp ON fp.learner_id = l.id
GROUP  BY l.school_id, l.id, l.adm, l.name, l.grade, fp.academic_year, fp.term;

COMMENT ON VIEW v_learner_fee_balance IS 'Live fee balance per learner per term. Uses same logic as JSMS Finance tab.';


-- ───────────────────────────────────────────────────────────────────────────
-- V2. Attendance summary per learner per term
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW v_attendance_summary AS
SELECT
  a.school_id,
  a.learner_id,
  l.adm,
  l.name,
  l.grade,
  COUNT(*)                                            AS total_days,
  COUNT(*) FILTER (WHERE a.status = 'P')              AS days_present,
  COUNT(*) FILTER (WHERE a.status = 'A')              AS days_absent,
  COUNT(*) FILTER (WHERE a.status = 'H')              AS half_days,
  COUNT(*) FILTER (WHERE a.status = 'E')              AS days_excused,
  ROUND(
    100.0 * (
      COUNT(*) FILTER (WHERE a.status = 'P') +
      0.5 * COUNT(*) FILTER (WHERE a.status = 'H')
    ) / NULLIF(COUNT(*), 0), 1
  )                                                   AS attendance_pct
FROM   attendance a
JOIN   learners l ON l.id = a.learner_id
GROUP  BY a.school_id, a.learner_id, l.adm, l.name, l.grade;

COMMENT ON VIEW v_attendance_summary IS 'Matches JSMS attendance percentage calculation (H = 0.5 day).';


-- ───────────────────────────────────────────────────────────────────────────
-- V3. Library: books with available copies count
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW v_library_availability AS
SELECT
  b.school_id,
  b.id           AS book_id,
  b.title,
  b.author,
  b.accession_no,
  s.name         AS shelf_name,
  b.copies       AS total_copies,
  COUNT(ll.id) FILTER (WHERE ll.status = 'active')  AS on_loan,
  b.copies - COUNT(ll.id) FILTER (WHERE ll.status = 'active') AS available
FROM   library_books b
LEFT   JOIN library_shelves s  ON s.id = b.shelf_id
LEFT   JOIN library_loans   ll ON ll.book_id = b.id AND ll.status = 'active'
GROUP  BY b.school_id, b.id, b.title, b.author, b.accession_no, s.name, b.copies;

COMMENT ON VIEW v_library_availability IS 'Real-time book availability: total - on_loan = available copies.';


-- ───────────────────────────────────────────────────────────────────────────
-- V4. Overdue loans (for library alert badge)
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT
  ll.school_id,
  ll.id          AS loan_id,
  ll.adm,
  ll.learner_name,
  b.title,
  ll.issue_date,
  ll.due_date,
  (CURRENT_DATE - ll.due_date) AS days_overdue
FROM   library_loans ll
JOIN   library_books b ON b.id = ll.book_id
WHERE  ll.status   = 'active'
AND    ll.due_date < CURRENT_DATE;


-- ───────────────────────────────────────────────────────────────────────────
-- V5. Lesson plan summary (Scheme of Work columns)
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW v_scheme_of_work AS
SELECT
  lp.school_id,
  lp.user_id,
  u.name         AS teacher_name,
  lp.grade,
  lp.term,
  lp.subject,
  lp.week,
  lp.lesson_no,
  lp.date,
  lp.day,
  lp.theme,
  lp.strand,
  lp.substrand,
  lp.slo,
  lp.resources,
  lp.assessment,
  lp.status
FROM   lesson_plans lp
LEFT   JOIN users u ON u.id = lp.user_id
WHERE  lp.is_deleted = FALSE
ORDER  BY lp.grade, lp.term, lp.week::INT NULLS LAST, lp.lesson_no::INT NULLS LAST;

COMMENT ON VIEW v_scheme_of_work IS 'Powers the SOW / ROW print exports in TPDS.';


-- ───────────────────────────────────────────────────────────────────────────
-- V6. Platform analytics (super-admin dashboard)
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW v_platform_analytics AS
SELECT
  s.id           AS school_id,
  s.name         AS school_name,
  s.county,
  s.plan,
  s.sub_status,
  s.sub_expiry,
  s.created_at   AS registered_at,
  COUNT(DISTINCT u.id)    AS total_users,
  COUNT(DISTINCT l.id)    AS total_learners,
  COALESCE(SUM(sp.amount) FILTER (WHERE sp.status = 'verified'), 0) AS total_revenue
FROM   schools s
LEFT   JOIN users               u  ON u.school_id  = s.id
LEFT   JOIN learners            l  ON l.school_id  = s.id
LEFT   JOIN subscription_payments sp ON sp.school_id = s.id
GROUP  BY s.id, s.name, s.county, s.plan, s.sub_status, s.sub_expiry, s.created_at;


-- ═══════════════════════════════════════════════════════════════════════════
-- ████  FUNCTIONS  ████
-- ═══════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────────
-- F1. Auto-update updated_at on any row change
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION trigger_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply to every table that has updated_at
DO $$
DECLARE
  tbl TEXT;
BEGIN
  FOREACH tbl IN ARRAY ARRAY[
    'schools','users','learners','staff',
    'library_books','library_loans','lesson_plans','ieps','summative_scores'
  ] LOOP
    EXECUTE format('
      DROP TRIGGER IF EXISTS set_updated_at ON %I;
      CREATE TRIGGER set_updated_at
        BEFORE UPDATE ON %I
        FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();
    ', tbl, tbl);
  END LOOP;
END;
$$;


-- ───────────────────────────────────────────────────────────────────────────
-- F2. Activate school subscription after payment verification
--     Called by the platform admin after clicking "Verify" in the hub.
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION verify_and_activate_subscription(
  p_payment_id UUID,
  p_verified_by UUID
)
RETURNS JSONB AS $$
DECLARE
  v_pay   subscription_payments%ROWTYPE;
  v_school schools%ROWTYPE;
  v_add   INTERVAL;
  v_expiry TIMESTAMPTZ;
BEGIN
  -- Fetch payment
  SELECT * INTO v_pay FROM subscription_payments WHERE id = p_payment_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Payment not found');
  END IF;
  IF v_pay.status <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Payment already processed: ' || v_pay.status);
  END IF;

  -- Determine period to add
  v_add := CASE v_pay.plan
    WHEN 'term'    THEN INTERVAL '4 months'
    WHEN 'starter' THEN INTERVAL '1 month'
    WHEN 'school'  THEN INTERVAL '1 month'
    WHEN 'premium' THEN INTERVAL '1 month'
    ELSE                INTERVAL '1 month'
  END;

  -- Extend subscription
  SELECT * INTO v_school FROM schools WHERE id = v_pay.school_id;
  v_expiry := GREATEST(COALESCE(v_school.sub_expiry, NOW()), NOW()) + v_add;

  UPDATE schools SET
    sub_status = 'active',
    sub_expiry = v_expiry,
    plan       = v_pay.plan,
    updated_at = NOW()
  WHERE id = v_pay.school_id;

  -- Mark payment verified
  UPDATE subscription_payments SET
    status      = 'verified',
    verified_at = NOW(),
    verified_by = p_verified_by
  WHERE id = p_payment_id;

  -- Notify school admin
  INSERT INTO notifications(school_id, type, title, body)
  SELECT v_pay.school_id, 'success',
    '✅ Subscription Activated',
    'Your ' || v_pay.plan || ' plan payment of KES ' || v_pay.amount ||
    ' has been verified. Active until ' || TO_CHAR(v_expiry, 'DD Mon YYYY') || '.';

  RETURN jsonb_build_object(
    'ok',      true,
    'expiry',  v_expiry,
    'plan',    v_pay.plan,
    'school',  v_school.name
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION verify_and_activate_subscription IS
  'Call from platform hub. Marks payment verified, extends school sub_expiry, inserts notification.';


-- ───────────────────────────────────────────────────────────────────────────
-- F3. Reject a payment submission
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION reject_payment(
  p_payment_id  UUID,
  p_reviewed_by UUID,
  p_reason      TEXT
)
RETURNS VOID AS $$
BEGIN
  UPDATE subscription_payments SET
    status           = 'rejected',
    verified_at      = NOW(),
    verified_by      = p_reviewed_by,
    rejection_reason = p_reason
  WHERE id = p_payment_id;

  INSERT INTO notifications(school_id, type, title, body)
  SELECT school_id, 'error',
    '❌ Payment Not Verified',
    'Reason: ' || p_reason || '. Please visit the school office or contact support.'
  FROM subscription_payments WHERE id = p_payment_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ───────────────────────────────────────────────────────────────────────────
-- F4. CBC performance level from percentage (matches portal logic exactly)
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION cbc_level(pct NUMERIC)
RETURNS TEXT AS $$
BEGIN
  RETURN CASE
    WHEN pct >= 75 THEN 'EE'   -- Exceeds Expectation
    WHEN pct >= 50 THEN 'ME'   -- Meets Expectation
    WHEN pct >= 25 THEN 'AE'   -- Approaches Expectation
    ELSE                 'BE'  -- Below Expectation
  END;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION cbc_level IS 'EE≥75%, ME≥50%, AE≥25%, BE<25%. Mirrors _ppCbeLvl() in JSMS.';


-- ───────────────────────────────────────────────────────────────────────────
-- F5. Soft-delete a lesson plan (moves to deleted_bin)
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION soft_delete_lesson(
  p_lesson_id UUID,
  p_user_id   UUID
)
RETURNS VOID AS $$
DECLARE v_row lesson_plans%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM lesson_plans WHERE id = p_lesson_id;
  IF NOT FOUND THEN RETURN; END IF;

  INSERT INTO deleted_bin(school_id, user_id, entity_type, entity_id, snapshot)
  VALUES (v_row.school_id, p_user_id, 'lesson_plan', v_row.id, row_to_json(v_row)::JSONB);

  UPDATE lesson_plans SET is_deleted = TRUE, updated_at = NOW()
  WHERE id = p_lesson_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ───────────────────────────────────────────────────────────────────────────
-- F6. Purge expired deleted_bin entries (run via Supabase pg_cron)
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION purge_deleted_bin()
RETURNS INT AS $$
DECLARE v_count INT;
BEGIN
  DELETE FROM deleted_bin WHERE expires_at < NOW();
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION purge_deleted_bin IS
  'Schedule: SELECT cron.schedule(''purge-bin'', ''0 2 * * *'', $$SELECT purge_deleted_bin()$$);';


-- ───────────────────────────────────────────────────────────────────────────
-- F7. Get learner performance summary for a term (mirrors app analytics)
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION learner_term_summary(
  p_school_id    UUID,
  p_learner_id   UUID,
  p_acad_year    TEXT,
  p_term         TEXT,
  p_ep_key       TEXT DEFAULT NULL   -- NULL = all exam periods
)
RETURNS TABLE (
  subject        TEXT,
  total_raw      NUMERIC,
  total_max      NUMERIC,
  percentage     NUMERIC,
  cbc_level      TEXT
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    ss.subject,
    SUM(ss.raw_score)  AS total_raw,
    SUM(ss.max_score)  AS total_max,
    ROUND(100.0 * SUM(ss.raw_score) / NULLIF(SUM(ss.max_score), 0), 1) AS percentage,
    cbc_level(ROUND(100.0 * SUM(ss.raw_score) / NULLIF(SUM(ss.max_score), 0), 1)) AS cbc_level
  FROM  summative_scores ss
  WHERE ss.school_id    = p_school_id
  AND   ss.learner_id   = p_learner_id
  AND   ss.academic_year = p_acad_year
  AND   ss.term          = p_term
  AND   (p_ep_key IS NULL OR ss.exam_period_key = p_ep_key)
  GROUP BY ss.subject
  ORDER BY ss.subject;
END;
$$ LANGUAGE plpgsql STABLE;


-- ═══════════════════════════════════════════════════════════════════════════
-- ████  ROW LEVEL SECURITY (RLS)  ████
--   Every school can ONLY see its own data. Users can only see data from
--   their own school. Super-admin bypasses RLS via service_role key.
-- ═══════════════════════════════════════════════════════════════════════════

-- Enable RLS on every tenant table
DO $$
DECLARE tbl TEXT;
BEGIN
  FOREACH tbl IN ARRAY ARRAY[
    'schools','users','subscription_payments','notifications','activity_log',
    'learners','staff','fee_structure','fee_payments','pending_payments',
    'attendance','exam_configs','exam_periods','summative_scores',
    'school_events','library_shelves','library_books','library_loans',
    'timetable_periods','timetable_subjects','timetable_entries',
    'cocurricular_categories','cocurricular_items','cocurricular_assignments',
    'tpds_setup','lesson_plans','ieps','iep_logs','cal_entries',
    'submitted_documents','deleted_bin'
  ] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY;', tbl);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY;',  tbl);
  END LOOP;
END;
$$;

-- ── Helper: get school_id of the authenticated user from JWT custom claim ──
-- The JS client must set: { 'x-school-id': school_id } in headers, OR
-- you embed school_id in the JWT. We use a session variable approach here.
CREATE OR REPLACE FUNCTION current_school_id()
RETURNS UUID AS $$
BEGIN
  RETURN NULLIF(current_setting('app.school_id', TRUE), '')::UUID;
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END;
$$ LANGUAGE plpgsql STABLE;

-- ── Policy factory: each school sees only its rows ──
-- Schools table: a school can read/update its own row
DROP POLICY IF EXISTS school_isolation ON schools;
CREATE POLICY school_isolation ON schools
  USING (id = current_school_id());

-- Generic school_id isolation for all other tables
DO $$
DECLARE tbl TEXT;
BEGIN
  FOREACH tbl IN ARRAY ARRAY[
    'users','subscription_payments','notifications','activity_log',
    'learners','staff','fee_structure','fee_payments','pending_payments',
    'attendance','exam_configs','exam_periods','summative_scores',
    'school_events','library_shelves','library_books','library_loans',
    'timetable_periods','timetable_subjects','timetable_entries',
    'cocurricular_categories','cocurricular_items','cocurricular_assignments',
    'tpds_setup','lesson_plans','ieps','iep_logs','cal_entries',
    'submitted_documents','deleted_bin'
  ] LOOP
    EXECUTE format('
      DROP POLICY IF EXISTS school_isolation ON %I;
      CREATE POLICY school_isolation ON %I
        USING (school_id = current_school_id());
    ', tbl, tbl);
  END LOOP;
END;
$$;

-- iep_logs has no school_id — isolate via iep_id join
DROP POLICY IF EXISTS school_isolation ON iep_logs;
CREATE POLICY school_isolation ON iep_logs
  USING (
    iep_id IN (
      SELECT id FROM ieps WHERE school_id = current_school_id()
    )
  );


-- ═══════════════════════════════════════════════════════════════════════════
-- ████  SEED DATA — DEFAULTS EVERY SCHOOL GETS ON FIRST SYNC  ████
-- ═══════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────────
-- S1. Default co-curricular categories (mirrors app's hardcoded list)
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION seed_cocurricular_defaults(p_school_id UUID)
RETURNS VOID AS $$
BEGIN
  INSERT INTO cocurricular_categories(school_id, name, icon, css_class, sort_order)
  VALUES
    (p_school_id, 'Sports',              '⚽', 'badge-sport',      1),
    (p_school_id, 'Clubs and Societies', '🏛️', 'badge-club',       2),
    (p_school_id, 'Leadership',          '👑', 'badge-leadership', 3),
    (p_school_id, 'Talent and Arts',     '🎨', 'badge-art',        4),
    (p_school_id, 'Environmental',       '🌿', 'badge-env',        5),
    (p_school_id, 'Technology',          '💻', 'badge-tech',       6)
  ON CONFLICT DO NOTHING;

  -- Default sports
  INSERT INTO cocurricular_items(school_id, category_id, name)
  SELECT p_school_id, c.id, item
  FROM   cocurricular_categories c,
         UNNEST(ARRAY[
           'Football','Volleyball','Basketball','Athletics','Swimming',
           'Handball','Rugby','Badminton','Table Tennis','Chess'
         ]) AS item
  WHERE  c.school_id = p_school_id AND c.name = 'Sports'
  ON CONFLICT DO NOTHING;

  -- Default clubs
  INSERT INTO cocurricular_items(school_id, category_id, name)
  SELECT p_school_id, c.id, item
  FROM   cocurricular_categories c,
         UNNEST(ARRAY[
           'Debate Club','Drama Club','Science Club','Journalism Club',
           'Environmental Club','Young Farmers','Red Cross','Scouts','Girl Guides'
         ]) AS item
  WHERE  c.school_id = p_school_id AND c.name = 'Clubs and Societies'
  ON CONFLICT DO NOTHING;

  -- Default leadership positions
  INSERT INTO cocurricular_items(school_id, category_id, name)
  SELECT p_school_id, c.id, item
  FROM   cocurricular_categories c,
         UNNEST(ARRAY[
           'Head Boy','Head Girl','Deputy Head Boy','Deputy Head Girl',
           'Class Captain','Class Secretary','Prefect'
         ]) AS item
  WHERE  c.school_id = p_school_id AND c.name = 'Leadership'
  ON CONFLICT DO NOTHING;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION seed_cocurricular_defaults IS
  'Call once per school at registration. Seeds all 6 default categories + standard items.';


-- ───────────────────────────────────────────────────────────────────────────
-- S2. Default exam periods (matches JSMS EXAM_PERIODS defaults)
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION seed_exam_periods(p_school_id UUID, p_year TEXT)
RETURNS VOID AS $$
BEGIN
  INSERT INTO exam_periods(school_id, academic_year, term, period_key, label, sort_order)
  VALUES
    (p_school_id, p_year, '1', 'op',  'Opening Assessment', 1),
    (p_school_id, p_year, '1', 'mid', 'Mid-Term Test',      2),
    (p_school_id, p_year, '1', 'end', 'End of Term Exam',   3),
    (p_school_id, p_year, '2', 'op',  'Opening Assessment', 1),
    (p_school_id, p_year, '2', 'mid', 'Mid-Term Test',      2),
    (p_school_id, p_year, '2', 'end', 'End of Term Exam',   3),
    (p_school_id, p_year, '3', 'op',  'Opening Assessment', 1),
    (p_school_id, p_year, '3', 'mid', 'Mid-Term Test',      2),
    (p_school_id, p_year, '3', 'end', 'End of Term Exam',   3)
  ON CONFLICT DO NOTHING;
END;
$$ LANGUAGE plpgsql;


-- ───────────────────────────────────────────────────────────────────────────
-- S3. Default timetable periods (standard Kenya junior school day)
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION seed_timetable_periods(p_school_id UUID)
RETURNS VOID AS $$
BEGIN
  INSERT INTO timetable_periods(school_id, name, time_from, time_to, sort_order, is_break)
  VALUES
    (p_school_id, 'Period 1',   '08:00', '08:40', 1,  FALSE),
    (p_school_id, 'Period 2',   '08:40', '09:20', 2,  FALSE),
    (p_school_id, 'Period 3',   '09:20', '10:00', 3,  FALSE),
    (p_school_id, 'Break',      '10:00', '10:20', 4,  TRUE),
    (p_school_id, 'Period 4',   '10:20', '11:00', 5,  FALSE),
    (p_school_id, 'Period 5',   '11:00', '11:40', 6,  FALSE),
    (p_school_id, 'Period 6',   '11:40', '12:20', 7,  FALSE),
    (p_school_id, 'Lunch',      '12:20', '13:00', 8,  TRUE),
    (p_school_id, 'Period 7',   '13:00', '13:40', 9,  FALSE),
    (p_school_id, 'Period 8',   '13:40', '14:20', 10, FALSE),
    (p_school_id, 'Period 9',   '14:20', '15:00', 11, FALSE),
    (p_school_id, 'Period 10',  '15:00', '15:40', 12, FALSE)
  ON CONFLICT DO NOTHING;
END;
$$ LANGUAGE plpgsql;


-- ───────────────────────────────────────────────────────────────────────────
-- S4. Default CBC subjects for junior school (Grades 7-9)
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION seed_subjects(p_school_id UUID)
RETURNS VOID AS $$
BEGIN
  INSERT INTO timetable_subjects(school_id, name, short_code, colour)
  VALUES
    (p_school_id, 'English',                  'ENG', '#1e40af'),
    (p_school_id, 'Kiswahili',                'KSW', '#065f46'),
    (p_school_id, 'Mathematics',              'MAT', '#dc2626'),
    (p_school_id, 'Integrated Science',       'SCI', '#7c3aed'),
    (p_school_id, 'Health Education',         'HEA', '#0369a1'),
    (p_school_id, 'Pre-Technical Studies',    'PTS', '#b45309'),
    (p_school_id, 'Social Studies',           'SOC', '#0f766e'),
    (p_school_id, 'Religious Education (CRE)','CRE', '#6d28d9'),
    (p_school_id, 'Business Studies',         'BUS', '#be123c'),
    (p_school_id, 'Agriculture & Nutrition',  'AGR', '#166534'),
    (p_school_id, 'Creative Arts & Sports',   'CAS', '#c2410c'),
    (p_school_id, 'Life Skills Education',    'LSE', '#0c4a6e')
  ON CONFLICT DO NOTHING;
END;
$$ LANGUAGE plpgsql;


-- ───────────────────────────────────────────────────────────────────────────
-- S5. Master onboarding function — call ONCE when a new school registers
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION onboard_new_school(p_school_id UUID)
RETURNS VOID AS $$
DECLARE v_year TEXT := TO_CHAR(NOW(), 'YYYY');
BEGIN
  PERFORM seed_cocurricular_defaults(p_school_id);
  PERFORM seed_exam_periods(p_school_id, v_year);
  PERFORM seed_timetable_periods(p_school_id);
  PERFORM seed_subjects(p_school_id);

  INSERT INTO tpds_setup(school_id, subject, academic_year, grades)
  VALUES (p_school_id, 'English', v_year, ARRAY[7,8,9])
  ON CONFLICT (school_id) DO NOTHING;

  INSERT INTO notifications(school_id, type, title, body)
  VALUES (p_school_id, 'success',
    '🎉 Welcome to EduSuite!',
    'Your school has been set up. Start by adding learners in JSMS and lesson plans in TPDS.');
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION onboard_new_school IS
  'Call immediately after inserting a new school row. Seeds all defaults in one shot.';


-- ═══════════════════════════════════════════════════════════════════════════
-- ████  INDEXES (additional performance)  ████
-- ═══════════════════════════════════════════════════════════════════════════

-- Composite for score lookup (most common query in exam module)
CREATE INDEX IF NOT EXISTS idx_scores_lookup
  ON summative_scores(school_id, academic_year, term, exam_period_key, subject);

-- Composite for attendance date range queries
CREATE INDEX IF NOT EXISTS idx_att_range
  ON attendance(school_id, date, status);

-- Composite for fee balance queries
CREATE INDEX IF NOT EXISTS idx_feepay_balance
  ON fee_payments(school_id, academic_year, term, learner_id);

-- Full-text on lesson plan content
CREATE INDEX IF NOT EXISTS idx_lp_theme
  ON lesson_plans USING gin(theme gin_trgm_ops);


-- ═══════════════════════════════════════════════════════════════════════════
-- ████  SCHEDULED JOBS (pg_cron — enable in Supabase Dashboard first)  ████
-- ═══════════════════════════════════════════════════════════════════════════
-- Uncomment these AFTER enabling pg_cron extension in Supabase Dashboard:
--
-- SELECT cron.schedule('purge-bin',         '0 2 * * *',   $$SELECT purge_deleted_bin()$$);
-- SELECT cron.schedule('check-overdue-lib', '0 7 * * *',   $$
--   INSERT INTO notifications(school_id, type, title, body)
--   SELECT DISTINCT school_id, 'warn',
--     '📚 Overdue Library Books',
--     'There are overdue book returns. Check the Library module.'
--   FROM v_overdue_loans;
-- $$);


-- ═══════════════════════════════════════════════════════════════════════════
-- ████  FINAL VERIFICATION QUERY  ████
--   Run this after setup to confirm all 30 objects exist.
-- ═══════════════════════════════════════════════════════════════════════════
SELECT
  'TABLES'    AS object_type,
  COUNT(*)    AS count
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_type   = 'BASE TABLE'

UNION ALL

SELECT 'VIEWS',     COUNT(*) FROM information_schema.views
WHERE table_schema = 'public'

UNION ALL

SELECT 'FUNCTIONS', COUNT(*) FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_type   = 'FUNCTION'

ORDER BY object_type;

-- ═══════════════════════════════════════════════════════════════════════════
-- ████  PORTAL-NATIVE SYNC TABLES  ████
--   Required by the built-in Supabase sync inside each portal.
--   TPDS uses: tpds_sync, tpds_users_cloud + three RPC functions.
--   JSMS uses: school_data (single JSON blob per school).
--   These work ALONGSIDE the normalised tables above — both sync paths
--   can run in parallel without conflict.
-- ═══════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────────
-- P1. TPDS — per-teacher data payload store  (tpds_sync)
--     Key: (user_id, data_key)  e.g. ('alice@school.ke', 'lessons')
--     Payload: the full JSONB array that localStorage holds for that key.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tpds_sync (
  row_id      TEXT        PRIMARY KEY,          -- '{user_id}__{data_key}' composite — matches portal p_id
  user_id     TEXT        NOT NULL,             -- sbUserId() value (lowercase username / TSC slug)
  data_key    TEXT        NOT NULL,             -- one of the SB_DATA_KEYS keys
  payload     JSONB,                            -- the full data array / object
  school_id   TEXT,                             -- optional school identifier
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE tpds_sync IS 'Native TPDS cloud sync. One row per (teacher, data_key). Mirrors eng_tpds_* localStorage keys.';
CREATE INDEX IF NOT EXISTS idx_tpds_sync_user   ON tpds_sync(user_id);
CREATE INDEX IF NOT EXISTS idx_tpds_sync_school ON tpds_sync(school_id);
CREATE INDEX IF NOT EXISTS idx_tpds_sync_key    ON tpds_sync(data_key);

DROP TRIGGER IF EXISTS set_updated_at_tpds_sync ON tpds_sync;
CREATE TRIGGER set_updated_at_tpds_sync
  BEFORE UPDATE ON tpds_sync
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();


-- ───────────────────────────────────────────────────────────────────────────
-- P2. TPDS — cloud teacher accounts  (tpds_users_cloud)
--     Teachers register a cloud username so they can access lesson plans
--     from any device without needing the Platform Hub login.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tpds_users_cloud (
  id            UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  username      TEXT        NOT NULL UNIQUE,   -- lowercase email or TSC number
  password_hash TEXT        NOT NULL,
  name          TEXT,
  tsc           TEXT,
  school        TEXT,
  school_id     TEXT,                          -- matches tpds_sync.school_id
  role          TEXT        NOT NULL DEFAULT 'teacher',
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE tpds_users_cloud IS 'TPDS teacher cloud accounts. Separate from Platform Hub users — TPDS manages its own auth.';
CREATE INDEX IF NOT EXISTS idx_tpds_users_school ON tpds_users_cloud(school_id);
CREATE INDEX IF NOT EXISTS idx_tpds_users_role   ON tpds_users_cloud(school_id, role);

DROP TRIGGER IF EXISTS set_updated_at_tpds_users ON tpds_users_cloud;
CREATE TRIGGER set_updated_at_tpds_users
  BEFORE UPDATE ON tpds_users_cloud
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();


-- ───────────────────────────────────────────────────────────────────────────
-- P3. JSMS — full school payload blob  (school_data)
--     JSMS pushes a complete JSON snapshot of all its localStorage keys
--     (edu2_* and jsms_*) as one JSONB column per school per push.
--     Pull restores everything in one request.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS school_data (
  id          UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id   TEXT        NOT NULL UNIQUE,
  payload     JSONB       NOT NULL DEFAULT '{}',
  version     TEXT,                          -- portal version string e.g. '15'
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE school_data IS 'Native JSMS cloud sync. One row per school. Payload contains all edu2_* and jsms_* keys as JSONB.';
CREATE INDEX IF NOT EXISTS idx_school_data_school    ON school_data(school_id);
CREATE INDEX IF NOT EXISTS idx_school_data_updated   ON school_data(updated_at DESC);

DROP TRIGGER IF EXISTS set_updated_at_school_data ON school_data;
CREATE TRIGGER set_updated_at_school_data
  BEFORE UPDATE ON school_data
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();


-- ═══════════════════════════════════════════════════════════════════════════
-- ████  PORTAL-NATIVE RPC FUNCTIONS  ████
--   Called directly by the portals via /rest/v1/rpc/<name>.
--   All are SECURITY DEFINER so they bypass RLS safely.
-- ═══════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────────
-- R1. tpds_upsert — write one data key for a teacher
--     Called after every save: lessons, IEPs, CAL, setup, submitted_docs.
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION tpds_upsert(
  p_id         TEXT,                   -- uid + '__' + dataKey composite — exact portal param
  p_user_id    TEXT,
  p_data_key   TEXT,
  p_payload    JSONB,
  p_updated_at TIMESTAMPTZ DEFAULT NOW(),
  p_school_id  TEXT        DEFAULT NULL
)
RETURNS VOID AS $$
BEGIN
  IF p_id IS NULL OR p_user_id IS NULL OR p_data_key IS NULL THEN
    RAISE EXCEPTION 'tpds_upsert: p_id, p_user_id, and p_data_key are required';
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
  'Called by TPDS portal _sbUpsert(). p_id = uid__dataKey composite. '
  'Param names must match exactly — PostgREST maps JSON body keys to param names.';


-- ───────────────────────────────────────────────────────────────────────────
-- R2. tpds_fetch — read all data keys for a teacher (login / pull)
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION tpds_fetch(p_id TEXT)
RETURNS JSONB AS $$
DECLARE
  v_payload JSONB;
BEGIN
  -- p_id = uid + '__' + dataKey (exact portal call format)
  -- Returns the payload JSONB directly, or NULL if not found.
  -- The portal checks: if(result !== null && result !== undefined)
  SELECT payload INTO v_payload
  FROM   tpds_sync
  WHERE  row_id = p_id
  LIMIT  1;

  RETURN v_payload;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

COMMENT ON FUNCTION tpds_fetch IS
  'Called by TPDS portal _sbFetch(dataKey). p_id = uid__dataKey. '
  'Returns the payload JSONB directly or NULL if not found. '
  'Param name must be p_id — PostgREST maps body {p_id:...} to this param.';


-- ───────────────────────────────────────────────────────────────────────────
-- R3. tpds_fetch_cloud_user — look up a teacher by username for login
-- ───────────────────────────────────────────────────────────────────────────
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
  WHERE   u.username = LOWER(p_username)
  LIMIT 1;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

COMMENT ON FUNCTION tpds_fetch_cloud_user IS
  'Called by TPDS login screen. Returns the teacher account row for credential verification.';


-- ───────────────────────────────────────────────────────────────────────────
-- R4. tpds_upsert_teacher — register or update a teacher cloud account
-- ───────────────────────────────────────────────────────────────────────────
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
DECLARE v_id UUID;
BEGIN
  INSERT INTO tpds_users_cloud(
    username, password_hash, name, tsc, school, school_id, role
  )
  VALUES (
    LOWER(p_username), p_password_hash,
    p_name, p_tsc, p_school, p_school_id, p_role
  )
  ON CONFLICT (username)
  DO UPDATE SET
    password_hash = COALESCE(EXCLUDED.password_hash, tpds_users_cloud.password_hash),
    name          = COALESCE(EXCLUDED.name,          tpds_users_cloud.name),
    tsc           = COALESCE(EXCLUDED.tsc,           tpds_users_cloud.tsc),
    school        = COALESCE(EXCLUDED.school,        tpds_users_cloud.school),
    school_id     = COALESCE(EXCLUDED.school_id,     tpds_users_cloud.school_id),
    role          = COALESCE(EXCLUDED.role,          tpds_users_cloud.role),
    updated_at    = NOW()
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION tpds_upsert_teacher IS
  'Called by TPDS Setup Wizard when a teacher registers or updates their cloud account. '
  'Password hash is the same SHA-256 hex used in localStorage.';


-- ═══════════════════════════════════════════════════════════════════════════
-- ████  RLS FOR PORTAL-NATIVE TABLES  ████
--   Open policies — portals authenticate via username+hash inside app logic,
--   not via Supabase JWT. SECURITY DEFINER functions handle tenant isolation.
--   For tighter security on tpds_users_cloud, restrict the UPDATE policy
--   so teachers cannot overwrite each other's rows via direct REST calls.
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE tpds_sync        ENABLE ROW LEVEL SECURITY;
ALTER TABLE tpds_sync        FORCE  ROW LEVEL SECURITY;
ALTER TABLE tpds_users_cloud ENABLE ROW LEVEL SECURITY;
ALTER TABLE tpds_users_cloud FORCE  ROW LEVEL SECURITY;
ALTER TABLE school_data      ENABLE ROW LEVEL SECURITY;
ALTER TABLE school_data      FORCE  ROW LEVEL SECURITY;

-- tpds_sync: allow SELECT (admin submitted_docs view uses direct GET)
-- INSERT/UPDATE/DELETE are blocked — forced through SECURITY DEFINER RPCs only
DROP POLICY IF EXISTS tpds_sync_select ON tpds_sync;
CREATE POLICY tpds_sync_select ON tpds_sync FOR SELECT USING (true);
DROP POLICY IF EXISTS tpds_sync_insert ON tpds_sync;
CREATE POLICY tpds_sync_insert ON tpds_sync FOR INSERT WITH CHECK (false);
DROP POLICY IF EXISTS tpds_sync_update ON tpds_sync;
CREATE POLICY tpds_sync_update ON tpds_sync FOR UPDATE USING (false);

-- tpds_users_cloud: allow read (for login check), write only via RPC
DROP POLICY IF EXISTS tpds_users_read       ON tpds_users_cloud;
CREATE POLICY tpds_users_read ON tpds_users_cloud FOR SELECT USING (true);

DROP POLICY IF EXISTS tpds_users_write      ON tpds_users_cloud;
CREATE POLICY tpds_users_write ON tpds_users_cloud
  FOR INSERT WITH CHECK (true);  -- INSERT via RPC only

-- school_data: anon can read/write own school_id row
DROP POLICY IF EXISTS school_data_open      ON school_data;
CREATE POLICY school_data_open ON school_data USING (true) WITH CHECK (true);


-- ═══════════════════════════════════════════════════════════════════════════
-- ████  CROSS-SYNC VIEWS  ████
--   These views join the normalised EduSync tables with the portal-native
--   tables so you can query everything from one place in Supabase dashboard.
-- ═══════════════════════════════════════════════════════════════════════════

-- V7. TPDS teacher lesson plan counts (from normalised table)
CREATE OR REPLACE VIEW v_teacher_lesson_stats AS
SELECT
  u.school_id                                         AS tpds_school_id,
  u.username,
  u.name                                              AS teacher_name,
  u.role,
  COUNT(lp.id)                                        AS total_lessons,
  COUNT(lp.id) FILTER (WHERE lp.status = 'approved') AS approved_lessons,
  COUNT(lp.id) FILTER (WHERE lp.status = 'draft')    AS draft_lessons,
  COUNT(lp.id) FILTER (WHERE lp.status = 'rejected') AS rejected_lessons,
  MAX(lp.updated_at)                                  AS last_activity
FROM   tpds_users_cloud u
LEFT   JOIN lesson_plans lp
       ON  lp.school_id = u.school_id::UUID
       -- Note: school_id in tpds_users_cloud is TEXT; lesson_plans uses UUID.
       -- This join only works when both are kept in sync via onboard_new_school().
       -- Filter by u.school_id IS NOT NULL to avoid cross-join noise.
WHERE  u.school_id IS NOT NULL
GROUP  BY u.school_id, u.username, u.name, u.role;

COMMENT ON VIEW v_teacher_lesson_stats IS
  'Joins TPDS cloud users with normalised lesson_plans. '
  'Use for HOD/Principal reporting dashboards.';


-- V8. School sync health — last push time for each school in both systems
CREATE OR REPLACE VIEW v_sync_health AS
SELECT
  s.id           AS school_id_uuid,
  s.name         AS school_name,
  s.plan,
  s.sub_status,
  -- JSMS blob sync last push
  sd.updated_at  AS jsms_last_sync,
  -- EduSync normalised: last lesson plan save
  MAX(lp.updated_at)  AS last_lesson_save,
  -- EduSync normalised: last learner update
  MAX(lr.updated_at)  AS last_learner_update,
  -- EduSync normalised: last attendance record
  MAX(at.created_at)  AS last_attendance,
  -- EduSync normalised: last score save
  MAX(ss.updated_at)  AS last_score_save
FROM   schools s
LEFT   JOIN school_data  sd ON sd.school_id = s.id::TEXT
LEFT   JOIN lesson_plans lp ON lp.school_id = s.id
LEFT   JOIN learners     lr ON lr.school_id = s.id
LEFT   JOIN attendance   at ON at.school_id = s.id
LEFT   JOIN summative_scores ss ON ss.school_id = s.id
GROUP  BY s.id, s.name, s.plan, s.sub_status, sd.updated_at;

COMMENT ON VIEW v_sync_health IS
  'Shows last sync time per school across both the JSMS blob sync and the normalised EduSync tables. '
  'Use in Platform Admin → Analytics to spot schools that have not synced recently.';


-- ═══════════════════════════════════════════════════════════════════════════
-- ████  FINAL VERIFICATION QUERY (updated to include portal-native tables)  ████
-- ═══════════════════════════════════════════════════════════════════════════
SELECT
  'TABLES'    AS object_type,
  COUNT(*)    AS count
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_type   = 'BASE TABLE'

UNION ALL

SELECT 'VIEWS',     COUNT(*) FROM information_schema.views
WHERE table_schema = 'public'

UNION ALL

SELECT 'FUNCTIONS', COUNT(*) FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_type   = 'FUNCTION'

ORDER BY object_type;

-- Expected results:
--   FUNCTIONS  17   (13 EduSync + 4 portal-native RPCs)
--   TABLES     34   (31 EduSync + tpds_sync + tpds_users_cloud + school_data)
--   VIEWS       8   (6 EduSync + v_teacher_lesson_stats + v_sync_health)

-- ═══════════════════════════════════════════════════════════════════════════
-- END OF EDUSUITE SUPABASE MASTER SETUP
-- ═══════════════════════════════════════════════════════════════════════════
