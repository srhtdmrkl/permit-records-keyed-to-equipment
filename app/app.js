// Permit Register: a browser front end over the schema in ../sql and ./sql.
// Every write goes through the database function record(); every rule is a
// trigger. This file renders query results and shows the database's refusals.

const CORE = ['01_assets', '02_events', '03_chain', '04_append_only', '05_open_conditions']
  .map((f) => new URL(`../sql/${f}.sql`, import.meta.url));
const APP = ['10_equipment', '11_catalogue', '12_rules']
  .map((f) => new URL(`sql/${f}.sql`, import.meta.url));
// Bump when the schema changes. A browser holding an older version starts again
// with the example, because old hashes do not check against a new hash function.
const VERSION = '3';
const STORE = 'permit-register';

const PERMIT_TYPES = [
  ['general', 'General work'],
  ['hot_work', 'Hot work'],
  ['confined_space', 'Confined space entry'],
  ['electrical', 'Electrical work'],
];
const TYPE_LABEL = Object.fromEntries(PERMIT_TYPES);

// ── Small helpers ───────────────────────────────────

const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const pad = (n) => String(n).padStart(2, '0');
const localInput = (d = new Date()) =>
  `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
const toPg = (v) => (v ? v.replace('T', ' ') : null);
const T = (col) => `to_char(${col}, 'DD Mon HH24:MI')`;

const saved = {
  get(k) { try { return localStorage.getItem(`${STORE}.${k}`); } catch { return null; } },
  set(k, v) { try { localStorage.setItem(`${STORE}.${k}`, v); } catch { /* private window */ } },
};

let db;
let persistent = false;
const ui = { tab: saved.get('tab') || 'equipment', eq: saved.get('eq'), permit: saved.get('permit') };

const q = async (sql, params = []) => (await db.query(sql, params)).rows;

async function asApp(fn) {
  await db.exec('SET ROLE permit_app');
  try { return await fn(); } finally { await db.exec('RESET ROLE'); }
}

const who = () => $('#who').value.trim();

// The one way this page writes a record.
function record({ tag = null, permit, type, when, reason = null, detail = {}, closes = null, by = who() }) {
  return asApp(async () => (await db.query(
    'SELECT record($1, $2, $3, $4::timestamptz, $5, $6, $7::jsonb, $8::uuid) AS id',
    [tag, permit, type, toPg(when), by, reason, JSON.stringify(detail), closes],
  )).rows[0].id);
}

function summary(r) {
  const d = r.detail || {};
  const parts = [];
  if (d.work) parts.push(esc(d.work));
  if (d.permit_type && d.permit_type !== 'general') parts.push(esc(TYPE_LABEL[d.permit_type] ?? d.permit_type));
  if (d.method) parts.push(esc(d.method));
  if (d.lel_percent !== undefined) parts.push(`${esc(d.lel_percent)}% LEL`);
  if (d.cross_referenced?.length) parts.push(`Cross-referenced ${esc(d.cross_referenced.join(', '))}`);
  if (d.overridden) {
    parts.push(`<span class="override-tag">Override</span> of ${esc(d.overridden.map((o) => `${o.condition} on ${o.tag} (${o.permit})`).join('; '))}`);
  }
  if (r.reason) parts.push(`“${esc(r.reason)}”`);
  return parts.join(' · ');
}

function table(cols, rows, rowClass = () => '') {
  if (!rows.length) return '<p class="empty">Nothing yet.</p>';
  return `<table><thead><tr>${cols.map((c) => `<th>${c[0]}</th>`).join('')}</tr></thead><tbody>${
    rows.map((r) => `<tr class="${rowClass(r)}">${cols.map((c) => `<td class="${c[2] ?? ''}">${c[1](r)}</td>`).join('')}</tr>`).join('')
  }</tbody></table>`;
}

const statusChip = (s) => `<span class="chip ${s.toLowerCase()}">${esc(s)}</span>`;
const permitLink = (p) => (p ? `<button type="button" class="link" data-goto-permit="${esc(p)}">${esc(p)}</button>` : '');
const eqLink = (t) => `<button type="button" class="link" data-goto-eq="${esc(t)}">${esc(t)}</button>`;

// ── Database ────────────────────────────────────────

async function loadPGlite() {
  try {
    return (await import('../node_modules/@electric-sql/pglite/dist/index.js')).PGlite;
  } catch {
    return (await import('https://cdn.jsdelivr.net/npm/@electric-sql/pglite@0.5.8/dist/index.js')).PGlite;
  }
}

let schemaSql;

async function installSchema() {
  for (const sql of schemaSql) await db.exec(sql);
  await db.exec(`CREATE TABLE app_meta (version TEXT NOT NULL); INSERT INTO app_meta VALUES ('${VERSION}');`);
}

async function wipe() {
  await db.exec('RESET ROLE; DROP SCHEMA public CASCADE; CREATE SCHEMA public; GRANT ALL ON SCHEMA public TO PUBLIC;');
  await installSchema();
}

async function openDb() {
  const PGlite = await loadPGlite();
  schemaSql = await Promise.all([...CORE, ...APP].map(async (u) => {
    const r = await fetch(u);
    if (!r.ok) throw new Error(`could not load ${u.pathname}`);
    return r.text();
  }));
  try {
    db = new PGlite(`idb://${STORE}`);
    await db.waitReady;
    persistent = true;
  } catch {
    db = new PGlite();
    await db.waitReady;
  }
  const tz = Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';
  try { await db.exec(`SET TIME ZONE '${tz.replace(/'/g, '')}'`); } catch { /* unknown zone name: stay on UTC */ }

  const [{ installed }] = await q(`SELECT to_regclass('app_meta') IS NOT NULL AS installed`);
  if (!installed) {
    await installSchema();
    return 'new';
  }
  const [meta] = await q('SELECT version FROM app_meta');
  if (meta?.version !== VERSION) {
    await wipe();
    return 'new';
  }
  return 'existing';
}

// ── Dialog ──────────────────────────────────────────

const dlg = $('#dlg');
let dlgSubmit = null;

async function openDialog({ title, ok, body, submit }) {
  $('#dlgTitle').textContent = title;
  $('#dlgOk').textContent = ok;
  $('#dlgError').textContent = '';
  $('#dlgOk').disabled = false;
  const el = $('#dlgBody');
  el.innerHTML = '';
  await body(el);
  dlgSubmit = submit;
  dlg.showModal();
  const first = $('input:not([type=checkbox]), select, textarea', el);
  if (first) first.focus();
}

$('#dlgCancel').addEventListener('click', () => dlg.close());
$('#dlgForm').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  if (!dlgSubmit) return;
  const btn = $('#dlgOk');
  btn.disabled = true;
  $('#dlgError').textContent = '';
  try {
    if (!who()) throw new Error('Enter your name in "Recording as" at the top. Every record carries it.');
    const data = new FormData($('#dlgForm'));
    await dlgSubmit(data);
    dlg.close();
    await renderAll();
  } catch (err) {
    $('#dlgError').textContent = err.message;
  } finally {
    btn.disabled = false;
  }
});

const fWhen = () => `<label>When <input type="datetime-local" name="when" value="${localInput()}" required></label>`;
const fText = (name, label, { value = '', placeholder = '', required = false } = {}) =>
  `<label>${label} <input type="text" name="${name}" value="${esc(value)}" placeholder="${esc(placeholder)}" ${required ? 'required' : ''}></label>`;
const fSelect = (name, label, options, selected) =>
  `<label>${label} <select name="${name}">${options.map(([v, l]) =>
    `<option value="${esc(v)}" ${v === selected ? 'selected' : ''}>${esc(l)}</option>`).join('')}</select></label>`;

async function equipmentOptions() {
  return (await q('SELECT tag, description FROM assets ORDER BY tag'))
    .map((r) => [r.tag, r.description ? `${r.tag} · ${r.description}` : r.tag]);
}

async function permitOptions(statuses) {
  return (await q('SELECT permit_id, tag, work, status FROM permits WHERE status = ANY($1) ORDER BY permit_id', [statuses]))
    .map((r) => [r.permit_id, `${r.permit_id} · ${r.tag} · ${r.work}${r.status === 'Suspended' ? ' (suspended)' : ''}`]);
}

function needPermitNote(el, what) {
  el.innerHTML = `<p>${what} is recorded under an active permit, and there is none. Issue a permit first.</p>`;
  $('#dlgOk').disabled = true;
}

// ── Actions ─────────────────────────────────────────

async function issuePermit(tag) {
  const [{ next }] = await q(`
    SELECT 'PTW-' || lpad((coalesce(max(substring(permit_id from '[0-9]+$')::int), 0) + 1)::text, 3, '0') AS next
    FROM asset_events WHERE event_type = 'permit_issued'`);
  await openDialog({
    title: 'Issue a permit',
    ok: 'Issue permit',
    body: async (el) => {
      el.innerHTML = `
        ${fText('permit', 'Permit number', { value: next, required: true })}
        ${fSelect('tag', 'Equipment', await equipmentOptions(), tag)}
        ${fSelect('ptype', 'Type', PERMIT_TYPES, 'general')}
        ${fText('work', 'Work', { placeholder: 'Replace mechanical seal', required: true })}
        ${fWhen()}
        <div class="xref" id="xref"></div>`;
      const draw = async () => {
        const rows = await q(`
          SELECT c.permit_id, string_agg(c.label || ' on ' || c.tag, '; ' ORDER BY c.device_timestamp) AS what
          FROM conditions_in_scope((SELECT asset_id FROM assets WHERE tag = $1)) c
          GROUP BY c.permit_id ORDER BY c.permit_id`, [$('[name=tag]', el).value]);
        $('#xref', el).innerHTML = rows.length
          ? `<p class="field-label">Already open on this equipment or equipment linked to it. Tick each permit once you have checked it against this work:</p>
             ${rows.map((r) => `<label class="check"><input type="checkbox" name="xref" value="${esc(r.permit_id)}">
               <span><strong>${esc(r.permit_id)}</strong> ${esc(r.what)}</span></label>`).join('')}`
          : '<p class="ok-note">Nothing else is open on this equipment or equipment linked to it.</p>';
      };
      $('[name=tag]', el).addEventListener('change', draw);
      await draw();
    },
    submit: async (f) => {
      const permit = f.get('permit').trim();
      await record({
        tag: f.get('tag'), permit, type: 'permit_issued', when: f.get('when'),
        detail: { work: f.get('work'), permit_type: f.get('ptype'), cross_referenced: f.getAll('xref') },
      });
      ui.permit = permit;
    },
  });
}

async function isolate({ tag, permit } = {}) {
  await openDialog({
    title: 'Record an isolation',
    ok: 'Record isolation',
    body: async (el) => {
      const permits = await permitOptions(['Active']);
      if (!permits.length) return needPermitNote(el, 'An isolation');
      el.innerHTML = `
        ${fSelect('permit', 'Under permit', permits, permit)}
        ${fSelect('tag', 'Equipment isolated', await equipmentOptions(), tag)}
        ${fText('method', 'How', { placeholder: 'Suction and discharge valves locked closed; breaker locked off' })}
        ${fWhen()}`;
    },
    submit: (f) => record({
      tag: f.get('tag'), permit: f.get('permit'), type: 'isolated', when: f.get('when'),
      detail: f.get('method') ? { method: f.get('method') } : {},
    }),
  });
}

async function removeProtection({ tag, permit } = {}) {
  const types = (await q(`SELECT event_type, label FROM condition_types WHERE kind = 'protection' AND opens ORDER BY label`))
    .map((r) => [r.event_type, r.label]);
  await openDialog({
    title: 'Record a removed protection',
    ok: 'Record',
    body: async (el) => {
      const permits = await permitOptions(['Active']);
      if (!permits.length) return needPermitNote(el, 'A removed protection');
      el.innerHTML = `
        <p class="sub">Anything that takes away a layer of protection: a relief valve off, a trip inhibited, a guard removed. It stays open on the equipment until a record says it is back.</p>
        ${fSelect('permit', 'Under permit', permits, permit)}
        ${fSelect('tag', 'Equipment', await equipmentOptions(), tag)}
        ${fSelect('type', 'What was removed', types, types[0]?.[0])}
        ${fText('reason', 'Note', { placeholder: 'Valve to workshop for bench test; blind flange fitted' })}
        ${fWhen()}`;
    },
    submit: (f) => record({ tag: f.get('tag'), permit: f.get('permit'), type: f.get('type'), when: f.get('when'), reason: f.get('reason') }),
  });
}

async function gasTest({ tag, permit } = {}) {
  await openDialog({
    title: 'Record a gas test',
    ok: 'Record gas test',
    body: async (el) => {
      const permits = await permitOptions(['Active', 'Suspended']);
      if (!permits.length) return needPermitNote(el, 'A gas test');
      if (!tag && permit) tag = (await q('SELECT tag FROM permits WHERE permit_id = $1', [permit]))[0]?.tag;
      el.innerHTML = `
        ${fSelect('permit', 'Under permit', permits, permit)}
        ${fSelect('tag', 'Where', await equipmentOptions(), tag)}
        <label>Reading, % of the lower explosive limit <input type="number" name="lel" min="0" max="100" step="0.1" required></label>
        ${fWhen()}`;
    },
    submit: (f) => record({
      tag: f.get('tag'), permit: f.get('permit'), type: 'gas_test', when: f.get('when'),
      detail: { lel_percent: Number(f.get('lel')) },
    }),
  });
}

async function reinstate(c) {
  const [closer] = await q('SELECT event_type, label FROM condition_types WHERE closes = $1', [c.event_type]);
  await openDialog({
    title: closer.label,
    ok: 'Record',
    body: async (el) => {
      const permits = await permitOptions(['Active']);
      if (!permits.length) return needPermitNote(el, 'Reinstating a protection');
      // Without this note the select would silently fall back to another permit.
      const ownActive = permits.some(([v]) => v === c.permit_id);
      el.innerHTML = `
        <p>Closes: <strong>${esc(c.label)}</strong> on ${esc(c.tag)}, recorded under ${esc(c.permit_id)} at ${esc(c.since)}.</p>
        ${ownActive ? '' : `<p class="sub">${esc(c.permit_id)} is not active. Revalidate it first, or choose the permit this work is done under.</p>`}
        ${fSelect('permit', 'Under permit', permits, c.permit_id)}
        ${fText('reason', 'Note', { placeholder: 'Refitted, set pressure tested' })}
        ${fWhen()}`;
    },
    submit: (f) => record({
      tag: c.tag, permit: f.get('permit'), type: closer.event_type, when: f.get('when'),
      reason: f.get('reason'), closes: c.event_id,
    }),
  });
}

async function release(c) {
  const blockers = await q(`SELECT b.*, ${T('b.device_timestamp')} AS since FROM release_blockers($1) b`, [c.event_id]);
  await openDialog({
    title: `Release the isolation on ${c.tag}`,
    ok: blockers.length ? 'Release' : 'Release isolation',
    body: async (el) => {
      el.innerHTML = blockers.length
        ? `<div class="verdict stop">Blocked. Still open on ${esc(c.tag)} or equipment linked to it:</div>
           <ul class="blockers">${blockers.map((b) => `<li><strong>${esc(b.label)}</strong> on ${esc(b.tag)}
             <span class="meta">${esc(b.relation === 'self' ? '' : `${b.relation} · `)}${esc(b.permit_id)} · since ${esc(b.since)}</span></li>`).join('')}</ul>
           <p class="sub">The database refuses this release. To release anyway, override and give the reason. The record will name every condition above.</p>
           <label class="check"><input type="checkbox" name="override" value="1"> <span>Override</span></label>
           <label>Reason <textarea name="reason" rows="2" placeholder="Why it is safe to release with these open"></textarea></label>
           ${fWhen()}`
        : `<div class="verdict go">Nothing open on ${esc(c.tag)} or equipment linked to it stops this release.</div>
           ${fText('reason', 'Note', { placeholder: 'Work complete, line walked' })}
           ${fWhen()}`;
    },
    submit: (f) => record({
      tag: c.tag, permit: c.permit_id, type: 'isolation_released', when: f.get('when'),
      reason: f.get('reason'), closes: c.event_id, detail: f.get('override') ? { override: true } : {},
    }),
  });
}

// Reads the condition fresh at click time; it may have closed since the screen was drawn.
async function withCondition(id, action) {
  const [c] = await q(`
    SELECT oc.event_id, oc.event_type, oc.permit_id, a.tag, ct.label, ct.kind, ${T('oc.device_timestamp')} AS since
    FROM open_conditions oc JOIN assets a USING (asset_id) JOIN condition_types ct USING (event_type)
    WHERE oc.event_id = $1`, [id]);
  if (c) await action(c);
  else await renderAll();
}

function permitChange(type, title, ok, placeholder) {
  return (permit) => openDialog({
    title: `${title} ${permit}`,
    ok,
    body: async (el) => {
      el.innerHTML = `${fText('reason', 'Reason', { placeholder })}${fWhen()}`;
    },
    submit: (f) => record({ permit, type, when: f.get('when'), reason: f.get('reason') }),
  });
}
const suspend = permitChange('permit_suspended', 'Suspend', 'Suspend permit', 'Work not finished at end of shift');
const revalidate = permitChange('permit_revalidated', 'Revalidate', 'Revalidate permit', 'Conditions checked; work resumes');
const closePermit = permitChange('permit_closed', 'Close', 'Close permit', 'Work complete; area clear');

// ── Equipment tab ───────────────────────────────────

async function renderEquipment() {
  const assets = await q(`
    SELECT a.tag, a.description, p.tag AS parent,
           (SELECT count(*)::int FROM open_conditions oc WHERE oc.asset_id = a.asset_id) AS n_open,
           (SELECT count(*)::int FROM open_conditions oc JOIN condition_types ct USING (event_type)
             WHERE oc.asset_id = a.asset_id AND ct.blocks_release) AS n_block
    FROM assets a LEFT JOIN assets p ON p.asset_id = a.parent_asset_id
    ORDER BY a.tag`);

  if (!assets.length) {
    $('#eqList').innerHTML = '';
    $('#eqScreen').innerHTML = `<div class="card"><h2>No equipment yet</h2>
      <p>Add equipment under <button type="button" class="link" data-goto-tab="setup">Equipment list</button>, or load the example there.</p></div>`;
    return;
  }
  if (!assets.some((a) => a.tag === ui.eq)) ui.eq = assets[0].tag;

  const kids = new Map();
  for (const a of assets) {
    const k = a.parent && assets.some((x) => x.tag === a.parent) ? a.parent : '';
    if (!kids.has(k)) kids.set(k, []);
    kids.get(k).push(a);
  }
  const item = (a, depth) => {
    const badge = a.n_block ? `<span class="badge stop">${a.n_block} open</span>`
      : a.n_open ? '<span class="badge iso">isolated</span>' : '';
    return `<button type="button" class="eq-item ${a.tag === ui.eq ? 'on' : ''}" data-goto-eq="${esc(a.tag)}" style="padding-left:${12 + depth * 18}px">
        <span><strong>${esc(a.tag)}</strong><span class="desc">${esc(a.description ?? '')}</span></span>${badge}</button>
      ${(kids.get(a.tag) ?? []).map((k) => item(k, depth + 1)).join('')}`;
  };
  $('#eqList').innerHTML = (kids.get('') ?? []).map((a) => item(a, 0)).join('');

  const [a] = await q('SELECT asset_id, tag, description, location FROM assets WHERE tag = $1', [ui.eq]);
  const rel = await q(`SELECT x.tag, s.relation FROM asset_scope($1) s JOIN assets x USING (asset_id)
                       WHERE s.relation <> 'self' ORDER BY s.relation, x.tag`, [a.asset_id]);
  const open = await q(`SELECT c.*, ${T('c.device_timestamp')} AS since FROM conditions_in_scope($1) c`, [a.asset_id]);
  const hist = await q(`
    SELECT e.ingest_seq::int AS n, ${T('e.device_timestamp')} AS t, x.tag, e.permit_id, ct.label, e.detail, e.reason, e.recorded_by
    FROM asset_events e
    JOIN asset_scope($1) s  ON s.asset_id = e.asset_id
    JOIN assets x           ON x.asset_id = e.asset_id
    JOIN condition_types ct ON ct.event_type = e.event_type
    ORDER BY e.device_timestamp DESC, e.ingest_seq DESC`, [a.asset_id]);

  // The scope shown here is the release scope for an isolation on this equipment only.
  // An isolation on equipment it belongs to has a wider scope; its Release button checks that.
  const blocking = open.filter((c) => c.blocks_release);
  const verdict = blocking.length
    ? `<div class="verdict stop">${blocking.length} open ${blocking.length === 1 ? 'condition' : 'conditions'} would block releasing an isolation on ${esc(a.tag)}.</div>`
    : open.length
      ? `<div class="verdict go">Nothing open here would block releasing an isolation on ${esc(a.tag)}.</div>`
      : `<div class="verdict go">Nothing open on ${esc(a.tag)} or equipment linked to it.</div>`;

  const groups = ['belongs to it', 'it belongs to'].map((r) => {
    const tags = rel.filter((x) => x.relation === r).map((x) => eqLink(x.tag));
    return tags.length ? `<p class="rel"><span class="field-label">${r === 'belongs to it' ? 'Belongs to it' : 'It belongs to'}</span> ${tags.join(', ')}</p>` : '';
  }).join('');

  const action = (c) => {
    if (c.kind === 'isolation') return `<button type="button" class="btn small" data-act="release" data-id="${c.event_id}">Release</button>`;
    if (c.kind === 'protection') return `<button type="button" class="btn small" data-act="reinstate" data-id="${c.event_id}">Reinstate</button>`;
    return `<button type="button" class="btn small ghost" data-goto-permit="${esc(c.permit_id)}">Open permit</button>`;
  };

  $('#eqScreen').innerHTML = `
    <div class="card">
      <p class="kicker">${esc(a.location ?? '')}</p>
      <h2>${esc(a.tag)} <span class="h-desc">${esc(a.description ?? '')}</span></h2>
      ${groups}
      ${verdict}
      <h3>Open now on ${esc(a.tag)} and equipment linked to it</h3>
      <div class="scroll">${table([
        ['Equipment', (c) => `${c.tag === a.tag ? esc(c.tag) : eqLink(c.tag)}${c.relation === 'self' ? '' : `<span class="meta">${esc(c.relation)}</span>`}`, 'nowrap'],
        ['Condition', (c) => `<strong>${esc(c.label)}</strong>${summary(c) ? `<span class="meta">${summary(c)}</span>` : ''}`],
        ['Permit', (c) => permitLink(c.permit_id), 'nowrap'],
        ['Since', (c) => esc(c.since), 'nowrap'],
        ['', action, 'nowrap right'],
      ], open, (c) => (c.blocks_release ? 'flag' : ''))}</div>
      <div class="row actions">
        <button type="button" class="btn" data-act="issue">Issue a permit on ${esc(a.tag)}</button>
        <button type="button" class="btn ghost" data-act="isolate">Isolate</button>
        <button type="button" class="btn ghost" data-act="remove">Remove a protection</button>
        <button type="button" class="btn ghost" data-act="gas">Gas test</button>
      </div>
    </div>
    <div class="card">
      <h3>History of ${esc(a.tag)} and equipment linked to it</h3>
      <div class="scroll">${table([
        ['When', (r) => esc(r.t), 'nowrap'],
        ['Equipment', (r) => esc(r.tag), 'nowrap'],
        ['Record', (r) => `<strong>${esc(r.label)}</strong>${summary(r) ? `<span class="meta">${summary(r)}</span>` : ''}`],
        ['Permit', (r) => permitLink(r.permit_id), 'nowrap'],
        ['By', (r) => esc(r.recorded_by), 'nowrap'],
      ], hist)}</div>
    </div>`;
}

// ── Permits tab ─────────────────────────────────────

async function renderPermits() {
  const list = await q(`SELECT permit_id, tag, work, status, permit_type FROM permits
                        ORDER BY (status = 'Closed'), issued_at DESC`);
  if (!list.length) {
    $('#permitList').innerHTML = '';
    $('#permitScreen').innerHTML = `<div class="card"><h2>No permits yet</h2>
      <p>Open a piece of equipment under <button type="button" class="link" data-goto-tab="equipment">Equipment</button> and issue a permit on it.</p></div>`;
    return;
  }
  if (!list.some((p) => p.permit_id === ui.permit)) ui.permit = list[0].permit_id;

  $('#permitList').innerHTML = list.map((p) => `
    <button type="button" class="eq-item ${p.permit_id === ui.permit ? 'on' : ''}" data-goto-permit="${esc(p.permit_id)}">
      <span><strong>${esc(p.permit_id)}</strong><span class="desc">${esc(p.tag)} · ${esc(p.work)}</span></span>${statusChip(p.status)}
    </button>`).join('');

  const [p] = await q(`SELECT p.*, ${T('p.issued_at')} AS issued, ${T('p.status_since')} AS since, ${T('p.closed_at')} AS closed
                       FROM permits p WHERE permit_id = $1`, [ui.permit]);
  const held = await q(`
    SELECT oc.event_id, oc.event_type, oc.permit_id, oc.detail, oc.reason, a.tag, ct.label, ct.kind, ${T('oc.device_timestamp')} AS since
    FROM open_conditions oc JOIN assets a USING (asset_id) JOIN condition_types ct USING (event_type)
    WHERE oc.permit_id = $1 AND oc.event_type <> 'permit_issued'
    ORDER BY oc.device_timestamp`, [p.permit_id]);
  const recs = await q(`
    SELECT ${T('e.device_timestamp')} AS t, a.tag, ct.label, e.detail, e.reason, e.recorded_by
    FROM asset_events e JOIN assets a USING (asset_id) JOIN condition_types ct USING (event_type)
    WHERE e.permit_id = $1 ORDER BY e.device_timestamp, e.ingest_seq`, [p.permit_id]);

  const buttons = {
    Active: `<button type="button" class="btn" data-pact="suspend">Suspend</button>
             <button type="button" class="btn" data-pact="close">Close</button>
             <button type="button" class="btn ghost" data-pact="isolate">Isolate</button>
             <button type="button" class="btn ghost" data-pact="remove">Remove a protection</button>
             <button type="button" class="btn ghost" data-pact="gas">Gas test</button>`,
    Suspended: `<button type="button" class="btn" data-pact="revalidate">Revalidate</button>
                <button type="button" class="btn" data-pact="close">Close</button>
                <button type="button" class="btn ghost" data-pact="gas">Gas test</button>`,
    Closed: '',
  }[p.status];

  const xref = p.cross_referenced?.length ? p.cross_referenced.map(permitLink).join(', ') : 'none needed';
  $('#permitScreen').innerHTML = `
    <div class="card">
      <p class="kicker">${esc(TYPE_LABEL[p.permit_type] ?? 'General work')}</p>
      <h2>${esc(p.permit_id)} ${statusChip(p.status)}</h2>
      <p class="lead">${esc(p.work)}</p>
      <dl class="facts">
        <dt>Equipment</dt><dd>${eqLink(p.tag)}</dd>
        <dt>Issued</dt><dd>${esc(p.issued)} by ${esc(p.issued_by)}</dd>
        ${p.status === 'Suspended' ? `<dt>Suspended</dt><dd>${esc(p.since)}</dd>` : ''}
        ${p.status === 'Closed' ? `<dt>Closed</dt><dd>${esc(p.closed)}</dd>` : ''}
        <dt>Cross-referenced at issue</dt><dd>${xref}</dd>
      </dl>
      ${buttons ? `<div class="row actions">${buttons}</div>` : ''}
    </div>
    <div class="card">
      <h3>Still open from this permit</h3>
      <div class="scroll">${table([
        ['Equipment', (c) => eqLink(c.tag), 'nowrap'],
        ['Condition', (c) => `<strong>${esc(c.label)}</strong>${summary(c) ? `<span class="meta">${summary(c)}</span>` : ''}`],
        ['Since', (c) => esc(c.since), 'nowrap'],
        ['', (c) => (c.kind === 'isolation'
          ? `<button type="button" class="btn small" data-act="release" data-id="${c.event_id}">Release</button>`
          : `<button type="button" class="btn small" data-act="reinstate" data-id="${c.event_id}">Reinstate</button>`), 'nowrap right'],
      ], held, (c) => (c.kind === 'protection' ? 'flag' : ''))}</div>
      <p class="sub">A permit cannot close while a protection it removed is still off. An isolation can outlive its permit; it stays on the equipment until released.</p>
    </div>
    <div class="card">
      <h3>Records under ${esc(p.permit_id)}</h3>
      <div class="scroll">${table([
        ['When', (r) => esc(r.t), 'nowrap'],
        ['Equipment', (r) => esc(r.tag), 'nowrap'],
        ['Record', (r) => `<strong>${esc(r.label)}</strong>${summary(r) ? `<span class="meta">${summary(r)}</span>` : ''}`],
        ['By', (r) => esc(r.recorded_by), 'nowrap'],
      ], recs)}</div>
    </div>`;
}

// ── Log tab ─────────────────────────────────────────

async function renderLog() {
  const [s] = await q(`
    SELECT (SELECT count(*)::int FROM asset_events) AS n,
           (SELECT min(ingest_seq)::int FROM chain_breaks) AS first_break,
           (SELECT encode(event_hash, 'hex') FROM asset_events ORDER BY ingest_seq DESC LIMIT 1) AS seal`);
  const status = !s.n ? '<div class="verdict">No records yet.</div>'
    : s.first_break ? `<div class="verdict stop">Chain broken at record #${s.first_break}. A record was changed or removed outside the application.</div>`
      : `<div class="verdict go">Chain intact across ${s.n} ${s.n === 1 ? 'record' : 'records'}.</div>`;
  $('#chainCard').innerHTML = `
    <h2>Is the log intact?</h2>
    ${status}
    ${s.seal ? `<p class="field-label">Latest seal</p>
      <div class="seal"><code id="sealText">${esc(s.seal)}</code><button type="button" class="btn small ghost" id="copySeal">Copy</button></div>
      <p class="sub">Paste this into your shift report or another system you do not administer. Anyone with full database access can rewrite records and recalculate every seal. They cannot change the copy you kept.</p>` : ''}
    <form class="row" id="sealForm">
      <label class="grow">Check a seal you kept <input id="sealIn" placeholder="64 characters" autocomplete="off"></label>
      <button type="submit" class="btn">Check</button>
    </form>
    <p class="msg" id="sealMsg"></p>`;

  const rows = await q(`
    SELECT e.ingest_seq::int AS n, ${T('e.device_timestamp')} AS happened,
           to_char(e.server_ingest_ts, 'DD Mon HH24:MI:SS') AS entered,
           a.tag, e.permit_id, ct.label, e.detail, e.reason, e.recorded_by,
           e.ingest_seq IN (SELECT ingest_seq FROM chain_breaks) AS broken
    FROM asset_events e JOIN assets a USING (asset_id) JOIN condition_types ct USING (event_type)
    ORDER BY e.ingest_seq DESC`);
  $('#logTable').innerHTML = table([
    ['#', (r) => r.n, 'nowrap'],
    ['Happened', (r) => esc(r.happened), 'nowrap'],
    ['Entered', (r) => esc(r.entered), 'nowrap muted'],
    ['Equipment', (r) => esc(r.tag), 'nowrap'],
    ['Permit', (r) => permitLink(r.permit_id), 'nowrap'],
    ['Record', (r) => `<strong>${esc(r.label)}</strong>${summary(r) ? `<span class="meta">${summary(r)}</span>` : ''}`],
    ['By', (r) => esc(r.recorded_by), 'nowrap'],
  ], rows, (r) => (r.broken ? 'flag' : ''));
}

async function checkSeal(hex) {
  const msg = $('#sealMsg');
  hex = hex.trim().toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(hex)) {
    msg.textContent = 'A seal is 64 characters, 0–9 and a–f.';
    return;
  }
  const [hit] = await q(`SELECT ingest_seq::int AS n,
                                (SELECT count(*)::int FROM asset_events) AS total,
                                (SELECT count(*)::int FROM chain_breaks b WHERE b.ingest_seq <= e.ingest_seq) AS breaks
                         FROM asset_events e WHERE event_hash = decode($1, 'hex')`, [hex]);
  if (!hit) {
    msg.textContent = 'No record carries this seal. If you copied it from this log, a record up to the moment you copied it has been changed or deleted.';
  } else if (hit.breaks) {
    msg.textContent = `This seal belongs to record #${hit.n}, but the chain before it is broken.`;
  } else {
    const added = hit.total - hit.n;
    msg.textContent = `Matches record #${hit.n}. Records 1 to ${hit.n} are unchanged since you copied it.${added ? ` ${added} added since.` : ''}`;
  }
}

async function showAsOf() {
  const at = toPg($('#asOf').value);
  if (!at) return;
  const known = $('#asOfMode').value === 'known';
  const rows = await q(`
    SELECT a.tag, coalesce(ct.open_label, ct.label) AS label, o.permit_id, ${T('o.device_timestamp')} AS since, ${T('o.server_ingest_ts')} AS entered
    FROM open_conditions_at($1::timestamptz, $2) o
    JOIN assets a USING (asset_id) JOIN condition_types ct USING (event_type)
    ORDER BY o.device_timestamp`, [at, known]);
  $('#asOfResult').innerHTML = rows.length
    ? `<div class="scroll">${table([
      ['Equipment', (r) => esc(r.tag), 'nowrap'],
      ['Open', (r) => `<strong>${esc(r.label)}</strong>`],
      ['Permit', (r) => permitLink(r.permit_id), 'nowrap'],
      ['Happened', (r) => esc(r.since), 'nowrap'],
      ['Entered', (r) => esc(r.entered), 'nowrap muted'],
    ], rows)}</div>`
    : `<p class="empty">Nothing was open at that moment${known ? ', as far as the system knew' : ''}.</p>`;
}

async function exportCsv() {
  const rows = await q(`
    SELECT e.ingest_seq::int AS seq, e.device_timestamp::text AS happened, e.server_ingest_ts::text AS entered,
           a.tag, e.permit_id, e.event_type, e.detail::text AS detail, e.reason, e.recorded_by,
           e.closes_event_id::text AS closes, e.event_id::text AS id, encode(e.event_hash, 'hex') AS seal
    FROM asset_events e JOIN assets a USING (asset_id) ORDER BY e.ingest_seq`);
  const cols = ['seq', 'happened', 'entered', 'tag', 'permit_id', 'event_type', 'detail', 'reason', 'recorded_by', 'closes', 'id', 'seal'];
  const cell = (v) => (v == null ? '' : /[",\n]/.test(String(v)) ? `"${String(v).replace(/"/g, '""')}"` : String(v));
  const csv = [cols.join(','), ...rows.map((r) => cols.map((c) => cell(r[c])).join(','))].join('\n');
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv' }));
  a.download = `permit-log-${localInput().slice(0, 10)}.csv`;
  a.click();
  URL.revokeObjectURL(a.href);
}

// ── Equipment list tab ──────────────────────────────

async function renderSetup() {
  const assets = await q(`
    SELECT a.tag, a.description, a.location, p.tag AS parent,
           (SELECT count(*)::int FROM asset_events e WHERE e.asset_id = a.asset_id) AS n
    FROM assets a LEFT JOIN assets p ON p.asset_id = a.parent_asset_id ORDER BY a.tag`);
  const tags = assets.map((a) => a.tag);
  const ownerSelect = (a) => `<select data-parent="${esc(a.tag)}" aria-label="${esc(a.tag)} belongs to">
      <option value="">—</option>${tags.filter((t) => t !== a.tag).map((t) =>
        `<option ${t === a.parent ? 'selected' : ''}>${esc(t)}</option>`).join('')}</select>`;
  $('#assetTable').innerHTML = table([
    ['Tag', (a) => `<strong>${esc(a.tag)}</strong>`, 'nowrap'],
    ['Description', (a) => esc(a.description)],
    ['Location', (a) => esc(a.location)],
    ['Belongs to', ownerSelect, 'nowrap'],
    ['Records', (a) => a.n, 'nowrap'],
    ['', (a) => (a.n ? '' : `<button type="button" class="btn small ghost" data-del-asset="${esc(a.tag)}">Remove</button>`), 'nowrap right'],
  ], assets);

  const opts = (sel = '') => `<option value="">—</option>${tags.map((t) => `<option ${t === sel ? 'selected' : ''}>${esc(t)}</option>`).join('')}`;
  $('#newParent').innerHTML = opts();
  $('#linkChild').innerHTML = opts();
  $('#linkOwner').innerHTML = opts();

  const links = await q(`SELECT c.tag AS child, o.tag AS owner FROM asset_links l
                         JOIN assets c ON c.asset_id = l.asset_id JOIN assets o ON o.asset_id = l.belongs_to
                         ORDER BY c.tag, o.tag`);
  $('#linkTable').innerHTML = links.length ? table([
    ['Equipment', (l) => esc(l.child), 'nowrap'],
    ['Also belongs to', (l) => esc(l.owner), 'nowrap'],
    ['', (l) => `<button type="button" class="btn small ghost" data-del-link="${esc(l.child)}|${esc(l.owner)}">Remove</button>`, 'nowrap right'],
  ], links) : '<p class="empty">No extra links.</p>';

  $('#storeNote').textContent = persistent
    ? 'Records are kept in this browser (IndexedDB) until you clear them. Nothing is sent anywhere.'
    : 'This browser would not keep the records, so they last until you close the page.';
}

const friendly = (err) => {
  const m = err.message;
  if (/duplicate key/.test(m)) return 'That tag is already in the list.';
  if (/foreign key/.test(m)) return 'Other equipment belongs to it. Change that first.';
  return m;
};

// ── Example ─────────────────────────────────────────

async function loadExample() {
  await wipe();
  await db.exec(`
    INSERT INTO assets (tag, description, location) VALUES
        ('P-101', 'Condensate pump A', 'Process area, lower level'),
        ('P-102', 'Condensate pump B', 'Process area, lower level'),
        ('T-205', 'Slop tank', 'Tank farm');
    INSERT INTO assets (tag, description, location, parent_asset_id)
    SELECT 'PSV-12', 'Relief valve, P-101 discharge', 'Process area, upper level', asset_id FROM assets WHERE tag = 'P-101';`);
  const d = new Date();
  d.setDate(d.getDate() - 1);
  const day = localInput(d).slice(0, 10);
  const at = (hhmm) => `${day}T${hhmm}`;
  const steps = [
    { tag: 'T-205', permit: 'PTW-130', type: 'permit_issued', when: at('07:50'), by: 'Supervisor A', detail: { work: 'Weld repair on roof nozzle', permit_type: 'hot_work' } },
    { tag: 'T-205', permit: 'PTW-130', type: 'gas_test', when: at('07:55'), by: 'Technician C', detail: { lel_percent: 0 } },
    { tag: 'P-101', permit: 'PTW-114', type: 'permit_issued', when: at('08:00'), by: 'Supervisor A', detail: { work: 'Pump overhaul', permit_type: 'general' } },
    { tag: 'P-101', permit: 'PTW-114', type: 'isolated', when: at('08:10'), by: 'Supervisor A', detail: { method: 'Suction and discharge valves locked closed; motor breaker locked off' } },
    { tag: 'PSV-12', permit: 'PTW-117', type: 'permit_issued', when: at('09:20'), by: 'Supervisor A', detail: { work: 'Remove relief valve for bench test', permit_type: 'general', cross_referenced: ['PTW-114'] } },
    { tag: 'PSV-12', permit: 'PTW-117', type: 'psv_removed', when: at('09:30'), by: 'Technician C', reason: 'Valve to workshop; blind flange fitted' },
    { tag: null, permit: 'PTW-130', type: 'permit_suspended', when: at('10:15'), by: 'Safety Officer B', reason: 'Gas alarm' },
    { tag: null, permit: 'PTW-117', type: 'permit_suspended', when: at('17:45'), by: 'Technician C', reason: 'Work not finished at end of shift' },
  ];
  for (const s of steps) await record(s);
  ui.eq = 'P-101';
  ui.permit = 'PTW-114';
  saved.set('hint', 'show');
}

function renderHint() {
  const show = saved.get('hint') === 'show';
  $('#hint').hidden = !show;
  if (!show) return;
  $('#hint').innerHTML = `
    <div class="hint-head"><p class="kicker">The example: yesterday's day shift</p>
      <button type="button" class="btn small ghost" id="hideHint">Hide</button></div>
    <p>Pump P-102 has tripped and you want P-101 back. P-101 was isolated for an overhaul that has not started. During the day its relief valve, PSV-12, was taken to the workshop under a different permit, which was suspended at 17:45.</p>
    <ol>
      <li><strong>Equipment → P-101.</strong> The screen lists what is open on the pump and on PSV-12, because the equipment list says PSV-12 belongs to P-101.</li>
      <li><strong>Permits → PTW-114 → Close.</strong> The overhaul removed nothing, so it closes. Its isolation stays on the pump.</li>
      <li><strong>Equipment → P-101 → Release.</strong> The database refuses: the relief valve is still off under PTW-117. You can override with a reason. The record then names the valve, for the next shift and for an investigator.</li>
      <li><strong>To release cleanly:</strong> revalidate PTW-117, reinstate the relief valve, close PTW-117, then release. Try closing PTW-117 before the valve is back: it is refused.</li>
      <li><strong>Permits → PTW-130 → Revalidate.</strong> The hot work was suspended after a gas alarm. Revalidation is refused until a gas test after 10:15 reads 0% of the lower explosive limit.</li>
      <li><strong>Log.</strong> Every step, including each override, is a new line. Copy the seal; edit nothing.</li>
    </ol>`;
  $('#hideHint').addEventListener('click', () => { saved.set('hint', 'hide'); renderHint(); });
}

// ── Wiring ──────────────────────────────────────────

function showTab(tab) {
  ui.tab = tab;
  saved.set('tab', tab);
  $$('.tabs [data-tab]').forEach((b) => b.setAttribute('aria-selected', String(b.dataset.tab === tab)));
  $$('.tab').forEach((s) => { s.hidden = s.id !== `tab-${tab}`; });
}

async function renderAll() {
  await renderEquipment();
  await renderPermits();
  await renderLog();
  await renderSetup();
  renderHint();
  if (ui.eq) saved.set('eq', ui.eq);
  if (ui.permit) saved.set('permit', ui.permit);
}

document.addEventListener('click', async (ev) => {
  const t = ev.target.closest('button');
  if (!t) return;
  const d = t.dataset;
  try {
    if (d.tab) showTab(d.tab);
    else if (d.gotoTab) showTab(d.gotoTab);
    else if (d.gotoEq) { ui.eq = d.gotoEq; showTab('equipment'); await renderAll(); }
    else if (d.gotoPermit) { ui.permit = d.gotoPermit; showTab('permits'); await renderAll(); }
    else if (d.act === 'release') await withCondition(d.id, release);
    else if (d.act === 'reinstate') await withCondition(d.id, reinstate);
    else if (d.act === 'issue') await issuePermit(ui.eq);
    else if (d.act === 'isolate') await isolate({ tag: ui.eq });
    else if (d.act === 'remove') await removeProtection({ tag: ui.eq });
    else if (d.act === 'gas') await gasTest({ tag: ui.eq });
    else if (d.pact === 'suspend') await suspend(ui.permit);
    else if (d.pact === 'revalidate') await revalidate(ui.permit);
    else if (d.pact === 'close') await closePermit(ui.permit);
    else if (d.pact === 'isolate') await isolate({ permit: ui.permit });
    else if (d.pact === 'remove') await removeProtection({ permit: ui.permit });
    else if (d.pact === 'gas') await gasTest({ permit: ui.permit });
    else if (d.delAsset) {
      await db.query('DELETE FROM assets WHERE tag = $1', [d.delAsset]);
      await renderAll();
    } else if (d.delLink) {
      const [child, owner] = d.delLink.split('|');
      await db.query(`DELETE FROM asset_links WHERE asset_id = (SELECT asset_id FROM assets WHERE tag = $1)
                      AND belongs_to = (SELECT asset_id FROM assets WHERE tag = $2)`, [child, owner]);
      await renderAll();
    } else if (t.id === 'copySeal') {
      await navigator.clipboard.writeText($('#sealText').textContent);
      t.textContent = 'Copied';
    }
  } catch (err) {
    const box = d.delAsset ? '#assetMsg' : d.delLink ? '#linkMsg' : null;
    if (box) $(box).textContent = friendly(err);
    else console.error(err);
  }
});

document.addEventListener('change', async (ev) => {
  const sel = ev.target.closest('[data-parent]');
  if (!sel) return;
  $('#assetMsg').textContent = '';
  try {
    await db.query(`UPDATE assets SET parent_asset_id = (SELECT asset_id FROM assets WHERE tag = $2) WHERE tag = $1`,
      [sel.dataset.parent, sel.value || null]);
  } catch (err) {
    $('#assetMsg').textContent = friendly(err);
  }
  await renderAll();
});

document.addEventListener('submit', async (ev) => {
  if (ev.target.id === 'sealForm') { ev.preventDefault(); await checkSeal($('#sealIn').value); }
});

$('#asOfForm').addEventListener('submit', async (ev) => { ev.preventDefault(); await showAsOf(); });
$('#exportCsv').addEventListener('click', exportCsv);

$('#assetForm').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  $('#assetMsg').textContent = '';
  const tag = $('#newTag').value.trim();
  if (!tag) return;
  try {
    await db.query(`INSERT INTO assets (tag, description, location, parent_asset_id)
                    VALUES ($1, nullif($2, ''), nullif($3, ''), (SELECT asset_id FROM assets WHERE tag = $4))`,
      [tag, $('#newDesc').value.trim(), $('#newLoc').value.trim(), $('#newParent').value || null]);
    ev.target.reset();
    await renderAll();
  } catch (err) {
    $('#assetMsg').textContent = friendly(err);
  }
});

$('#linkForm').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  $('#linkMsg').textContent = '';
  try {
    if (!$('#linkChild').value || !$('#linkOwner').value) throw new Error('Choose both.');
    await db.query(`INSERT INTO asset_links SELECT c.asset_id, o.asset_id FROM assets c, assets o WHERE c.tag = $1 AND o.tag = $2`,
      [$('#linkChild').value, $('#linkOwner').value]);
    await renderAll();
  } catch (err) {
    $('#linkMsg').textContent = /duplicate key/.test(err.message) ? 'That link already exists.' : /asset_links_check/.test(err.message) ? 'Equipment cannot belong to itself.' : friendly(err);
  }
});

$('#loadExample').addEventListener('click', async () => {
  if (!confirm('Load the example? This replaces every record and the equipment list in this browser.')) return;
  await loadExample();
  showTab('equipment');
  await renderAll();
});
$('#showSteps').addEventListener('click', () => { saved.set('hint', 'show'); renderHint(); window.scrollTo({ top: 0, behavior: 'smooth' }); });
$('#wipe').addEventListener('click', async () => {
  if (!confirm('Clear every record and the equipment list in this browser? This cannot be undone.')) return;
  await wipe();
  saved.set('hint', 'hide');
  await renderAll();
});

$('#who').value = saved.get('who') ?? '';
$('#who').addEventListener('input', () => saved.set('who', who()));

// ── Boot ────────────────────────────────────────────

const boot = $('#boot');
try {
  const state = await openDb();
  if (state === 'new') {
    await loadExample();
    if (!who()) $('#who').value = 'Night supervisor';
    saved.set('who', who());
  }
  $('#asOf').value = localInput();
  showTab(ui.tab);
  await renderAll();
  boot.hidden = true;
} catch (err) {
  boot.classList.add('error');
  boot.textContent = `The database did not start: ${err.message}`;
  console.error(err);
}
