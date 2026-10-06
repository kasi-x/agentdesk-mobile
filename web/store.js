/* Application state + localStorage persistence.
 * Leaf module: imports nothing, so every other module may depend on it. */

export const LS_HUB = 'agentdesk.hub';
export const LS_TOKEN = 'agentdesk.token';
export const LS_QUEUE = 'agentdesk.offlineQueue';
export const LS_SNOOZED = 'agentdesk.snoozedIds';
export const LS_HISTORY = 'agentdesk.history';
export const LS_PAUSED = 'agentdesk.paused';
export const LS_ORDER = 'agentdesk.order';
export const LS_QUIET = 'agentdesk.quiet';
export const BACKOFF_INIT_MS = 1000;
export const BACKOFF_MAX_MS = 30_000;
export const TOAST_MS = 3000;
export const UNDOABLE_LIMIT = 30;
export const HISTORY_LIMIT = 200;

/** Snooze presets (I-702): +1h default, 明日朝 = next day 08:00 local. */
export const SNOOZE_OPTIONS = [
  { id: '1h', label: '1時間後', until: () => new Date(Date.now() + 3600e3).toISOString() },
  {
    id: 'morning',
    label: '明日の朝',
    until: () => {
      const d = new Date();
      d.setDate(d.getDate() + 1);
      d.setHours(8, 0, 0, 0);
      return d.toISOString();
    },
  },
];

export function readJson(key, fallback) {
  try {
    const raw = localStorage.getItem(key);
    return raw ? JSON.parse(raw) : fallback;
  } catch {
    return fallback;
  }
}

/** Is `now` inside the quiet-hours window (I-402)? Handles midnight wrap. */
export function quietWindowActive(quiet, now = new Date()) {
  const s = String((quiet && quiet.start) || '');
  const e = String((quiet && quiet.end) || '');
  if (!/^\d{1,2}:\d{2}$/.test(s) || !/^\d{1,2}:\d{2}$/.test(e)) return false;
  const [sh, sm] = s.split(':').map(Number);
  const [eh, em] = e.split(':').map(Number);
  const st = sh * 60 + sm;
  const en = eh * 60 + em;
  if (st === en) return false;
  const t = now.getHours() * 60 + now.getMinutes();
  return st < en ? t >= st && t < en : t >= st || t < en;
}

/** I-402: critical cards are never parked by quiet hours. */
export function isParked(task) {
  return quietWindowActive(state.quiet) && task.severity !== 'critical';
}

export const state = {
  hub: localStorage.getItem(LS_HUB) || location.origin,
  token: localStorage.getItem(LS_TOKEN) || '',
  stack: [], // TaskCard[]
  order: localStorage.getItem(LS_ORDER) || 'urgent', // 'urgent'|'newest'|'agent'
  snoozedIds: new Set(readJson(LS_SNOOZED, [])), // local-fallback snoozes
  serverSnoozed: [], // [{taskId, until}] from snapshot — server-side snoozes (I-702)
  queue: readJson(LS_QUEUE, []), // ActionReply[] persisted FIFO
  es: null,
  backoff: BACKOFF_INIT_MS,
  reconnectTimer: null,
  inspectTask: null, // TaskCard currently open in the sheet
  undoable: new Map(), // taskId → task; cards triaged this session (I-104)
  selected: 0, // keyboard selection index into visibleUnits()
  kbActive: false, // true once j/k (or a tap) engaged the focus ring
  fleet: null, // agent name filter (I-603), null = all
  fleetOpen: false,
  paused: readJson(LS_PAUSED, false) === true, // emergency stop (I-403)
  pausedUntil: null,
  history: readJson(LS_HISTORY, []), // processed/audit entries (I-120/I-512)
  quiet: readJson(LS_QUIET, { start: '', end: '' }), // quiet hours (I-402)
  approvalProgress: {}, // taskId → approvals already recorded (multi-approval, I-902)
  deliveryFailed: new Set(), // taskIds whose replyUrl retries were exhausted (I-604)
  rules: [], // auto-approval rules from GET /state (I-602)
  rubberStamp: false, // 連続承認検知 (I-401)
  stampTimes: [], // timestamps of fast high-risk approvals, newest last
  stampArm: null, // taskId armed by a first click (2-click gate, I-401)
  rowSelections: new Map(), // taskId → Map(componentId → Set(rowId)) (row-select)
  edits: new Map(), // taskId → edited value for the `editable` hint (I-114)
};

export function persistQueue() {
  localStorage.setItem(LS_QUEUE, JSON.stringify(state.queue));
}

export function persistSnoozed() {
  localStorage.setItem(LS_SNOOZED, JSON.stringify([...state.snoozedIds]));
}

export function persistHistory() {
  localStorage.setItem(LS_HISTORY, JSON.stringify(state.history));
}

export function persistPaused() {
  localStorage.setItem(LS_PAUSED, JSON.stringify(!!state.paused));
}

export function persistQuiet() {
  localStorage.setItem(LS_QUIET, JSON.stringify(state.quiet));
}

// I-206: client-side priority modes — urgent/newest/agent.
export function persistOrder() {
  localStorage.setItem(LS_ORDER, state.order);
}

// Lazy sortTasks holder — populated once priority.js arrives; before that
// (stale cache, tests without DOM) degrade to arrival order.
let _sortTasks = null;
export function _setSortTasks(fn) { _sortTasks = fn; }

/** Re-sort the stack by the active mode; snoozed ids stay pinned at the tail.
 *  Guarded: a stale cache that misses priority.js must not blank the page. */
export function applyOrder() {
  if (typeof _sortTasks !== 'function') return;
  const non = [];
  const snoozed = [];
  for (const t of state.stack) {
    (state.snoozedIds.has(t.taskId) ? snoozed : non).push(t);
  }
  const now = Date.now();
  state.stack = _sortTasks(non, state.order, now).concat(_sortTasks(snoozed, state.order, now));
}

export const ORDER_LABELS = { urgent: '緊急順', newest: '新しい順', agent: 'エージェント順' };
export const ORDER_CYCLE = ['urgent', 'newest', 'agent'];

export function updateOrderLabel() {
  const labelEl = document.getElementById('order-label');
  if (labelEl) labelEl.textContent = ORDER_LABELS[state.order] || ORDER_LABELS.urgent;
}

/** 並び替えモードを切り替えて永続化し、山札を並べ直す。 */
export function setOrder(mode) {
  state.order = ORDER_LABELS[mode] ? mode : 'urgent';
  persistOrder();
  applyOrder();
  updateOrderLabel();
}
/** Header #order-toggle button — cycle urgent → newest → agent. */
export function wireOrder() {
  updateOrderLabel();
  const btn = document.getElementById('order-toggle');
  if (!btn) return;
  btn.addEventListener('click', () => {
    const i = ORDER_CYCLE.indexOf(state.order);
    const next = ORDER_CYCLE[(i + 1) % ORDER_CYCLE.length];
    setOrder(next);
    import('./render.js').then(({ render }) => render()).catch(() => {});
    import('./dom.js').then(({ toast }) => toast(`並び替え: ${ORDER_LABELS[state.order]}`)).catch(() => {});
  });
}

/** Stack filtered by the Fleet agent lane (I-603) and quiet hours (I-402). */
export function visibleStack() {
  const base = state.fleet
    ? state.stack.filter((t) => ((t.agent && t.agent.name) || 'Agent') === state.fleet)
    : state.stack;
  return base.filter((t) => !isParked(t));
}

/** I-402: how many cards are parked by quiet hours right now. */
export function parkedCount() {
  return state.stack.filter(isParked).length;
}

/**
 * Render units for the stack: individual cards plus groupKey bundles (I-201).
 * A card bundles with its group only when it is not an exception — critical
 * cards and confidence < 0.5 render individually so they keep full attention.
 * Group order follows the first member's position; groups with a single
 * bundleable member degrade back to a plain card.
 */
export function visibleUnits() {
  const vis = visibleStack();
  const isException = (t) =>
    t.severity === 'critical' ||
    (typeof t.confidence === 'number' && t.confidence < 0.5);
  const groups = new Map(); // groupKey → members[]
  const units = [];
  for (const t of vis) {
    const key = typeof t.groupKey === 'string' && t.groupKey ? t.groupKey : null;
    if (key && !isException(t)) {
      if (!groups.has(key)) {
        const members = [];
        groups.set(key, members);
        units.push({ type: 'group', key, members });
      }
      groups.get(key).push(t);
    } else {
      units.push({ type: 'card', task: t });
    }
  }
  const out = [];
  for (const u of units) {
    if (u.type === 'group' && u.members.length < 2) {
      for (const t of u.members) out.push({ type: 'card', task: t });
    } else {
      out.push(u);
    }
  }
  return out;
}

/** The unit under keyboard focus (`state.selected`), clamped. */
export function selectedUnit() {
  const units = visibleUnits();
  if (units.length === 0) return null;
  if (state.selected >= units.length) state.selected = units.length - 1;
  if (state.selected < 0) state.selected = 0;
  return units[state.selected];
}

export function rememberUndoable(task) {
  state.undoable.delete(task.taskId); // refresh recency
  state.undoable.set(task.taskId, task);
  while (state.undoable.size > UNDOABLE_LIMIT) {
    state.undoable.delete(state.undoable.keys().next().value);
  }
}

export function queuedTaskIds() {
  return new Set(state.queue.map((r) => r.taskId));
}

/** Drop a task from the stack and every task-scoped side table. */
export function removeFromStack(taskId) {
  const i = state.stack.findIndex((t) => t.taskId === taskId);
  if (i >= 0) state.stack.splice(i, 1);
  state.snoozedIds.delete(taskId);
  persistSnoozed();
  state.serverSnoozed = state.serverSnoozed.filter((s) => s.taskId !== taskId);
  delete state.approvalProgress[taskId];
  state.deliveryFailed.delete(taskId);
  state.rowSelections.delete(taskId);
  state.edits.delete(taskId);
  if (state.stampArm === taskId) state.stampArm = null;
}