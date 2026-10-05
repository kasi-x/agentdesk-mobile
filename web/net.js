/* Transport: hub REST calls + the SSE stream (reconnect + snapshot resync). */
import {
  state,
  BACKOFF_INIT_MS,
  BACKOFF_MAX_MS,
  removeFromStack,
} from './store.js';
import { setConnected, toast } from './dom.js';
import { agentName } from './util.js';
import { flushQueue, applySnapshot, upsertTaskCard } from './actions.js';
import { recordProcessed } from './history.js';
import { setPaused } from './pause.js';
import { render } from './render.js';

export function apiUrl(path) {
  return `${state.hub.replace(/\/$/, '')}${path}`;
}

export function authHeaders() {
  return { Authorization: `Bearer ${state.token}`, 'Content-Type': 'application/json' };
}

export async function fetchState() {
  const res = await fetch(apiUrl('/api/v1/state'), { headers: authHeaders() });
  if (!res.ok) throw new Error(`state ${res.status}`);
  return res.json();
}

/** POST an action reply. Returns 'ok' | 'conflict' | 'not_found' | throws on network/5xx. */
export async function postAction(reply) {
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
export async function postUndo(taskId, nonce) {
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

/** Emergency stop (I-403). Returns 'ok' | 'unsupported' (404) | throws. */
export async function postPause(paused) {
  const res = await fetch(apiUrl('/api/v1/pause'), {
    method: 'POST',
    headers: authHeaders(),
    body: JSON.stringify({ paused: !!paused }),
  });
  if (res.ok) return 'ok';
  if (res.status === 404) return 'unsupported';
  throw new Error(`pause ${res.status}`);
}

/* ---------------- SSE ---------------- */

/** Map a dismissTask `by` value to a history source (I-512). */
function dismissSource(by) {
  const b = String(by || '');
  if (b.startsWith('on_expire')) return 'expire';
  if (b === 'withdraw') return 'withdraw';
  if (b === 'snooze') return 'snooze';
  return 'auto';
}

function dismissMessage(by) {
  const b = String(by || '');
  if (b.startsWith('on_expire')) return '期限のため自動処理されました';
  if (b === 'withdraw') return 'エージェントがカードを取り下げました';
  if (b === 'snooze') return '他デバイスでスヌーズされました';
  return `他デバイスで処理されました (${by || 'unknown'})`;
}

/** FR-3.2: a taskId dismissed anywhere leaves this device too. */
function handleDismiss(data) {
  if (!data || !data.taskId) return;
  const task = state.stack.find((t) => t.taskId === data.taskId);
  removeFromStack(data.taskId);
  if (!task) return; // e.g. echo of our own optimistic removal
  recordProcessed({
    taskId: data.taskId,
    action: String(data.by || 'dismiss'),
    source: dismissSource(data.by),
    agent: agentName(task),
    summary: task.summary || '',
  });
  render();
  toast(dismissMessage(data.by));
}

export function connect() {
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
      upsertTaskCard(task);
    } catch {
      /* ignore malformed event */
    }
  });
  es.addEventListener('dismissTask', (e) => {
    try {
      handleDismiss(JSON.parse(e.data));
    } catch {
      /* ignore malformed event */
    }
  });
  // Agent-side withdrawal (I-205): the card is gone for good.
  es.addEventListener('withdrawTask', (e) => {
    try {
      const data = JSON.parse(e.data);
      handleDismiss(Object.assign({}, data, { by: 'withdraw' }));
    } catch {
      /* ignore malformed event */
    }
  });
  // Hub-wide emergency stop (I-403).
  es.addEventListener('pauseState', (e) => {
    try {
      const data = JSON.parse(e.data);
      if (!data || typeof data.paused !== 'boolean') return;
      setPaused(data.paused, { remote: true, until: data.until || null });
    } catch {
      /* ignore malformed event */
    }
  });
  // Reply delivery gave up (I-604): the agent never saw this decision.
  es.addEventListener('deliveryFailed', (e) => {
    try {
      const data = JSON.parse(e.data);
      if (!data || !data.taskId) return;
      toast(`エージェントに返信できませんでした${data.lastError ? ` (${data.lastError})` : ''}`);
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

export function scheduleReconnect() {
  if (state.reconnectTimer) return;
  const delay = state.backoff;
  state.backoff = Math.min(state.backoff * 2, BACKOFF_MAX_MS);
  state.reconnectTimer = setTimeout(() => {
    state.reconnectTimer = null;
    connect();
  }, delay);
}
