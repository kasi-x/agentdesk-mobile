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

function toast(message) {
  const t = el('div', 'toast', message);
  document.getElementById('toasts').appendChild(t);
  setTimeout(() => t.remove(), TOAST_MS);
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

/* ---------------- optimistic triage (FR-2.1/2.2/2.3) ---------------- */

function triage(task, { actionName, data, source }) {
  removeFromStack(task.taskId);
  render();
  const reply = {
    taskId: task.taskId,
    nonce: task.nonce,
    actionName,
    source,
    data: data || {},
  };
  deliver(reply);
}

async function deliver(reply) {
  try {
    const result = await postAction(reply);
    if (result === 'conflict') {
      toast('処理済み — このタスクはすでに別デバイスで処理されています');
    } else if (result === 'not_found') {
      toast('タスクが見つかりません');
    }
  } catch {
    // Offline / 5xx: persist FIFO (FR-2.3); snapshot sync excludes queued ids.
    state.queue.push(reply);
    persistQueue();
    toast('オフライン: 操作をキューに保存しました');
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
      if (state.stack.some((t) => t.taskId === task.taskId)) return;
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
        toast(`他デバイスで処理されました (${data.by || 'unknown'})`);
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
      const addPair = (parent, label, before, after) => {
        const row = el('div', 'diffbox-row');
        if (label) row.appendChild(el('div', 'diffbox-title', label));
        else if (p.title && parent === wrap) row.appendChild(el('div', 'diffbox-title', p.title));
        row.appendChild(el('div', 'diff-before', before || ''));
        row.appendChild(el('div', 'diff-after', `→ ${after || ''}`));
        parent.appendChild(row);
      };
      addPair(wrap, null, p.before, p.after);
      if (Array.isArray(p.rows)) {
        for (const r of p.rows) {
          if (!r || typeof r !== 'object') continue;
          addPair(wrap, r.label || null, r.before, r.after);
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

function renderCard(task) {
  const card = el('div', 'card');
  const inner = el('div', 'card-inner');

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
  const sev = task.severity === 'critical' ? 'critical' : task.severity === 'warning' ? 'warning' : 'info';
  header.appendChild(el('span', `badge ${sev}`, sev));
  inner.appendChild(header);

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

  const approve = el('button', 'btn ok', '✓ Approve');
  approve.type = 'button';
  approve.addEventListener('click', () =>
    triage(task, { actionName: (right && right.actionName) || 'approve', data: right && right.payload, source: 'web_ui' }),
  );

  const reject = el('button', 'btn no', '✕ Reject');
  reject.type = 'button';
  reject.addEventListener('click', () =>
    triage(task, { actionName: (left && left.actionName) || 'reject', data: left && left.payload, source: 'web_ui' }),
  );

  const inspect = el('button', 'btn primary', 'Inspect');
  inspect.type = 'button';
  inspect.addEventListener('click', () => openInspect(task));

  const snz = el('button', 'btn dim', 'Snooze');
  snz.type = 'button';
  snz.addEventListener('click', () => snooze(task));

  actions.append(reject, approve, inspect, snz);
  card.appendChild(actions);
  return card;
}

function render() {
  const stackEl = document.getElementById('stack');
  clear(stackEl);

  const count = document.getElementById('pending-count');
  if (state.stack.length) {
    count.hidden = false;
    count.textContent = `${state.stack.length} pending`;
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
}

function closeInspect() {
  state.inspectTask = null;
  const sheet = document.getElementById('inspect-sheet');
  sheet.hidden = true;
  clear(sheet);
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
        if (p.divisions > 1) input.step = (Number(input.max) - Number(input.min)) / (p.divisions - 1);
        input.value = p.default ?? input.min;
        const val = el('span', 'range-value', input.value);
        input.addEventListener('input', () => { val.textContent = input.value; });
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

wireSettings();
bootstrap();
