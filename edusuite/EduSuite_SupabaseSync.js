/**
 * ═══════════════════════════════════════════════════════════════════
 *  EDUSUITE SUPABASE SYNC CLIENT  v1.0
 *  Bridges localStorage (TPDS v1.44 + JSMS v2.5) ↔ Supabase
 *
 *  HOW TO USE:
 *    1. Add this script to both portal HTML files, just before </body>:
 *       <script src="EduSuite_SupabaseSync.js"></script>
 *
 *    2. After Supabase project URL + anon key are saved (from Platform Hub
 *       school settings → Sync tab), call once on page load:
 *         EduSync.init({ schoolId, supabaseUrl, supabaseKey })
 *
 *    3. Push changes after every save:
 *         EduSync.push.lessons()       // after saveLessonsData()
 *         EduSync.push.ieps()          // after saveIEPsData()
 *         EduSync.push.learners()      // after saveAll() in JSMS
 *         EduSync.push.attendance()    // after marking attendance
 *         EduSync.push.scores()        // after saving exam scores
 *         EduSync.push.all()           // full sync (on login/startup)
 *
 *    4. Pull from Supabase (e.g. on new device login):
 *         EduSync.pull.all()
 *
 *  ARCHITECTURE:
 *    - Offline-first: every operation writes to localStorage first.
 *    - If online + Supabase configured: immediately mirrors to DB.
 *    - If offline: action goes into offline queue (IndexedDB).
 *    - On reconnect: queue is drained automatically.
 *    - RLS: every request sends school_id in the Prefer header.
 *      The DB uses SET app.school_id = ? to enforce tenant isolation.
 * ═══════════════════════════════════════════════════════════════════
 */

const EduSync = (() => {
  'use strict';

  /* ── CONFIG ─────────────────────────────────────────────────────── */
  let CFG = {
    url:      '',
    key:      '',
    schoolId: '',
    ready:    false,
  };

  const IDB_NAME    = 'edusuite_offline_queue';
  const IDB_STORE   = 'queue';
  const IDB_VERSION = 1;
  let   _idb        = null;

  /* ── INIT ────────────────────────────────────────────────────────── */
  async function init({ schoolId, supabaseUrl, supabaseKey } = {}) {
    if (!schoolId || !supabaseUrl || !supabaseKey) {
      _log('warn', 'EduSync.init: missing config — sync disabled');
      return;
    }
    CFG.schoolId = schoolId;
    CFG.url      = supabaseUrl.replace(/\/$/, '');
    CFG.key      = supabaseKey;
    CFG.ready    = true;

    await _openIDB();
    _log('info', `EduSync ready for school ${schoolId}`);

    // Auto-drain queue when online
    window.addEventListener('online', () => {
      _log('info', 'Connection restored — draining offline queue');
      _drainQueue();
    });

    // Drain any leftover queue entries on init
    if (navigator.onLine) {
      await _drainQueue();
    }
  }

  /* ── SUPABASE REST HELPER ────────────────────────────────────────── */
  async function _rpc(method, path, body = null) {
    if (!CFG.ready) throw new Error('EduSync not initialised');

    const url = `${CFG.url}/rest/v1/${path}`;
    const headers = {
      'apikey':        CFG.key,
      'Authorization': `Bearer ${CFG.key}`,
      'Content-Type':  'application/json',
      'Prefer':        'return=minimal',
      // Sends school_id so Postgres SET LOCAL app.school_id works via trigger/RLS
      'x-school-id':   CFG.schoolId,
    };

    const opts = { method, headers };
    if (body) opts.body = JSON.stringify(body);

    const res = await fetch(url, opts);
    if (!res.ok) {
      const txt = await res.text();
      throw new Error(`Supabase ${method} ${path} → ${res.status}: ${txt}`);
    }
    const ct = res.headers.get('content-type') || '';
    return ct.includes('application/json') ? res.json() : null;
  }

  // Convenience wrappers
  const _get    = (path)        => _rpc('GET',    path);
  const _post   = (path, body)  => _rpc('POST',   path, body);
  const _patch  = (path, body)  => _rpc('PATCH',  path, body);
  const _delete = (path)        => _rpc('DELETE',  path);

  // Upsert (INSERT … ON CONFLICT DO UPDATE)
  async function _upsert(table, rows, conflictCols = 'id') {
    if (!rows || !rows.length) return;
    const path = `${table}?on_conflict=${conflictCols}`;
    const headers = {
      'apikey':        CFG.key,
      'Authorization': `Bearer ${CFG.key}`,
      'Content-Type':  'application/json',
      'Prefer':        'resolution=merge-duplicates,return=minimal',
      'x-school-id':   CFG.schoolId,
    };
    const res = await fetch(`${CFG.url}/rest/v1/${path}`, {
      method:  'POST',
      headers,
      body:    JSON.stringify(rows),
    });
    if (!res.ok) {
      const txt = await res.text();
      throw new Error(`Upsert ${table} → ${res.status}: ${txt}`);
    }
  }

  /* ── INDEXEDDB OFFLINE QUEUE ─────────────────────────────────────── */
  function _openIDB() {
    return new Promise((resolve, reject) => {
      if (_idb) { resolve(_idb); return; }
      const req = indexedDB.open(IDB_NAME, IDB_VERSION);
      req.onupgradeneeded = e => {
        const db = e.target.result;
        if (!db.objectStoreNames.contains(IDB_STORE)) {
          const store = db.createObjectStore(IDB_STORE, { keyPath: 'id', autoIncrement: true });
          store.createIndex('status', 'status', { unique: false });
        }
      };
      req.onsuccess = e => { _idb = e.target.result; resolve(_idb); };
      req.onerror   = e => { _log('error', 'IDB open failed', e); reject(e); };
    });
  }

  function _queueAction(action) {
    return new Promise((resolve, reject) => {
      if (!_idb) { resolve(); return; }
      const tx    = _idb.transaction(IDB_STORE, 'readwrite');
      const store = tx.objectStore(IDB_STORE);
      store.add({ ...action, status: 'pending', queuedAt: Date.now() });
      tx.oncomplete = resolve;
      tx.onerror    = reject;
    });
  }

  function _getQueuedActions() {
    return new Promise((resolve, reject) => {
      if (!_idb) { resolve([]); return; }
      const tx    = _idb.transaction(IDB_STORE, 'readonly');
      const store = tx.objectStore(IDB_STORE);
      const idx   = store.index('status');
      const req   = idx.getAll('pending');
      req.onsuccess = () => resolve(req.result || []);
      req.onerror   = reject;
    });
  }

  function _markActionSynced(id) {
    return new Promise((resolve) => {
      if (!_idb) { resolve(); return; }
      const tx    = _idb.transaction(IDB_STORE, 'readwrite');
      const store = tx.objectStore(IDB_STORE);
      const req   = store.get(id);
      req.onsuccess = () => {
        const rec = req.result;
        if (rec) { rec.status = 'synced'; rec.syncedAt = Date.now(); store.put(rec); }
        resolve();
      };
    });
  }

  async function _drainQueue() {
    if (!CFG.ready || !navigator.onLine) return;
    const actions = await _getQueuedActions();
    if (!actions.length) return;

    _log('info', `Draining ${actions.length} queued action(s)…`);
    let synced = 0;
    let failed = 0;

    for (const action of actions) {
      try {
        await _executeAction(action);
        await _markActionSynced(action.id);
        synced++;
      } catch (e) {
        _log('error', `Queue action ${action.type} failed:`, e.message);
        failed++;
      }
    }
    _log('info', `Queue drain: ${synced} synced, ${failed} failed`);
    _emitEvent('edusync:drain', { synced, failed });
  }

  async function _executeAction(action) {
    switch (action.type) {
      case 'upsert': return _upsert(action.table, action.rows, action.conflict);
      case 'delete': return _delete(`${action.table}?id=eq.${action.id}&school_id=eq.${CFG.schoolId}`);
      default: throw new Error(`Unknown action type: ${action.type}`);
    }
  }

  /* ── SAFE PUSH (tries live; queues if offline) ───────────────────── */
  async function _safePush(table, rows, conflict = 'id') {
    if (!CFG.ready) return;
    if (!Array.isArray(rows) || !rows.length) return;

    // Stamp school_id on every row
    const stamped = rows.map(r => ({ ...r, school_id: CFG.schoolId }));

    if (navigator.onLine) {
      try {
        await _upsert(table, stamped, conflict);
        return;
      } catch (e) {
        _log('warn', `Live push to ${table} failed — queuing: ${e.message}`);
      }
    }
    // Offline or failed → queue
    await _queueAction({ type: 'upsert', table, rows: stamped, conflict });
    _log('info', `Queued ${stamped.length} row(s) for ${table}`);
  }

  /* ── UTILITIES ───────────────────────────────────────────────────── */
  function _ls(key) {
    try { return JSON.parse(localStorage.getItem(key)); } catch { return null; }
  }

  function _uid() {
    // Use existing id or generate a new deterministic UUID-like string
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
      const r = Math.random() * 16 | 0;
      return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
    });
  }

  function _today() { return new Date().toISOString().slice(0, 10); }

  function _log(level, ...args) {
    const prefix = '[EduSync]';
    if (level === 'error') console.error(prefix, ...args);
    else if (level === 'warn') console.warn(prefix, ...args);
    else console.log(prefix, ...args);
  }

  function _emitEvent(name, detail = {}) {
    window.dispatchEvent(new CustomEvent(name, { detail }));
  }

  /* ══════════════════════════════════════════════════════════════════
     PUSH FUNCTIONS — localStorage → Supabase
     Called after every save operation in the portals.
  ══════════════════════════════════════════════════════════════════ */
  const push = {

    /* ── TPDS: LESSON PLANS ──────────────────────────────────────── */
    async lessons() {
      const raw = _ls('eng_tpds_lessons') || [];
      if (!raw.length) return;
      const rows = raw.map(l => ({
        id:            l.id,
        school_id:     CFG.schoolId,
        grade:         parseInt(l.grade) || 7,
        term:          String(l.term || '1'),
        subject:       l.subject || 'English',
        week:          l.week || null,
        lesson_no:     l.lno || null,
        date:          l.date || null,
        day:           l.day || null,
        time_slot:     l.time || null,
        roll:          l.roll || null,
        theme:         l.theme || null,
        strand:        l.strand || null,
        substrand:     l.substrand || null,
        slo:           l.slo || null,
        sle:           l.sle || null,
        kiq:           l.kiq || null,
        resources:     l.resources || null,
        org_learning:  l.orglearn || null,
        introduction:  l.intro || null,
        steps:         l.steps ? JSON.stringify(l.steps) : null,
        extended:      l.extended || null,
        conclusion:    l.conclusion || null,
        reflection:    l.reflect || null,
        skill:         l.skill || null,
        work_done:     l.workdone || null,
        assessment:    l.asm || null,
        attainment:    l.attainment || null,
        mat_files:     l.matFiles ? JSON.stringify(l.matFiles) : null,
        ev_files:      l.evFiles  ? JSON.stringify(l.evFiles)  : null,
        status:        l.status || 'draft',
        is_deleted:    false,
        updated_at:    new Date().toISOString(),
      }));
      await _safePush('lesson_plans', rows, 'id');
      _log('info', `Pushed ${rows.length} lesson plan(s)`);
    },

    /* ── TPDS: IEPs ──────────────────────────────────────────────── */
    async ieps() {
      const raw = _ls('eng_tpds_ieps') || [];
      if (!raw.length) return;
      const rows = raw.map(i => ({
        id:             i.id,
        school_id:      CFG.schoolId,
        learner_name:   i.name || '',
        adm:            i.adm || null,
        grade:          i.grade || null,
        term:           i.term || null,
        dob:            i.dob || null,
        parent_name:    i.parent || null,
        contact:        i.contact || null,
        date:           i.date || null,
        review_date:    i.review || null,
        challenges:     i.challenges || null,
        strengths:      i.strengths || null,
        goals:          i.goals || null,
        strategies:     i.strategies || null,
        assessment:     i.assessment || null,
        progress:       i.progress || null,
        remarks:        i.remarks || null,
        parent_remarks: i.parentremarks || null,
        is_deleted:     false,
        updated_at:     new Date().toISOString(),
      }));
      await _safePush('ieps', rows, 'id');

      // Push IEP logs separately
      const logsObj = _ls('tpds_iep_logs') || {};
      const logRows = [];
      for (const [iepId, entries] of Object.entries(logsObj)) {
        for (const e of (entries || [])) {
          logRows.push({
            id:          e.id || _uid(),
            school_id:   CFG.schoolId,
            iep_id:      iepId,
            review_date: e.date || null,
            reviewed_by: e.by || null,
            notes:       e.notes || null,
            next_review: e.nextDate || null,
            created_at:  e.createdAt ? new Date(e.createdAt).toISOString() : new Date().toISOString(),
          });
        }
      }
      if (logRows.length) await _safePush('iep_logs', logRows, 'id');
      _log('info', `Pushed ${rows.length} IEP(s) + ${logRows.length} log(s)`);
    },

    /* ── TPDS: CAL ENTRIES ───────────────────────────────────────── */
    async cal() {
      const raw = _ls('eng_tpds_cal') || [];
      if (!raw.length) return;
      const rows = raw.map(c => ({
        id:          c.id || _uid(),
        school_id:   CFG.schoolId,
        learner_name: c.learner || c.learnerName || null,
        adm:         c.adm || null,
        grade:       c.grade || null,
        term:        c.term || null,
        date:        c.date || null,
        notes:       c.notes || null,
        next_date:   c.nextDate || null,
        recorded_by: c.by || null,
        created_at:  c.createdAt ? new Date(c.createdAt).toISOString() : new Date().toISOString(),
      }));
      await _safePush('cal_entries', rows, 'id');
      _log('info', `Pushed ${rows.length} CAL entr(ies)`);
    },

    /* ── TPDS: SETUP ─────────────────────────────────────────────── */
    async setup() {
      const s  = _ls('eng_tpds_setup');
      const lh = _ls('tpds_letterhead');
      if (!s) return;
      const row = {
        school_id:    CFG.schoolId,
        school_name:  s.school || null,
        subject:      s.subject || 'English',
        academic_year: s.academicYear || String(new Date().getFullYear()),
        grades:       s.grades || [7, 8, 9],
        schedule:     s.schedule ? JSON.stringify(s.schedule) : null,
        rolls:        s.rolls   ? JSON.stringify(s.rolls)    : null,
        themes:       s.themes  ? JSON.stringify(s.themes)   : null,
        strands:      s.strands ? JSON.stringify(s.strands)  : null,
        letterhead:   lh        ? JSON.stringify(lh)         : null,
        updated_at:   new Date().toISOString(),
      };
      await _safePush('tpds_setup', [row], 'school_id');
      _log('info', 'Pushed TPDS setup');
    },

    /* ── TPDS: SUBMITTED DOCUMENTS ───────────────────────────────── */
    async submittedDocs() {
      const raw = _ls('tpds_submitted_docs') || [];
      if (!raw.length) return;
      const rows = raw.map(d => ({
        id:           d.id,
        school_id:    CFG.schoolId,
        doc_type:     d.docType || 'Document',
        summary:      d.summary || null,
        target_role:  d.targetRole || null,
        status:       d.status || 'pending',
        submitted_at: d.submittedAt ? new Date(d.submittedAt).toISOString() : new Date().toISOString(),
      }));
      await _safePush('submitted_documents', rows, 'id');
      _log('info', `Pushed ${rows.length} submitted doc(s)`);
    },

    /* ── JSMS: LEARNERS ──────────────────────────────────────────── */
    async learners() {
      const raw = _ls('edu2_l') || [];
      if (!raw.length) return;
      const rows = raw.map(l => ({
        id:        l._sbId || _uid(),   // use cached Supabase ID if available
        school_id: CFG.schoolId,
        adm:       l.adm,
        name:      l.name,
        grade:     String(l.grade || '7'),
        stream:    l.stream || null,
        gender:    l.gender || null,
        dob:       l.dob   || null,
        doa:       l.doa   || null,
        email:     l.email || null,
        nemis_no:  l.nemisNo || null,
        ass_no:    l.assNo || null,
        par_name:  l.parName  || null,
        par_phone: l.parPhone || null,
        par_email: l.parEmail || null,
        updated_at: new Date().toISOString(),
      }));
      await _safePush('learners', rows, 'school_id,adm');

      // Cache returned IDs back to localStorage for future updates
      if (navigator.onLine) {
        try {
          const dbRows = await _get(
            `learners?school_id=eq.${CFG.schoolId}&select=id,adm`
          );
          if (dbRows && Array.isArray(dbRows)) {
            const idMap = {};
            dbRows.forEach(r => { idMap[r.adm] = r.id; });
            const updated = raw.map(l => ({ ...l, _sbId: idMap[l.adm] || l._sbId }));
            localStorage.setItem('edu2_l', JSON.stringify(updated));
          }
        } catch (_) { /* non-critical */ }
      }
      _log('info', `Pushed ${rows.length} learner(s)`);
    },

    /* ── JSMS: STAFF ─────────────────────────────────────────────── */
    async staff() {
      const raw = _ls('edu2_staff') || [];
      if (!raw.length) return;
      const rows = raw.map(s => ({
        id:              s.id || _uid(),
        school_id:       CFG.schoolId,
        name:            s.name,
        tsc_number:      s.tsc || null,
        phone:           s.phone || null,
        email:           s.email || null,
        role:            s.role || 'Teacher',
        department:      s.dept || null,
        subjects:        s.subjects || [],
        class_teacher_of: s.classOf || null,
        is_active:       s.active !== false,
        updated_at:      new Date().toISOString(),
      }));
      await _safePush('staff', rows, 'id');
      _log('info', `Pushed ${rows.length} staff member(s)`);
    },

    /* ── JSMS: ATTENDANCE ────────────────────────────────────────── */
    async attendance() {
      const att = _ls('edu2_att') || {};
      const learners = _ls('edu2_l') || [];
      const admToId = {};
      learners.forEach(l => { if (l._sbId) admToId[l.adm] = l._sbId; });

      const rows = [];
      for (const [date, dayMap] of Object.entries(att)) {
        for (const [adm, status] of Object.entries(dayMap)) {
          if (!status) continue;
          rows.push({
            id:         `${CFG.schoolId}-${adm}-${date}`,  // deterministic id
            school_id:  CFG.schoolId,
            learner_id: admToId[adm] || null,
            adm,
            date,
            status,
          });
        }
      }
      if (!rows.length) return;

      // Batch in chunks of 500 to avoid payload limits
      for (let i = 0; i < rows.length; i += 500) {
        await _safePush('attendance', rows.slice(i, i + 500), 'school_id,adm,date');
      }
      _log('info', `Pushed ${rows.length} attendance record(s)`);
    },

    /* ── JSMS: FEE STRUCTURE ─────────────────────────────────────── */
    async feeStructure() {
      const raw = _ls('edu2_fs') || [];
      if (!raw.length) return;
      const year = String(new Date().getFullYear());
      // fee structure is term-agnostic in localStorage — we store under current year
      const rows = raw.map((f, i) => ({
        id:           `${CFG.schoolId}-fs-${i}`,
        school_id:    CFG.schoolId,
        term:         '1',   // JSMS stores one structure for all terms
        academic_year: year,
        name:         f.name || 'Fee',
        amount:       parseFloat(f.amt) || 0,
        sort_order:   i,
      }));
      await _safePush('fee_structure', rows, 'id');
      _log('info', `Pushed ${rows.length} fee structure item(s)`);
    },

    /* ── JSMS: FEE PAYMENTS ──────────────────────────────────────── */
    async feePayments() {
      const pays = _ls('edu2_pays') || {};
      const learners = _ls('edu2_l') || [];
      const admToId = {};
      learners.forEach(l => { if (l._sbId) admToId[l.adm] = l._sbId; });

      const rows = [];
      for (const [adm, entries] of Object.entries(pays)) {
        const learnerId = admToId[adm] || null;
        for (const p of (entries || [])) {
          rows.push({
            id:            p._sbId || `${CFG.schoolId}-${adm}-${p.date}-${p.txn || Math.random().toString(36).slice(2,6)}`,
            school_id:     CFG.schoolId,
            learner_id:    learnerId,
            adm,
            term:          String(p.term || '1'),
            academic_year: String(p.academicYear || new Date().getFullYear()),
            amount:        parseFloat(p.amt) || 0,
            mode:          p.mode || 'M-Pesa',
            txn_ref:       p.txn || null,
            receipt_no:    p.rcptNo || null,
            payment_date:  p.date || _today(),
            from_parent:   !!p._fromParent,
          });
        }
      }
      if (!rows.length) return;
      for (let i = 0; i < rows.length; i += 500) {
        await _safePush('fee_payments', rows.slice(i, i + 500), 'id');
      }
      _log('info', `Pushed ${rows.length} payment record(s)`);
    },

    /* ── JSMS: PENDING (PARENT) PAYMENTS ────────────────────────── */
    async pendingPayments() {
      const raw = _ls('edu2_pending_pays') || [];
      if (!raw.length) return;
      const learners = _ls('edu2_l') || [];
      const admToId = {};
      learners.forEach(l => { if (l._sbId) admToId[l.adm] = l._sbId; });

      const rows = raw.map(p => ({
        id:           p.id,
        school_id:    CFG.schoolId,
        learner_id:   admToId[p.adm] || null,
        adm:          p.adm,
        learner_name: p.learnerName || null,
        grade:        p.grade || null,
        amount:       parseFloat(p.amt) || 0,
        term:         String(p.term || '1'),
        mode:         p.mode || 'M-Pesa',
        txn_ref:      p.txn,
        pay_phone:    p.phone || null,
        status:       p.status || 'pending',
        submitted_at: p.submittedAt ? new Date(p.submittedAt).toISOString() : new Date().toISOString(),
      }));
      await _safePush('pending_payments', rows, 'id');
      _log('info', `Pushed ${rows.length} pending payment(s)`);
    },

    /* ── JSMS: SUMMATIVE SCORES ──────────────────────────────────── */
    async scores() {
      const summative = _ls('edu2_s') || {};
      const learners  = _ls('edu2_l') || [];
      const configs   = _ls('edu2_ec') || {};
      const year      = String(new Date().getFullYear());

      const admToId = {};
      learners.forEach(l => { if (l._sbId) admToId[l.adm] = l._sbId; });

      const rows = [];
      // Key format: adm_term_epKey  e.g. ADM001_t1_op
      for (const [key, subjects] of Object.entries(summative)) {
        const parts = key.split('_');
        if (parts.length < 3) continue;
        const adm     = parts[0];
        const term    = parts[1].replace('t', '');  // 't1' → '1'
        const epKey   = parts.slice(2).join('_');   // 'op', 'mid', 'end'

        for (const [subject, tasks] of Object.entries(subjects || {})) {
          for (const [taskName, data] of Object.entries(tasks || {})) {
            if (data === undefined || data === null) continue;
            // Look up max score from exam config
            const cfgKey = `t${term}_${epKey}`;
            const taskCfg = (configs[cfgKey]?.[subject] || []).find(c => c.name === taskName);
            const maxScore = taskCfg?.max || 100;

            rows.push({
              id:              `${CFG.schoolId}-${adm}-${term}-${epKey}-${subject}-${taskName}`.replace(/\s+/g,'_'),
              school_id:       CFG.schoolId,
              learner_id:      admToId[adm] || null,
              adm,
              academic_year:   year,
              term:            String(term),
              exam_period_key: epKey,
              subject,
              task_name:       taskName,
              raw_score:       data.raw ?? null,
              percentage:      data.pct ?? null,
              max_score:       maxScore,
              updated_at:      new Date().toISOString(),
            });
          }
        }
      }
      if (!rows.length) return;
      for (let i = 0; i < rows.length; i += 500) {
        await _safePush('summative_scores', rows.slice(i, i + 500), 'id');
      }
      _log('info', `Pushed ${rows.length} score record(s)`);
    },

    /* ── JSMS: LIBRARY ───────────────────────────────────────────── */
    async library() {
      const shelves = _ls('edu2_lib_shelves') || [];
      const books   = _ls('edu2_lib_books')   || [];
      const loans   = _ls('edu2_lib_loans')   || [];
      const learners = _ls('edu2_l') || [];
      const admToId = {};
      learners.forEach(l => { if (l._sbId) admToId[l.adm] = l._sbId; });

      if (shelves.length) {
        const sRows = shelves.map(s => ({
          id:         s.id,
          school_id:  CFG.schoolId,
          name:       s.name,
          colour:     s.colour || '#1b4332',
          loan_days:  s.loanDays || 14,
        }));
        await _safePush('library_shelves', sRows, 'id');
      }

      if (books.length) {
        const bRows = books.map(b => ({
          id:          b.id,
          school_id:   CFG.schoolId,
          shelf_id:    b.shelfId || null,
          title:       b.title,
          author:      b.author || null,
          isbn:        b.isbn   || null,
          accession_no: b.accessionNo || b.accession || null,
          copies:      b.copies || 1,
          grade_level: b.gradeLevel || null,
          subject:     b.subject || null,
          updated_at:  new Date().toISOString(),
        }));
        await _safePush('library_books', bRows, 'id');
      }

      if (loans.length) {
        const lRows = loans.map(ln => ({
          id:             ln.id,
          school_id:      CFG.schoolId,
          book_id:        ln.bookId,
          learner_id:     admToId[ln.adm] || null,
          adm:            ln.adm,
          learner_name:   ln.learnerName || null,
          issue_date:     ln.issued  || ln.issueDate  || _today(),
          due_date:       ln.due     || ln.dueDate    || _today(),
          returned_date:  ln.returned || null,
          status:         ln.status || 'active',
          updated_at:     new Date().toISOString(),
        }));
        await _safePush('library_loans', lRows, 'id');
      }
      _log('info', `Pushed library: ${shelves.length} shelves, ${books.length} books, ${loans.length} loans`);
    },

    /* ── JSMS: TIMETABLE ─────────────────────────────────────────── */
    async timetable() {
      const periods  = _ls('edu2_tt_periods')     || [];
      const subjects = _ls('edu2_tt_subjects')    || [];
      const entries  = _ls('edu2_tt_timetable')   || [];
      const year     = String(new Date().getFullYear());

      if (periods.length) {
        const pRows = periods.map((p, i) => ({
          id:         p.id || `${CFG.schoolId}-ttp-${i}`,
          school_id:  CFG.schoolId,
          name:       p.name,
          time_from:  p.timeFrom || null,
          time_to:    p.timeTo   || null,
          sort_order: i,
          is_break:   !!p.isBreak,
        }));
        await _safePush('timetable_periods', pRows, 'id');
      }

      if (subjects.length) {
        const sRows = subjects.map((s, i) => ({
          id:         s.id || `${CFG.schoolId}-tts-${i}`,
          school_id:  CFG.schoolId,
          name:       s.name,
          short_code: s.short || null,
          colour:     s.colour || '#1b4332',
        }));
        await _safePush('timetable_subjects', sRows, 'id');
      }

      if (entries.length) {
        const eRows = entries.map((e, i) => ({
          id:           e.id || `${CFG.schoolId}-tte-${i}`,
          school_id:    CFG.schoolId,
          academic_year: year,
          term:         String(e.term || '1'),
          day:          e.day,
          grade:        String(e.grade),
          stream:       e.stream || null,
          subject:      e.subject,
          teacher_name: e.teacher || null,
          room:         e.room || null,
        }));
        for (let i = 0; i < eRows.length; i += 500) {
          await _safePush('timetable_entries', eRows.slice(i, i + 500), 'id');
        }
      }
      _log('info', `Pushed timetable: ${periods.length} periods, ${subjects.length} subjects, ${entries.length} entries`);
    },

    /* ── JSMS: CO-CURRICULAR ─────────────────────────────────────── */
    async cocurricular() {
      const assignments = _ls('jsms_cocurricular_assignments') || [];
      const learners    = _ls('edu2_l') || [];
      const admToId = {};
      learners.forEach(l => { if (l._sbId) admToId[l.adm] = l._sbId; });
      const year = String(new Date().getFullYear());

      if (!assignments.length) return;
      const rows = assignments.map(a => ({
        id:           a.id || _uid(),
        school_id:    CFG.schoolId,
        learner_id:   admToId[a.adm] || null,
        adm:          a.adm,
        academic_year: year,
        term:         a.term || null,
        role:         a.role || 'Member',
      }));
      await _safePush('cocurricular_assignments', rows, 'id');
      _log('info', `Pushed ${rows.length} co-curricular assignment(s)`);
    },

    /* ── JSMS: SCHOOL EVENTS ─────────────────────────────────────── */
    async events() {
      const raw = _ls('edu2_events') || [];
      if (!raw.length) return;
      const rows = raw.map((e, i) => ({
        id:         e.id || `${CFG.schoolId}-ev-${i}`,
        school_id:  CFG.schoolId,
        title:      e.title,
        event_date: e.date,
        event_type: e.type || 'general',
      }));
      await _safePush('school_events', rows, 'id');
      _log('info', `Pushed ${rows.length} event(s)`);
    },

    /* ── FULL PUSH (all modules) ─────────────────────────────────── */
    async all() {
      if (!CFG.ready) {
        _log('warn', 'EduSync not ready — call EduSync.init() first');
        return;
      }
      _log('info', 'Starting full push…');
      _emitEvent('edusync:push:start');
      const results = {};

      const modules = [
        ['setup',           push.setup],
        ['lessons',         push.lessons],
        ['ieps',            push.ieps],
        ['cal',             push.cal],
        ['submittedDocs',   push.submittedDocs],
        ['learners',        push.learners],
        ['staff',           push.staff],
        ['feeStructure',    push.feeStructure],
        ['feePayments',     push.feePayments],
        ['pendingPayments', push.pendingPayments],
        ['attendance',      push.attendance],
        ['scores',          push.scores],
        ['library',         push.library],
        ['timetable',       push.timetable],
        ['cocurricular',    push.cocurricular],
        ['events',          push.events],
      ];

      for (const [name, fn] of modules) {
        try {
          await fn();
          results[name] = 'ok';
        } catch (e) {
          results[name] = `error: ${e.message}`;
          _log('error', `Module ${name} failed:`, e.message);
        }
      }

      _emitEvent('edusync:push:done', { results });
      _log('info', 'Full push complete', results);
      return results;
    },
  }; // end push

  /* ══════════════════════════════════════════════════════════════════
     PULL FUNCTIONS — Supabase → localStorage
     Call on fresh login or new device.
  ══════════════════════════════════════════════════════════════════ */
  const pull = {

    async learners() {
      const rows = await _get(`learners?school_id=eq.${CFG.schoolId}&is_active=eq.true&order=adm`);
      if (!rows) return;
      const mapped = rows.map(r => ({
        _sbId:    r.id,
        adm:      r.adm,
        name:     r.name,
        grade:    r.grade,
        stream:   r.stream,
        gender:   r.gender,
        dob:      r.dob,
        doa:      r.doa,
        email:    r.email,
        nemisNo:  r.nemis_no,
        assNo:    r.ass_no,
        parName:  r.par_name,
        parPhone: r.par_phone,
        parEmail: r.par_email,
      }));
      localStorage.setItem('edu2_l', JSON.stringify(mapped));
      _log('info', `Pulled ${mapped.length} learner(s)`);
      return mapped;
    },

    async lessons() {
      const rows = await _get(
        `lesson_plans?school_id=eq.${CFG.schoolId}&is_deleted=eq.false&order=created_at.desc`
      );
      if (!rows) return;
      const mapped = rows.map(r => ({
        id:         r.id,
        grade:      r.grade,
        term:       r.term,
        subject:    r.subject,
        week:       r.week,
        lno:        r.lesson_no,
        date:       r.date,
        day:        r.day,
        time:       r.time_slot,
        roll:       r.roll,
        theme:      r.theme,
        strand:     r.strand,
        substrand:  r.substrand,
        slo:        r.slo,
        sle:        r.sle,
        kiq:        r.kiq,
        resources:  r.resources,
        orglearn:   r.org_learning,
        intro:      r.introduction,
        steps:      r.steps      ? JSON.parse(r.steps)      : [],
        extended:   r.extended,
        conclusion: r.conclusion,
        reflect:    r.reflection,
        skill:      r.skill,
        workdone:   r.work_done,
        asm:        r.assessment,
        attainment: r.attainment,
        matFiles:   r.mat_files  ? JSON.parse(r.mat_files)  : [],
        evFiles:    r.ev_files   ? JSON.parse(r.ev_files)   : [],
        status:     r.status,
      }));
      localStorage.setItem('eng_tpds_lessons', JSON.stringify(mapped));
      _log('info', `Pulled ${mapped.length} lesson plan(s)`);
      return mapped;
    },

    async ieps() {
      const rows = await _get(
        `ieps?school_id=eq.${CFG.schoolId}&is_deleted=eq.false&order=created_at.desc`
      );
      if (!rows) return;
      const mapped = rows.map(r => ({
        id:            r.id,
        name:          r.learner_name,
        adm:           r.adm,
        grade:         r.grade,
        term:          r.term,
        dob:           r.dob,
        parent:        r.parent_name,
        contact:       r.contact,
        date:          r.date,
        review:        r.review_date,
        challenges:    r.challenges,
        strengths:     r.strengths,
        goals:         r.goals,
        strategies:    r.strategies,
        assessment:    r.assessment,
        progress:      r.progress,
        remarks:       r.remarks,
        parentremarks: r.parent_remarks,
        createdAt:     new Date(r.created_at).getTime(),
        updatedAt:     new Date(r.updated_at).getTime(),
      }));
      localStorage.setItem('eng_tpds_ieps', JSON.stringify(mapped));

      // Pull IEP logs too
      const logRows = await _get(`iep_logs?school_id=eq.${CFG.schoolId}&order=created_at.desc`);
      if (logRows) {
        const logsObj = {};
        logRows.forEach(l => {
          if (!logsObj[l.iep_id]) logsObj[l.iep_id] = [];
          logsObj[l.iep_id].push({
            id:         l.id,
            date:       l.review_date,
            by:         l.reviewed_by,
            notes:      l.notes,
            nextDate:   l.next_review,
            createdAt:  new Date(l.created_at).getTime(),
          });
        });
        localStorage.setItem('tpds_iep_logs', JSON.stringify(logsObj));
      }
      _log('info', `Pulled ${mapped.length} IEP(s)`);
      return mapped;
    },

    async attendance() {
      const rows = await _get(
        `attendance?school_id=eq.${CFG.schoolId}&order=date.asc`
      );
      if (!rows) return;
      const att = {};
      rows.forEach(r => {
        if (!att[r.date]) att[r.date] = {};
        att[r.date][r.adm] = r.status;
      });
      localStorage.setItem('edu2_att', JSON.stringify(att));
      _log('info', `Pulled ${rows.length} attendance record(s)`);
      return att;
    },

    async scores() {
      const rows = await _get(
        `summative_scores?school_id=eq.${CFG.schoolId}`
      );
      if (!rows) return;
      const summative = {};
      rows.forEach(r => {
        const key = `${r.adm}_t${r.term}_${r.exam_period_key}`;
        if (!summative[key]) summative[key] = {};
        if (!summative[key][r.subject]) summative[key][r.subject] = {};
        summative[key][r.subject][r.task_name] = {
          raw: r.raw_score,
          pct: r.percentage,
        };
      });
      localStorage.setItem('edu2_s', JSON.stringify(summative));
      _log('info', `Pulled ${rows.length} score record(s)`);
      return summative;
    },

    async feePayments() {
      const rows = await _get(
        `fee_payments?school_id=eq.${CFG.schoolId}&order=payment_date.desc`
      );
      if (!rows) return;
      const pays = {};
      rows.forEach(r => {
        if (!pays[r.adm]) pays[r.adm] = [];
        pays[r.adm].push({
          _sbId:   r.id,
          amt:     r.amount,
          date:    r.payment_date,
          mode:    r.mode,
          txn:     r.txn_ref,
          rcptNo:  r.receipt_no,
          term:    r.term,
          _fromParent: r.from_parent,
        });
      });
      localStorage.setItem('edu2_pays', JSON.stringify(pays));
      _log('info', `Pulled ${rows.length} payment(s)`);
      return pays;
    },

    async all() {
      if (!CFG.ready) {
        _log('warn', 'EduSync not ready — call EduSync.init() first');
        return;
      }
      _log('info', 'Starting full pull…');
      _emitEvent('edusync:pull:start');
      const results = {};

      const modules = [
        ['learners',    pull.learners],
        ['lessons',     pull.lessons],
        ['ieps',        pull.ieps],
        ['attendance',  pull.attendance],
        ['scores',      pull.scores],
        ['feePayments', pull.feePayments],
      ];

      for (const [name, fn] of modules) {
        try {
          await fn();
          results[name] = 'ok';
        } catch (e) {
          results[name] = `error: ${e.message}`;
          _log('error', `Pull ${name} failed:`, e.message);
        }
      }

      _emitEvent('edusync:pull:done', { results });
      _log('info', 'Full pull complete', results);
      return results;
    },
  }; // end pull

  /* ══════════════════════════════════════════════════════════════════
     STATUS / DIAGNOSTICS
  ══════════════════════════════════════════════════════════════════ */
  const status = {
    isReady()   { return CFG.ready; },
    isOnline()  { return navigator.onLine; },
    schoolId()  { return CFG.schoolId; },

    async queueDepth() {
      const actions = await _getQueuedActions();
      return actions.length;
    },

    async testConnection() {
      if (!CFG.ready) return { ok: false, error: 'Not initialised' };
      try {
        const res = await fetch(`${CFG.url}/rest/v1/schools?id=eq.${CFG.schoolId}&select=id,name`, {
          headers: {
            'apikey': CFG.key,
            'Authorization': `Bearer ${CFG.key}`,
          },
        });
        if (res.ok) {
          const data = await res.json();
          return { ok: true, school: data[0] || null, latencyMs: null };
        }
        return { ok: false, status: res.status, error: await res.text() };
      } catch (e) {
        return { ok: false, error: e.message };
      }
    },

    async summary() {
      const qDepth = await status.queueDepth();
      const conn   = navigator.onLine ? await status.testConnection() : { ok: false, error: 'Offline' };
      return {
        ready:       CFG.ready,
        online:      navigator.onLine,
        schoolId:    CFG.schoolId,
        supabaseUrl: CFG.url ? CFG.url.replace(/https?:\/\//, '').slice(0, 30) + '…' : 'not set',
        connection:  conn,
        queueDepth:  qDepth,
      };
    },
  };

  /* ══════════════════════════════════════════════════════════════════
     PUBLIC API
  ══════════════════════════════════════════════════════════════════ */
  return { init, push, pull, status };

})();

/**
 * ───────────────────────────────────────────────────────────────────
 * INTEGRATION GUIDE
 * ───────────────────────────────────────────────────────────────────
 *
 * 1. INITIALISE ON LOGIN (add to both portals after doSuccessLogin):
 *
 *    const cfg = JSON.parse(localStorage.getItem('supabase_cfg_' + schoolId) || '{}');
 *    if (cfg.url && cfg.key) {
 *      EduSync.init({ schoolId, supabaseUrl: cfg.url, supabaseKey: cfg.key })
 *        .then(() => EduSync.pull.all())  // pull fresh data on login
 *        .then(() => console.log('Sync ready'));
 *    }
 *
 * 2. PUSH AFTER SAVES (patch into existing save functions):
 *
 *    // TPDS — after saveLessonsData():
 *    function saveLessonsData(a) {
 *      localStorage.setItem(SK.lessons, JSON.stringify(a));
 *      EduSync.push.lessons();          // ← add this line
 *    }
 *
 *    // JSMS — after saveAll():
 *    function saveAll() {
 *      try {
 *        localStorage.setItem('edu2_l',    JSON.stringify(LEARNERS));
 *        localStorage.setItem('edu2_s',    JSON.stringify(SUMMATIVE));
 *        localStorage.setItem('edu2_pays', JSON.stringify(PAYMENTS));
 *        localStorage.setItem('edu2_att',  JSON.stringify(ATTENDANCE));
 *        EduSync.push.learners();        // ← add these
 *        EduSync.push.scores();
 *        EduSync.push.feePayments();
 *        EduSync.push.attendance();
 *      } catch(e) { ... }
 *    }
 *
 * 3. LISTEN FOR SYNC EVENTS (optional UI feedback):
 *
 *    window.addEventListener('edusync:push:done', e => {
 *      console.log('Sync results:', e.detail.results);
 *    });
 *    window.addEventListener('edusync:drain', e => {
 *      console.log('Offline queue drained:', e.detail);
 *    });
 *
 * 4. DIAGNOSTICS (run in browser console):
 *
 *    EduSync.status.summary().then(console.log);
 *    EduSync.status.testConnection().then(console.log);
 *    EduSync.status.queueDepth().then(d => console.log('Queue:', d));
 *
 * ───────────────────────────────────────────────────────────────────
 * SUPABASE CLIENT-SIDE SETUP
 * ───────────────────────────────────────────────────────────────────
 *
 * In your Supabase project SQL editor, set the school_id context
 * for RLS. Add this to your Supabase Edge Function or use the
 * Postgres session variable approach:
 *
 *    -- Called automatically when x-school-id header is present:
 *    CREATE OR REPLACE FUNCTION set_school_context()
 *    RETURNS void LANGUAGE plpgsql AS $$
 *    BEGIN
 *      PERFORM set_config(
 *        'app.school_id',
 *        current_setting('request.headers', true)::json->>'x-school-id',
 *        true
 *      );
 *    END;
 *    $$;
 *
 *    -- Add to your schema as a trigger on first connection, or
 *    -- call from your app before any query.
 *
 * ───────────────────────────────────────────────────────────────────
 */
