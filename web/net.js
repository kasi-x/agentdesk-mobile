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
import { recordProcessed, markDeliveryFailed } from './history.js';
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

/** POST one bulk triage batch. Returns {ok,results} | 'bad' (400) | throws. */
export async function postBulk(entries) {
  const res = await fetch(apiUrl('/api/v1/actions/bulk'), {
    method: 'POST',
    headers: authHeaders(),
    body: JSON.stringify({ actions: entries }),
  });
  if (res.ok) return { ok: true, results: (await res.json()).results || [] };
  if (res.status === 400) return { ok: false, results: [], bad: true };
  throw new Error(`bulk ${res.status}`);
}

/** Server-side snooze (I-702) — does not consume the nonce. */
export async function postSnooze(taskId, nonce, until) {
  return postAction({ taskId, nonce, action: 'snooze', until });
}

/** Delegate a card to someone (I-703) — it stays pending. */
export async function postDelegate(taskId, nonce, to) {
  return postAction({ taskId, nonce, action: 'delegate', data: { to }, source: 'web_ui' });
}

/** Ask the agent a question (I-504) — the card stays pending; the
 *  question lands on the card's `asks` trail and reaches replyUrl. */
export async function postAsk(taskId, nonce, question) {
  return postAction({ taskId, nonce, action: 'ask', data: { question }, source: 'web_ui' });
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

/** Emergency stop (I-403): pause with an optional auto-resume `until`. */
export async function postPause(until) {
  const res = await fetch(apiUrl('/api/v1/pause'), {
    method: 'POST',
    headers: authHeaders(),
    body: JSON.stringify(until ? { until } : {}),
  });
  if (res.ok) return 'ok';
  if (res.status === 404) return 'unsupported';
  throw new Error(`pause ${res.status}`);
}

/** Resume after an emergency stop (I-403). */
export async function postResume() {
  const res = await fetch(apiUrl('/api/v1/resume'), {
    method: 'POST',
    headers: authHeaders(),
  });
  if (res.ok) return 'ok';
  if (res.status === 404) return 'unsupported';
  throw new Error(`resume ${res.status}`);
}

/** Publish a device pairing code (I-808). Returns the payload or 'unsupported'. */
export async function postPair(device, user) {
  const res = await fetch(apiUrl('/api/v1/pair'), {
    method: 'POST',
    headers: authHeaders(),
    body: JSON.stringify({ device: device || undefined, user: user || undefined }),
  });
  if (res.status === 404) return 'unsupported';
  if (!res.ok) throw new Error(`pair ${res.status}`);
  return res.json();
}

/** Fetch the VAPID public key for Web Push (I-701) — null when unset. */
export async function fetchVapidKey() {
  try {
    const res = await fetch(apiUrl('/api/v1/push/vapid'), { headers: authHeaders() });
    if (!res.ok) return null;
    const data = await res.json();
    return (data && data.publicKey) || null;
  } catch {
    return null;
  }
}

/** Store a Web Push subscription on the hub. */
export async function postPushSub(sub) {
  const res = await fetch(apiUrl('/api/v1/push/subscribe'), {
    method: 'POST',
    headers: authHeaders(),
    body: JSON.stringify(sub),
  });
  if (res.status !== 201 && !res.ok) throw new Error(`push ${res.status}`);
  return true;
}

/* ---------------- Executive Desk (I-1001/I-1002) ---------------- */

/** Fetch auto-approval rules (I-1002). Returns the rule array, or
 *  'unsupported' when the hub predates GET /api/v1/rules (404) — callers
 *  degrade like `api is HubRulesApi` does on mobile. Throws on network/5xx. */
export async function fetchRules() {
  const res = await fetch(apiUrl('/api/v1/rules'), { headers: authHeaders() });
  if (res.status === 404) return 'unsupported';
  if (!res.ok) throw new Error(`rules ${res.status}`);
  const data = await res.json();
  return Array.isArray(data.rules) ? data.rules : [];
}

/** Replace the whole rule set (I-1002). Returns 'ok' | 'unsupported' | throws. */
export async function saveRules(rules) {
  const res = await fetch(apiUrl('/api/v1/rules'), {
    method: 'PUT',
    headers: authHeaders(),
    body: JSON.stringify({ rules }),
  });
  if (res.ok) return 'ok';
  if (res.status === 404) return 'unsupported';
  throw new Error(`rules ${res.status}`);
}

/** Simulate a rule draft (I-1002). Returns { sampleSize, autoApprove,
 *  autoReject, hitl }, or 'unsupported' when the hub predates the endpoint. */
export async function simulateRule(match, action) {
  const res = await fetch(apiUrl('/api/v1/rules/simulate'), {
    method: 'POST',
    headers: authHeaders(),
    body: JSON.stringify({ match, action }),
  });
  if (res.status === 404) return 'unsupported';
  if (!res.ok) throw new Error(`simulate ${res.status}`);
  return res.json();
}

/** Upload one attachment (I-1001). Returns the hub payload ({ id, url }). */
export async function postAttachment({ kind, contentType, dataBase64 }) {
  const res = await fetch(apiUrl('/api/v1/attachments'), {
    method: 'POST',
    headers: authHeaders(),
    body: JSON.stringify({ kind, contentType, dataBase64 }),
  });
  if (!res.ok) throw new Error(`attachment ${res.status}`);
  return res.json();
}

/* ---------------- SSE ---------------- */

/** Map a dismissTask `by` value to a history source (I-512). */
function dismissSource(by) {
  const b = String(by || '');
  if (b.startsWith('on_expire')) return 'expire';
  if (b === 'withdraw') return 'withdraw';
  if (b === 'snooze') return 'snooze';
  if (b === 'auto_rule') return 'auto';
  return 'auto';
}

function dismissMessage(by) {
  const b = String(by || '');
  if (b.startsWith('on_expire')) return '期限のため自動処理されました';
  if (b === 'withdraw') return 'エージェントがカードを取り下げました';
  if (b === 'snooze') return '他デバイスでスヌーズされました';
  if (b === 'auto_rule') return '自動承認ルールで処理されました';
  return `他デバイスで処理されました (${by || 'unknown'})`;
}

/** FR-3.2: a taskId dismissed anywhere leaves this device too. */
function handleDismiss(data) {
  if (!data || !data.taskId) return;
  const task = state.stack.find((t) => t.taskId === data.taskId);
  if (String(data.by || '') === 'snooze') {
    // A remote snooze lands in the server-side あとで list (I-702).
    if (data.snoozedUntil) {
      const i = state.serverSnoozed.findIndex((s) => s.taskId === data.taskId);
      if (i >= 0) state.serverSnoozed[i] = { taskId: data.taskId, until: data.snoozedUntil };
      else state.serverSnoozed.push({ taskId: data.taskId, until: data.snoozedUntil });
    }
  }
  removeFromStack(data.taskId);
  if (!task) {
    if (String(data.by || '') === 'snooze') render(); // refresh the あとで chip
    return; // e.g. echo of our own optimistic removal
  }
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

/** Apply the full state envelope (snapshot + rules + pause + server snooze). */
export function applyEnvelope(data) {
  applySnapshot(data.tasks || []);
  if (Array.isArray(data.snoozed)) {
    state.serverSnoozed = data.snoozed.filter((s) => s && s.taskId);
  }
  if (data && typeof data === 'object' && data.approvalProgress && typeof data.approvalProgress === 'object') {
    state.approvalProgress = data.approvalProgress;
  }
  if (Array.isArray(data.rules)) state.rules = data.rules;
  if (typeof data.paused === 'boolean') setPaused(data.paused, { until: data.pausedUntil || null });
  flushQueue();
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
      applyEnvelope(JSON.parse(e.data));
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
      state.deliveryFailed.add(data.taskId);
      markDeliveryFailed(data.taskId);
      render();
      toast(`⚠ エージェントに返信できませんでした${data.lastError ? ` (${data.lastError})` : ''}`);
    } catch {
      /* ignore malformed event */
    }
  });
  // Card delegated to someone else (I-703): it stays pending.
  es.addEventListener('delegateTask', (e) => {
    try {
      const data = JSON.parse(e.data);
      if (!data || !data.taskId) return;
      const task = state.stack.find((t) => t.taskId === data.taskId);
      if (task && data.to !== undefined) {
        task.delegatedTo = data.to;
        render();
      }
    } catch {
      /* ignore malformed event */
    }
  });
  // Another approval landed on a multi-approval card (I-902).
  es.addEventListener('approvalProgress', (e) => {
    try {
      const data = JSON.parse(e.data);
      if (!data || !data.taskId) return;
      const count = Number(data.count);
      if (Number.isFinite(count)) {
        state.approvalProgress[data.taskId] = count;
        render();
      }
    } catch {
      /* ignore malformed event */
    }
  });
  // Auto-approval rules changed on the hub (I-602).
  es.addEventListener('ruleChanged', (e) => {
    try {
      const data = JSON.parse(e.data);
      if (!data) return;
      state.rules = Array.isArray(data.rules) ? data.rules : [];
      toast(`自動承認ルールが更新されました (${state.rules.length}件)`);
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
