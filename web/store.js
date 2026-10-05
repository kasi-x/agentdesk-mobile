/* Application state + localStorage persistence.
 * Leaf module: imports nothing, so every other module may depend on it. */

export const LS_HUB = 'agentdesk.hub';
export const LS_TOKEN = 'agentdesk.token';
export const LS_QUEUE = 'agentdesk.offlineQueue';
export const LS_SNOOZED = 'agentdesk.snoozedIds';
export const LS_HISTORY = 'agentdesk.history';
export const LS_PAUSED = 'agentdesk.paused';

export const BACKOFF_INIT_MS = 1000;
export const BACKOFF_MAX_MS = 30_000;
export const TOAST_MS = 3000;
export const UNDOABLE_LIMIT = 30;
export const HISTORY_LIMIT = 200;

export function readJson(key, fallback) {
  try {
    const raw = localStorage.getItem(key);
    return raw ? JSON.parse(raw) : fallback;
  } catch {
    return fallback;
  }
}

/** Newest-first pending stack; snoozed tasks sit at the tail. */
export const state = {
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
  selected: 0, // keyboard selection index into visibleStack()
  kbActive: false, // true once j/k (or a tap) engaged the focus ring
  fleet: null, // agent name filter (I-603), null = all
  fleetOpen: false,
  paused: readJson(LS_PAUSED, false) === true, // emergency stop (I-403)
  pausedUntil: null,
  history: readJson(LS_HISTORY, []), // processed/audit entries (I-120/I-512)
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

/** Stack filtered by the Fleet agent lane (I-603) — [] when nothing matches. */
export function visibleStack() {
  if (!state.fleet) return state.stack;
  return state.stack.filter(
    (t) => ((t.agent && t.agent.name) || 'Agent') === state.fleet,
  );
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

export function removeFromStack(taskId) {
  const i = state.stack.findIndex((t) => t.taskId === taskId);
  if (i >= 0) state.stack.splice(i, 1);
  state.snoozedIds.delete(taskId);
  persistSnoozed();
}
