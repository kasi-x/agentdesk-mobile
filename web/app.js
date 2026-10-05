/* AgentDesk web triage UI — vanilla JS, no build step.
 *
 * NFR-2.1: every payload string reaches the DOM only via textContent /
 * createElement — never innerHTML or eval.
 * FR-2.1/2.2/2.3: optimistic removal, async POST, localStorage offline queue.
 * FR-3.2/3.3: dismissTask removes cards everywhere; 409 → "処理済み" toast.
 */
'use strict';

const LS_HUB = 'agentdesk.hub';
const LS_TOKEN = 'agentdesk.token';
const LS_QUEUE = 'agentdesk.offlineQueue';
const LS_SNOOZED = 'agentdesk.snoozedIds';

const BACKOFF_INIT_MS = 1000;
const BACKOFF_MAX_MS = 30_000;
const TOAST_MS = 3000;

/** Risk levels mirror mobile task_card.dart (I-102). */
function riskLevel(task) {
  const impact = task.impact || {};
  const irreversible = impact.reversible === false;
  if (task.severity === 'critical' && irreversible) return 'locked';
  if (task.severity === 'critical' || irreversible ||
      (impact.cost && impact.cost.amount > 0)) return 'high';
  return 'normal';
}

/* ---------------- state ---------------- */

/** Newest-first pending stack; snoozed tasks sit at the tail. */
const state = {
  hub: localStorage.getItem(LS_HUB) || location.origin,
  token: localStorage.getItem(LS_TOKEN) || '',
  stack: [], // TaskCard[]
  snoozedIds: new Set(readJson(LS_SNOOZED, [])),
  queue: readJson(LS_QUEUE, []), // ActionReply[] persisted FIFO
  es: null,
  backoff: BACKOFF_INIT_MS,
  reconnectTimer: null,
  inspectTask: null, // TaskCard currently open in the sheet
  undoable: new Map(), // taskId → task; cards triaged this session (I-104)
};

function readJson(key, fallback) {
  try {
    const raw = localStorage.getItem(key);
    return raw ? JSON.parse(raw) : fallback;
  } catch {
    return fallback;
  }
}

function persistQueue() {
  localStorage.setItem(LS_QUEUE, JSON.stringify(state.queue));
}

function persistSnoozed() {
  localStorage.setItem(LS_SNOOZED, JSON.stringify([...state.snoozedIds]));
}

/* ---------------- tiny DOM helpers (textContent only) ---------------- */

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined && text !== null) node.textContent = String(text);
  return node;
}

function clear(node) {
  node.textContent = '';
}

function toast(message, { undoTaskId } = {}) {
  const t = el('div', 'toast', message);
  if (undoTaskId) {
    const btn = el('button', 'toast-undo', '元に戻す');
    btn.type = 'button';
    btn.onclick = () => {
      t.remove();
      undo(undoTaskId);
    };
    t.appendChild(btn);
  }
  document.getElementById('toasts').appendChild(t);
  setTimeout(() => t.remove(), undoTaskId ? 5000 : TOAST_MS);
}

/* ---------------- API ---------------- */

function apiUrl(path) {
  return `${state.hub.replace(/\/$/, '')}${path}`;
}

function authHeaders() {
  return { Authorization: `Bearer ${state.token}`, 'Content-Type': 'application/json' };
}

async function fetchState() {
  const res = await fetch(apiUrl('/api/v1/state'), { headers: authHeaders() });
  if (!res.ok) throw new Error(`state ${res.status}`);
  return res.json();
}

/** POST an action reply. Returns 'ok' | 'conflict' | 'not_found' | throws on network/5xx. */
async function postAction(reply) {
  const res = await fetch(apiUrl('/api/v1/actions'), {
    method: 'POST',
    headers: authHeaders(),
    body: JSON.stringify(reply),
  });
  if (res.ok) return 'ok';
  if (res.status === 409) return 'conflict';
  if (res.status === 404) return 'not_found';
  throw new Error(`action ${res.status}`);
}

/** POST an undo request. Returns 'ok' | 'too_late' | 'not_found' | throws. */
async function postUndo(taskId, nonce) {
  const res = await fetch(apiUrl('/api/v1/actions/undo'), {
    method: 'POST',
    headers: authHeaders(),
    body: JSON.stringify({ taskId, nonce }),
  });
  if (res.ok) return 'ok';
  if (res.status === 409) return 'too_late'; // too_late or bad_nonce
  if (res.status === 404) return 'not_found';
  throw new Error(`undo ${res.status}`);
}

const UNDOABLE_LIMIT = 30;

function rememberUndoable(task) {
  state.undoable.delete(task.taskId); // refresh recency
  state.undoable.set(task.taskId, task);
  while (state.undoable.size > UNDOABLE_LIMIT) {
    state.undoable.delete(state.undoable.keys().next().value);
  }
}

/**
 * Revert a triage decision (I-104). Offline-queued decisions are dropped
 * locally; sent ones ask the hub, which re-broadcasts the card via
 * createTaskCard (next snapshot restores it regardless).
 */
async function undo(taskId) {
  const task = state.undoable.get(taskId);
  if (!task) {
    toast('元に戻せません（この端末では操作していません）');
    return;
  }
  state.undoable.delete(taskId);
  const qi = state.queue.findIndex((r) => r.taskId === taskId);
  if (qi >= 0) {
    state.queue.splice(qi, 1);
    persistQueue();
    state.stack.unshift(task);
    render();
    toast('元に戻しました（送信前の操作を取り消し）');
    return;
  }
  try {
    const result = await postUndo(taskId, task.nonce);
    if (result === 'ok') {
      toast('元に戻しました');
    } else {
      toast('元に戻せません（確定済み）');
    }
  } catch {
    state.undoable.set(taskId, task); // keep for a later retry
    toast('オフライン: まだ元に戻せていません');
  }
}

/* ---------------- optimistic triage (FR-2.1/2.2/2.3) ---------------- */

function triage(task, { actionName, data, source }) {
  removeFromStack(task.taskId);
  rememberUndoable(task);
  render();
  const reply = {
    taskId: task.taskId,
    nonce: task.nonce,
    actionName,
    source,
    data: data || {},
  };
  deliver(reply, task);
}

async function deliver(reply, task) {
  try {
    const result = await postAction(reply);
    if (result === 'ok') {
      toast(`${reply.actionName} しました`, { undoTaskId: task.taskId });
    } else if (result === 'conflict') {
      toast('処理済み — このタスクはすでに別デバイスで処理されています');
    } else if (result === 'not_found') {
      toast('タスクが見つかりません');
    }
  } catch {
    // Offline / 5xx: persist FIFO (FR-2.3); snapshot sync excludes queued ids.
    state.queue.push(reply);
    persistQueue();
    toast('オフライン: 操作をキューに保存しました', { undoTaskId: task.taskId });
    render();
  }
}

async function flushQueue() {
  while (state.queue.length > 0) {
    const reply = state.queue[0];
    try {
      const result = await postAction(reply);
      if (result === 'conflict') toast('処理済み — キュー済みの操作が競合しました');
      if (result === 'not_found') toast('キュー済みのタスクが見つかりません');
      state.queue.shift();
      persistQueue();
    } catch {
      return; // still offline — retry on next reconnect
    }
  }
  render();
}

/* ---------------- stack management ---------------- */

function removeFromStack(taskId) {
  const i = state.stack.findIndex((t) => t.taskId === taskId);
  if (i >= 0) state.stack.splice(i, 1);
  state.snoozedIds.delete(taskId);
  persistSnoozed();
}

function queuedTaskIds() {
  return new Set(state.queue.map((r) => r.taskId));
}

/** Rebuild stack from a server snapshot (oldest→newest array). */
function applySnapshot(tasks) {
  const queued = queuedTaskIds();
  const pending = (tasks || []).filter(
    (t) => t && t.taskId && !queued.has(t.taskId),
  );
  // Newest first; locally snoozed ids move to the tail.
  const fresh = [];
  const snoozed = [];
  for (const t of pending.slice().reverse()) {
    (state.snoozedIds.has(t.taskId) ? snoozed : fresh).push(t);
  }
  state.stack = fresh.concat(snoozed);
  render();
}

function snooze(task) {
  const i = state.stack.findIndex((t) => t.taskId === taskId);
  if (i < 0) return;
  const [t] = state.stack.splice(i, 1);
  state.snoozedIds.add(t.taskId);
  persistSnoozed();
  state.stack.push(t);
  render();
  toast('スヌーズ — 山札の最後尾へ');
}

/* ---------------- SSE ---------------- */

function connect() {
  if (state.es) {
    state.es.close();
    state.es = null;
  }
  if (!state.token) {
    setConnected(false);
    return;
  }
  const url = `${apiUrl('/api/v1/stream')}?token=${encodeURIComponent(state.token)}`;
  const es = new EventSource(url);
  state.es = es;

  es.onopen = () => {
    state.backoff = BACKOFF_INIT_MS;
    setConnected(true);
  };
  es.addEventListener('snapshot', (e) => {
    setConnected(true);
    try {
      const data = JSON.parse(e.data);
      applySnapshot(data.tasks || []);
      flushQueue();
    } catch {
      /* malformed snapshot — keep current stack */
    }
  });
  es.addEventListener('createTaskCard', (e) => {
    try {
      const task = JSON.parse(e.data);
      if (!task || !task.taskId) return;
      // The hub may re-broadcast a card we already hold (I-203 escalate:
      // rotated nonce + bumped severity) — the hub is the single source
      // of truth (P9), so replace in place instead of ignoring.
      const i = state.stack.findIndex((t) => t.taskId === task.taskId);
      if (i >= 0) {
        state.stack[i] = task;
        render();
        return;
      }
      if (state.snoozedIds.has(task.taskId)) state.stack.push(task);
      else state.stack.unshift(task);
      render();
    } catch {
      /* ignore malformed event */
    }
  });
  es.addEventListener('dismissTask', (e) => {
    try {
      const data = JSON.parse(e.data);
      if (!data || !data.taskId) return;
      const had = state.stack.some((t) => t.taskId === data.taskId);
      removeFromStack(data.taskId);
      if (had) {
        render();
        toast(
          String(data.by || '').startsWith('on_expire')
            ? '期限のため自動処理されました'
            : `他デバイスで処理されました (${data.by || 'unknown'})`,
        );
      }
    } catch {
      /* ignore malformed event */
    }
  });
  es.onerror = () => {
    setConnected(false);
    es.close();
    state.es = null;
    scheduleReconnect();
  };
}

function scheduleReconnect() {
  if (state.reconnectTimer) return;
  const delay = state.backoff;
  state.backoff = Math.min(state.backoff * 2, BACKOFF_MAX_MS);
  state.reconnectTimer = setTimeout(() => {
    state.reconnectTimer = null;
    connect();
  }, delay);
}

function setConnected(on) {
  document.getElementById('status-dot').classList.toggle('on', !!on);
}

/* ---------------- rendering ---------------- */

const ORDERED_CATALOG = new Set(['Text', 'DiffBox', 'Chips']);

/* Animate UI counting-number, translated: tween the pending count so a
 * batch of dismissals ticks down instead of jumping. */
let _pendingShown = null;
let _pendingRaf = 0;

function setPendingCount(target) {
  const el = document.getElementById('pending-count');
  const from = _pendingShown;
  _pendingShown = target;
  if (from === null || from === target) {
    el.textContent = `${target} pending`;
    return;
  }
  cancelAnimationFrame(_pendingRaf);
  const start = performance.now();
  const DURATION = 420;
  const step = (now) => {
    const t = Math.min(1, (now - start) / DURATION);
    const eased = 1 - Math.pow(1 - t, 3); // easeOutCubic
    el.textContent = `${Math.round(from + (target - from) * eased)} pending`;
    if (t < 1) _pendingRaf = requestAnimationFrame(step);
  };
  _pendingRaf = requestAnimationFrame(step);
}

function timeAgo(iso) {
  const t = new Date(iso);
  if (Number.isNaN(t.getTime())) return '';
  const s = Math.max(0, (Date.now() - t.getTime()) / 1000);
  if (s < 60) return 'たった今';
  if (s < 3600) return `${Math.floor(s / 60)}分前`;
  if (s < 86400) return `${Math.floor(s / 3600)}時間前`;
  return `${Math.floor(s / 86400)}日前`;
}

function confidenceClass(c) {
  if (c >= 0.9) return 'green';
  if (c >= 0.6) return 'yellow';
  return 'red';
}

/** Render order: children of TriageCard if present, else array order. */
function orderedComponents(task) {
  const list = Array.isArray(task.components) ? task.components : [];
  const root = list.find((c) => c && c.component === 'TriageCard');
  if (root && Array.isArray(root.children)) {
    const byId = new Map(list.map((c) => [c && c.id, c]));
    const resolved = root.children
      .map((id) => byId.get(id))
      .filter((c) => c && c.component !== 'TriageCard');
    // Include any stray components not referenced by the root.
    const rest = list.filter((c) => c && !root.children.includes(c.id));
    return resolved.concat(rest.filter((c) => c.component !== 'TriageCard'));
  }
  return list.filter((c) => c && c.component !== 'TriageCard');
}

/* ---------------- value-aware diff rendering ----------------
 * 「2026-10-05 14:00 → 16:30」はカレンダーの変更に、「$120 → $80」は
 * 金額の変更に見えるように。パースできる値だけ意味づけし、それ以外は
 * 従来のテキスト差分にフォールバックする(どちらも純粋なテキスト描画)。 */
const WEEKDAYS_JA = '日月火水木金土';

function parseValue(raw) {
  const s = String(raw ?? '').trim();
  if (!s) return null;
  let m = s.match(/^(\d{4})-(\d{1,2})-(\d{1,2})[ T](\d{1,2}):(\d{2})(?::\d{2})?$/);
  if (m) {
    const d = new Date(+m[1], +m[2] - 1, +m[3]);
    return {
      kind: 'datetime',
      dateKey: `${m[1]}-${m[2]}-${m[3]}`,
      date: `${+m[2]}月${+m[3]}日(${WEEKDAYS_JA[d.getDay()]})`,
      time: `${String(+m[4]).padStart(2, '0')}:${m[5]}`,
    };
  }
  m = s.match(/^(\d{1,2}):(\d{2})$/);
  if (m) return { kind: 'time', time: `${String(+m[1]).padStart(2, '0')}:${m[2]}` };
  m = s.match(/^([^0-9\s]+)\s*([\d,]+(?:\.\d+)?)$/);
  if (m && /^(?:[$¥€£]|usd|jpy|eur)/i.test(m[1])) {
    return { kind: 'money', symbol: m[1], amount: parseFloat(m[2].replace(/,/g, '')) };
  }
  return null;
}

function minutesOf(time) {
  const [h, m] = time.split(':').map(Number);
  return h * 60 + m;
}

function deltaLabel(bv, av) {
  if (bv.kind === 'datetime' && av.kind === 'datetime' && bv.dateKey === av.dateKey) {
    const diff = minutesOf(av.time) - minutesOf(bv.time);
    const sign = diff >= 0 ? '+' : '−';
    const abs = Math.abs(diff);
    const h = Math.floor(abs / 60);
    const mm = abs % 60;
    return sign + (h ? `${h}時間${mm ? `${mm}分` : ''}` : `${mm}分`);
  }
  if (bv.kind === 'money' && av.kind === 'money' && bv.symbol === av.symbol) {
    const diff = av.amount - bv.amount;
    const sign = diff >= 0 ? '+' : '−';
    return `${sign}${bv.symbol}${Math.abs(diff).toLocaleString('en-US')}`;
  }
  return null;
}

function diffIcon(name, cls) {
  return el('span', `dvv-ic dvv-ic-${name} ${cls || ''}`);
}

function valueChip(v, isBefore) {
  const chip = el('span', `dvv-chip ${isBefore ? 'before' : 'after'}`);
  if (v.kind !== 'money') chip.appendChild(diffIcon('clock'));
  chip.appendChild(el('span', 'dvv-chip-text',
    v.kind === 'money' ? `${v.symbol}${v.amount.toLocaleString('en-US')}` : v.time));
  return chip;
}

/* その日の予定表で「どこからどこへ動いたか」を描く: 変更前の枠(破線)と
 * 変更後の枠(塗り)を時間軸上に重ねる。Event duration は properties.duration
 * (分, 既定60)。すべて表示上の計算で、実データには触れない。 */
function dayTimeline(bv, av, durationMin) {
  const dur = Number.isFinite(durationMin) && durationMin > 0 ? durationMin : 60;
  const b = minutesOf(bv.time);
  const a = minutesOf(av.time);
  let start = Math.max(0, Math.floor(Math.min(b, a) / 60) * 60);
  let end = Math.min(24 * 60, Math.ceil((Math.max(b, a) + dur) / 60) * 60);
  if (end - start < 120) {
    start = Math.max(0, end - 120);
  }
  const span = end - start;
  const pos = (m) => ((m - start) / span) * 100;

  const track = el('div', 'dvv-tl');
  const bars = el('div', 'dvv-tl-bars');
  const beforeBar = el('div', 'dvv-tl-bar before', `変更前 ${bv.time}`);
  beforeBar.style.left = `${pos(b)}%`;
  beforeBar.style.width = `${(dur / span) * 100}%`;
  const afterBar = el('div', 'dvv-tl-bar after', `変更後 ${av.time}`);
  afterBar.style.left = `${pos(a)}%`;
  afterBar.style.width = `${(dur / span) * 100}%`;
  bars.append(beforeBar, afterBar);
  track.appendChild(bars);

  const ticks = el('div', 'dvv-tl-ticks');
  for (let t = start; t <= end; t += 60) {
    const tick = el('span', 'dvv-tl-tick');
    tick.style.left = `${pos(t)}%`;
    tick.appendChild(el('span', 'dvv-tl-tickline'));
    tick.appendChild(el('span', 'dvv-tl-ticklabel',
      `${String(Math.floor(t / 60) % 24).padStart(2, '0')}:00`));
    ticks.appendChild(tick);
  }
  track.appendChild(ticks);
  return track;
}

function renderValuePair(parent, label, beforeRaw, afterRaw, opts = {}) {
  const row = el('div', 'diffbox-row');
  if (label) row.appendChild(el('div', 'diffbox-rowlabel', label));
  const bv = parseValue(beforeRaw);
  const av = parseValue(afterRaw);
  if (bv && av && bv.kind === av.kind) {
    if (bv.kind === 'datetime') {
      const dateRow = el('div', 'dvv-date');
      dateRow.appendChild(diffIcon('calendar'));
      dateRow.appendChild(el('span', 'dvv-date-text', bv.date));
      row.appendChild(dateRow);
    }
    const chips = el('div', 'dvv-chips');
    chips.appendChild(valueChip(bv, true));
    chips.appendChild(diffIcon('arrow-right', 'dvv-arrow'));
    chips.appendChild(valueChip(av, false));
    const delta = deltaLabel(bv, av);
    if (delta) chips.appendChild(el('span', 'dvv-delta', delta));
    row.appendChild(chips);
    if (bv.kind === 'datetime' && bv.dateKey === av.dateKey) {
      row.appendChild(dayTimeline(bv, av, opts.durationMin));
    }
  } else {
    row.appendChild(el('div', 'diff-before', beforeRaw || ''));
    row.appendChild(el('div', 'diff-after', `→ ${afterRaw || ''}`));
  }
  parent.appendChild(row);
}

function renderComponent(comp, task) {
  const box = el('div', 'comp');
  switch (comp.component) {
    case 'Text': {
      const p = comp.properties || {};
      const variant = p.variant === 'title' ? 'title' : p.variant === 'body' ? 'body' : 'caption';
      const t = el('div', `text-${variant}`, p.text || '');
      if (p.source === 'external') t.classList.add('text-external'); // NFR-2.2 quote block
      box.appendChild(t);
      return box;
    }
    case 'DiffBox': {
      const p = comp.properties || {};
      const wrap = el('div', 'diffbox');
      const hl = p.highlight === 'warning' ? 'warning' : p.highlight === 'critical' ? 'critical' : 'info';
      wrap.appendChild(el('div', `diffbox-highlight ${hl}`));
      if (p.title && typeof p.title === 'string') {
        wrap.appendChild(el('div', 'diffbox-title', p.title));
      }
      const pairOpts = { durationMin: Number(p.duration) };
      renderValuePair(wrap, null, p.before, p.after, pairOpts);
      if (Array.isArray(p.rows)) {
        for (const r of p.rows) {
          if (!r || typeof r !== 'object') continue;
          renderValuePair(wrap, r.label || null, r.before, r.after, pairOpts);
        }
      }
      if (typeof p.inline === 'string' && p.inline) {
        // Unified-diff style: + green, - red, context dim. Plain text only.
        const pre = el('div', 'diffbox-inline');
        for (const line of p.inline.split('\n')) {
          const cls = line.startsWith('+') ? 'diff-line-add' : line.startsWith('-') ? 'diff-line-del' : 'diff-line-ctx';
          pre.appendChild(el('div', cls, line === '' ? ' ' : line));
        }
        wrap.appendChild(pre);
      }
      box.appendChild(wrap);
      return box;
    }
    case 'Chips': {
      const p = comp.properties || {};
      const wrap = el('div', 'chips');
      const options = Array.isArray(p.options) ? p.options : [];
      for (const opt of options) {
        const chip = el('button', 'chip', (opt && opt.label) || '?');
        chip.type = 'button';
        chip.addEventListener('click', () => {
          if (opt && opt.actionName) {
            triage(task, { actionName: opt.actionName, data: opt.payload, source: 'quick_chip' });
          } else {
            openInspect(task);
          }
        });
        wrap.appendChild(chip);
      }
      box.appendChild(wrap);
      return box;
    }
    default: {
      // FR-1.3 fallback card for unknown component types.
      const f = el('div', 'fallback');
      f.appendChild(el('div', 'fallback-label', `${comp.component || 'unknown'} — 未対応コンポーネント`));
      f.appendChild(el('div', 'fallback-text', JSON.stringify(comp.properties || {})));
      box.appendChild(f);
      return box;
    }
  }
}

/* ---------------- expiry countdown (I-203) ---------------- */

function countdownParts(expiresAt, onExpire) {
  const ms = Date.parse(expiresAt) - Date.now();
  const verb = { approve: '期限で自動承認', reject: '期限で自動却下', escalate: '期限で緊急化' }[onExpire] || '期限で破棄';
  if (!(ms > 0)) return { cls: 'past', text: '期限切れ · まもなく自動処理' };
  const min = Math.floor(ms / 60000);
  const sec = Math.floor((ms % 60000) / 1000);
  let left;
  if (min >= 60) left = `${Math.floor(min / 60)}時間${min % 60}分`;
  else if (min >= 10) left = `${min}分`;
  else if (min >= 1) left = `${min}分${sec}秒`;
  else left = `${sec}秒`;
  const cls = min <= 5 ? 'urgent' : min <= 30 ? 'soon' : '';
  return { cls, text: `残り ${left} · ${verb}` };
}

/** Text-only refresh — a full render() every few seconds would break
 *  pointer-holds and drags mid-gesture. */
function updateCountdown(stripEl) {
  const parts = countdownParts(stripEl.dataset.expires, stripEl.dataset.onexpire);
  stripEl.className = `countdown ${parts.cls}`.trim();
  stripEl.textContent = parts.text;
}

setInterval(() => {
  document.querySelectorAll('.countdown[data-expires]').forEach(updateCountdown);
}, 5000);

function renderCard(task) {
  const sev = task.severity === 'critical' ? 'critical' : task.severity === 'warning' ? 'warning' : 'info';
  // The card surface itself carries severity (color-pop theme).
  const card = el('div', `card sev-${sev}`);
  const inner = el('div', 'card-inner');

  // Expiry countdown strip (I-203): the hub executes the default
  // behavior at the deadline; this only tells the user what will happen.
  if (typeof task.expiresAt === 'string' && task.expiresAt) {
    const strip = el('div', 'countdown');
    strip.dataset.expires = task.expiresAt;
    strip.dataset.onexpire = task.onExpire || 'drop';
    updateCountdown(strip);
    inner.appendChild(strip);
  }

  // Header: avatar, agent name, time, severity badge.
  const header = el('div', 'card-header');
  const avatar = el('div', 'avatar');
  const agent = task.agent || {};
  if (agent.avatarUrl) {
    const img = el('img');
    img.src = agent.avatarUrl;
    img.alt = '';
    img.referrerPolicy = 'no-referrer';
    avatar.appendChild(img);
  } else {
    avatar.textContent = (agent.name || '?').slice(0, 1).toUpperCase();
  }
  header.appendChild(avatar);
  const agentCol = el('div', 'card-agent');
  agentCol.appendChild(el('div', 'agent-name', agent.name || 'Agent'));
  agentCol.appendChild(el('div', 'card-meta', timeAgo(task.createdAt)));
  header.appendChild(agentCol);
  header.appendChild(el('span', `badge ${sev}`, sev));
  inner.appendChild(header);
  // Impact row: 「承認すると…」+ reversibility / cost badges (I-202).
  const impact = task.impact;
  if (impact && typeof impact === 'object') {
    const row = el('div', 'impact-row');
    if (typeof impact.summary === 'string' && impact.summary) {
      row.appendChild(el('span', 'impact-text', `承認すると ${impact.summary}`));
    }
    const impactBadge = (text, cls) => row.appendChild(el('span', `impact-badge ${cls}`, text));
    if (impact.reversible === false) impactBadge('取り消し不可', 'no');
    else if (impact.reversible === true) impactBadge('取り消し可', 'yes');
    if (impact.cost && typeof impact.cost === 'object' &&
        typeof impact.cost.amount === 'number' && impact.cost.currency) {
      impactBadge(`${impact.cost.currency} ${impact.cost.amount}`, 'cost');
    }
    inner.appendChild(row);
  }

  // Confidence indicator.
  if (typeof task.confidence === 'number') {
    const conf = el('div', 'confidence');
    const pct = Math.round(Math.min(1, Math.max(0, task.confidence)) * 100);
    conf.appendChild(el('span', 'confidence-label', `Confidence: ${pct}%`));
    const bar = el('div', 'confidence-bar');
    const fill = el('div', `confidence-fill ${confidenceClass(task.confidence)}`);
    fill.style.width = `${pct}%`;
    bar.appendChild(fill);
    conf.appendChild(bar);
    inner.appendChild(conf);
    const reasons = Array.isArray(task.confidenceReasons) ? task.confidenceReasons : [];
    if (task.confidence < 0.9 && reasons.length) {
      const rs = el('div', 'reasons');
      for (const r of reasons) rs.appendChild(el('span', 'reason-chip', r));
      inner.appendChild(rs);
    }
  }

  inner.appendChild(el('div', 'summary', task.summary || ''));

  for (const comp of orderedComponents(task)) inner.appendChild(renderComponent(comp, task));
  card.appendChild(inner);

  // Actions row.
  const actions = el('div', 'card-actions');
  const right = task.actions && task.actions.onSwipeRight;
  const left = task.actions && task.actions.onSwipeLeft;

  const approve = el('button', 'btn ok', `${(right && right.label) || 'Approve'}`);
  approve.type = 'button';
  approve.addEventListener('click', () =>
    triage(task, { actionName: (right && right.actionName) || 'approve', data: right && right.payload, source: 'web_ui' }),
  );

  // Reject reason chips (I-118): when the agent supplied candidates,
  // expand them inline; ignoring them (timeout) rejects without a reason.
  const rejectReasons = (task.actions && task.actions.rejectReasons) || [];
  let reasonTimer = null;
  const sendReject = (reasonId) => {
    clearTimeout(reasonTimer);
    const data = Object.assign({}, (left && left.payload) || {});
    if (reasonId != null) data.reason = reasonId;
    triage(task, {
      actionName: (left && left.actionName) || 'reject',
      data,
      source: 'web_ui',
    });
  };
  const reject = el('button', 'btn no', `${(left && left.label) || 'Reject'}`);
  reject.type = 'button';
  if (rejectReasons.length) {
    reject.addEventListener('click', () => {
      reject.style.display = 'none';
      const row = el('div', 'reason-chips');
      row.appendChild(el('span', 'reason-title', '理由 (任意):'));
      for (const r of rejectReasons) {
        const chip = el('button', 'chip', r.label || '?');
        chip.type = 'button';
        chip.addEventListener('click', (e) => { e.stopPropagation(); sendReject(r.id); });
        row.appendChild(chip);
      }
      const skip = el('button', 'chip dim', '理由なし');
      skip.type = 'button';
      skip.addEventListener('click', (e) => { e.stopPropagation(); sendReject(null); });
      row.appendChild(skip);
      actions.appendChild(row);
      reasonTimer = setTimeout(() => sendReject(null), 4000);
    });
  } else {
    reject.addEventListener('click', () => sendReject(null));
  }
  actions.appendChild(approve);

  // Locked (critical + irreversible): approve becomes a hold-to-confirm
  // ring (I-102/I-103). Pointer press fills it; early release cancels.
  if (riskLevel(task) === 'locked') {
    approve.textContent = `${(right && right.label) || '長押しで承認'}`;
    approve.classList.add('hold');
    let holdTimer = null;
    let progress = null;
    const HOLD_MS = 1200;
    approve.addEventListener('pointerdown', (e) => {
      e.preventDefault();
      approve.classList.add('holding');
      progress = el('span', 'hold-progress');
      approve.appendChild(progress);
      progress.animate(
        [{ transform: 'scaleX(0)' }, { transform: 'scaleX(1)' }],
        { duration: HOLD_MS, fill: 'forwards' },
      );
      holdTimer = setTimeout(() => {
        cleanup();
        triage(task, {
          actionName: (right && right.actionName) || 'approve',
          data: right && right.payload,
          source: 'hold_confirm',
        });
      }, HOLD_MS);
    });
    const cleanup = () => {
      clearTimeout(holdTimer);
      holdTimer = null;
      approve.classList.remove('holding');
      progress?.remove();
      progress = null;
    };
    approve.addEventListener('pointerup', cleanup);
    approve.addEventListener('pointerleave', cleanup);
    approve.addEventListener('pointercancel', cleanup);
    approve.addEventListener('contextmenu', (e) => e.preventDefault());
  }

  const inspect = el('button', 'btn primary', 'Inspect');
  inspect.type = 'button';
  inspect.addEventListener('click', () => openInspect(task));

  const snz = el('button', 'btn dim', 'Snooze');
  snz.type = 'button';
  snz.addEventListener('click', () => snooze(task));

  actions.append(reject, inspect, snz);
  card.appendChild(actions);
  return card;
}

function render() {
  const stackEl = document.getElementById('stack');
  clear(stackEl);

  const count = document.getElementById('pending-count');
  if (state.stack.length) {
    count.hidden = false;
    setPendingCount(state.stack.length);
  } else {
    count.hidden = true;
  }

  if (!state.stack.length) {
    const empty = el('div', 'empty');
    empty.appendChild(el('div', '', 'すべてのタスクが処理済み'));
    empty.appendChild(el('div', '', '新しい要求が届くとここに表示されます'));
    stackEl.appendChild(empty);
    return;
  }

  stackEl.appendChild(renderCard(state.stack[0]));

  if (state.stack.length > 1) {
    const queue = el('div', 'queue');
    queue.appendChild(el('div', 'queue-label', `残り ${state.stack.length - 1} 件`));
    for (const t of state.stack.slice(1)) {
      const mini = el('div', 'mini');
      const sev = t.severity === 'critical' ? 'critical' : t.severity === 'warning' ? 'warning' : 'info';
      mini.appendChild(el('span', `mini-badge ${sev}`, sev));
      mini.appendChild(el('span', 'mini-agent', (t.agent && t.agent.name) || 'Agent'));
      mini.appendChild(el('span', 'mini-summary', t.summary || ''));
      if (state.snoozedIds.has(t.taskId)) mini.appendChild(el('span', 'mini-badge info', 'snoozed'));
      queue.appendChild(mini);
    }
    stackEl.appendChild(queue);
  }
}

/* ---------------- inspect sheet (§3.3) ---------------- */

function openInspect(task) {
  state.inspectTask = task;
  renderInspect();
  document.getElementById('sheet-backdrop').hidden = false;
}

function closeInspect() {
  state.inspectTask = null;
  const sheet = document.getElementById('inspect-sheet');
  sheet.hidden = true;
  clear(sheet);
  document.getElementById('sheet-backdrop').hidden = true;
}

function renderInspect() {
  const task = state.inspectTask;
  const sheet = document.getElementById('inspect-sheet');
  clear(sheet);
  if (!task) {
    sheet.hidden = true;
    return;
  }

  sheet.appendChild(el('div', 'sheet-title', task.summary || 'Inspect'));

  for (const comp of orderedComponents(task)) {
    sheet.appendChild(renderComponent(comp, task));
  }

  // Dynamic form catalog (docs/protocol.md §inspectForm).
  const form = (task.actions && Array.isArray(task.actions.inspectForm)) ? task.actions.inspectForm : [];
  const inputs = new Map(); // componentId → () => value

  for (const comp of form) {
    const p = (comp && comp.properties) || {};
    const field = el('div', 'form-field');
    if (p.label) field.appendChild(el('label', '', p.label));

    switch (comp.component) {
      case 'TimePicker': {
        const input = el('input');
        input.type = 'time';
        input.value = typeof p.default === 'string' ? p.default : '';
        field.appendChild(input);
        inputs.set(comp.id, () => input.value);
        break;
      }
      case 'DatePicker': {
        const input = el('input');
        input.type = 'date';
        input.value = typeof p.default === 'string' ? p.default : '';
        field.appendChild(input);
        inputs.set(comp.id, () => input.value);
        break;
      }
      case 'Slider': {
        const row = el('div', 'range-row');
        const input = el('input');
        input.type = 'range';
        input.min = p.min ?? 0;
        input.max = p.max ?? 100;
        if (p.divisions > 1) {
          const raw = (Number(input.max) - Number(input.min)) / (p.divisions - 1);
          input.step = Math.round(raw * 1e6) / 1e6; // avoid float noise in the UI
        }
        input.value = p.default ?? input.min;
        const fmt = (v) => String(parseFloat(Number(v).toPrecision(10)));
        const val = el('span', 'range-value', fmt(input.value));
        input.addEventListener('input', () => { val.textContent = fmt(input.value); });
        row.append(input, val);
        field.appendChild(row);
        inputs.set(comp.id, () => Number(input.value));
        break;
      }
      case 'Segmented': {
        const options = Array.isArray(p.options) ? p.options : [];
        const seg = el('div', 'segmented');
        let selected = null;
        for (const opt of options) {
          const label = typeof opt === 'string' ? opt : (opt && (opt.label || opt.value)) || '?';
          const b = el('button', 'seg', label);
          b.type = 'button';
          b.addEventListener('click', () => {
            seg.querySelectorAll('.seg').forEach((s) => s.classList.remove('selected'));
            b.classList.add('selected');
            selected = typeof opt === 'string' ? opt : (opt && opt.value !== undefined ? opt.value : label);
          });
          seg.appendChild(b);
        }
        field.appendChild(seg);
        inputs.set(comp.id, () => selected);
        break;
      }
      case 'TextField': {
        const input = p.multiline ? el('textarea') : el('input');
        if (!p.multiline) input.type = 'text';
        input.value = typeof p.default === 'string' ? p.default : '';
        field.appendChild(input);
        inputs.set(comp.id, () => input.value);
        break;
      }
      default: {
        // FR-1.3 fallback inside the form too.
        const f = el('div', 'fallback');
        f.appendChild(el('div', 'fallback-label', `${comp.component || 'unknown'} — 未対応コンポーネント`));
        field.appendChild(f);
        break;
      }
    }
    sheet.appendChild(field);
  }

  const row = el('div', 'sheet-actions');
  const submit = el('button', 'btn primary', '修正して承認');
  submit.type = 'button';
  submit.addEventListener('click', () => {
    const values = {};
    for (const [id, getter] of inputs) {
      const v = getter();
      if (v !== undefined && v !== null && v !== '') values[id] = v;
    }
    const right = task.actions && task.actions.onSwipeRight;
    const merged = Object.assign({}, (right && right.payload) || {}, values);
    closeInspect();
    triage(task, { actionName: 'approve', data: merged, source: 'inspect_form' });
  });
  const cancel = el('button', 'btn dim', 'キャンセル');
  cancel.type = 'button';
  cancel.addEventListener('click', closeInspect);
  row.append(cancel, submit);
  sheet.appendChild(row);

  sheet.hidden = false;
}

/* ---------------- keyboard ---------------- */

document.addEventListener('keydown', (e) => {
  if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement) return;
  const top = state.stack[0];
  if (state.inspectTask) {
    if (e.key === 'Escape') closeInspect();
    return;
  }
  if (!top) return;
  const right = top.actions && top.actions.onSwipeRight;
  const left = top.actions && top.actions.onSwipeLeft;
  switch (e.key) {
    case 'ArrowRight':
      triage(top, { actionName: (right && right.actionName) || 'approve', data: right && right.payload, source: 'web_ui' });
      break;
    case 'ArrowLeft':
      triage(top, { actionName: (left && left.actionName) || 'reject', data: left && left.payload, source: 'web_ui' });
      break;
    case 'i':
      openInspect(top);
      break;
    case 's':
      snooze(top);
      break;
  }
});

/* ---------------- settings ---------------- */

function wireSettings() {
  const toggle = document.getElementById('settings-toggle');
  const panel = document.getElementById('settings');
  const hubInput = document.getElementById('hub-input');
  const tokenInput = document.getElementById('token-input');
  const save = document.getElementById('save-settings');

  hubInput.value = state.hub;
  tokenInput.value = state.token;
  panel.hidden = !!state.token; // open until a token exists

  toggle.addEventListener('click', () => {
    panel.hidden = !panel.hidden;
  });
  save.addEventListener('click', () => {
    state.hub = hubInput.value.trim() || location.origin;
    state.token = tokenInput.value.trim();
    localStorage.setItem(LS_HUB, state.hub);
    localStorage.setItem(LS_TOKEN, state.token);
    panel.hidden = true;
    bootstrap();
  });
}

/* ---------------- boot ---------------- */

async function bootstrap() {
  if (state.reconnectTimer) {
    clearTimeout(state.reconnectTimer);
    state.reconnectTimer = null;
  }
  setConnected(false);
  // Cold start (NFR-1.2): snapshot before SSE connects.
  if (state.token) {
    try {
      const data = await fetchState();
      applySnapshot(data.tasks || []);
      flushQueue();
    } catch {
      // SSE snapshot will reconcile.
    }
  }
  connect();
}

document.getElementById('sheet-backdrop').addEventListener('click', closeInspect);
wireSettings();
bootstrap();
