/* Triage actions: optimistic removal, delivery, offline queue, undo, stack. */
import {
  state,
  persistQueue,
  persistSnoozed,
  rememberUndoable,
  removeFromStack,
  queuedTaskIds,
  visibleUnits,
  SNOOZE_OPTIONS,
} from './store.js';
import { toast } from './dom.js';
import { agentName, riskLevel, choiceId, parseEditNumber, parseEditDateTime } from './util.js';
import { postAction, postUndo, postBulk, postSnooze, postDelegate } from './net.js';
import { render } from './render.js';
import { recordProcessed } from './history.js';
import { renderStampBanner, passGate } from './stamp.js';

/** Rebuild stack from a server snapshot (the hub's order: priority desc). */
export function applySnapshot(tasks) {
  const queued = queuedTaskIds();
  const pending = (tasks || []).filter(
    (t) => t && t.taskId && !queued.has(t.taskId),
  );
  // Wire contract: snapshot carries `priority` and is ordered priority desc
  // (createdAt asc tiebreak). Older hubs sent oldest→newest; keep that
  // newest-first fallback when no card exposes a priority.
  const ordered = pending.slice();
  if (pending.some((t) => typeof t.priority === 'number')) {
    ordered.sort((a, b) => (b.priority || 0) - (a.priority || 0) ||
      (Date.parse(a.createdAt || 0) - Date.parse(b.createdAt || 0)));
  } else {
    ordered.reverse();
  }
  // Locally snoozed ids move to the tail.
  const fresh = [];
  const snoozed = [];
  for (const t of ordered) {
    (state.snoozedIds.has(t.taskId) ? snoozed : fresh).push(t);
  }
  state.stack = fresh.concat(snoozed);
  clampSelection();
  render();
}

/** Insert or replace a card pushed over SSE (nonce rotation = replace). */
export function upsertTaskCard(task) {
  const i = state.stack.findIndex((t) => t.taskId === task.taskId);
  // A snoozed card resurfacing (I-702) is fresh — it goes to the head.
  if (state.serverSnoozed.some((s) => s.taskId === task.taskId)) {
    state.serverSnoozed = state.serverSnoozed.filter((s) => s.taskId !== task.taskId);
  }
  if (i >= 0) {
    state.stack[i] = task;
  } else if (state.snoozedIds.has(task.taskId)) {
    state.stack.push(task);
  } else {
    state.stack.unshift(task);
  }
  render();
}

/**
 * Server-side snooze (I-702): the hub hides the card until `until`,
 * keeping the same nonce. On a network failure (offline) we fall back to
 * the old local move-to-tail so nothing is lost.
 */
export async function snooze(task, until) {
  const due = until || SNOOZE_OPTIONS[0].until();
  removeFromStack(task.taskId);
  recordProcessed({
    taskId: task.taskId,
    action: 'snooze',
    source: 'snooze',
    agent: agentName(task),
    summary: task.summary || '',
  });
  clampSelection();
  render();
  try {
    const result = await postSnooze(task.taskId, task.nonce, due);
    if (result === 'ok') {
      // The dismissTask echo reconciles this; record it now so the あとで
      // chip is correct even if the echo is missed on a flaky link.
      state.serverSnoozed.push({ taskId: task.taskId, until: due });
      render();
      toast('後で (サーバーに保存)');
    } else if (result === 'conflict') {
      toast('処理済み — スヌーズできませんでした');
    } else if (result === 'not_found') {
      toast('タスクが見つかりません');
    }
  } catch {
    // Offline / 5xx: local fallback (FR-2.3) — tail of the stack.
    const i = state.stack.findIndex((t) => t.taskId === task.taskId);
    if (i < 0) {
      state.snoozedIds.add(task.taskId);
      persistSnoozed();
      state.stack.push(task);
    }
    toast('オフライン: この端末だけでスヌーズしました');
    render();
  }
}

/**
 * Build the approve `data` for a card: the swipe binding payload underneath,
 * plus collected extras. Reply `data` passthrough (wire contract):
 * - row-select → `acceptedRows` (omitted when every row stays selected)
 * - editable → `edited: {componentId, value}`
 * - `extra` (choose → `choice`, two-stage → `proposeAutomation`, …)
 */
export function approvalData(task, extra) {
  const right = task.actions && task.actions.onSwipeRight;
  const data = Object.assign({}, (right && right.payload) || {}, extra || {});
  const rows = acceptedRows(task);
  if (rows) data.acceptedRows = rows;
  if (task.editable && typeof task.editable.componentId !== 'undefined') {
    const v = editedValue(task);
    if (v !== undefined) data.edited = { componentId: task.editable.componentId, value: v };
  }
  return data;
}

/** Approve one card with its collected extras (Shift+→ adds automation).
 * Returns false when the rubber-stamp gate armed instead of sending. */
export function approve(task, { source = 'web_ui', extra = null } = {}) {
  if (!passGate(task)) {
    toast('もう一度で承認 (連続承認検知中)');
    return false;
  }
  const right = task.actions && task.actions.onSwipeRight;
  triage(task, {
    actionName: (right && right.actionName) || 'approve',
    data: approvalData(task, extra),
    source,
  });
  return true;
}

/** Choose one of a choose card's options (ArrowUp/ArrowDown). */
export function choose(task, index) {
  const choices = Array.isArray(task.choices) ? task.choices : [];
  const choice = choices[index];
  if (!choice) return false;
  if (!passGate(task)) {
    toast('もう一度で選択 (連続承認検知中)');
    return false;
  }
  const binds = task.actions || {};
  const bind = index === 0 ? binds.onSwipeUp : binds.onSwipeDown;
  const data = approvalData(task, { choice: choiceId(choice, index) });
  triage(task, {
    actionName: (bind && bind.actionName) || (index === 0 ? 'choose_a' : 'choose_b'),
    data,
    source: 'web_ui',
  });
  return true;
}

/**
 * One-click approve for a multi-member bundle (I-201): every member is CASed
 * independently via /actions/bulk, optimistic like single triage. Exceptions
 * never reach a bundle — the hub may still return per-item errors.
 */
export async function bulkApprove(members) {
  const targets = members.filter((t) => t && t.taskId);
  if (targets.length === 0) return;
  for (const t of targets) {
    removeFromStack(t.taskId);
    rememberUndoable(t);
    recordProcessed({
      taskId: t.taskId,
      action: approveName(t),
      source: 'bulk',
      verdict: 'approve',
      agent: agentName(t),
      summary: t.summary || '',
    });
  }
  clampSelection();
  render();
  const entries = targets.map((t) => ({
    taskId: t.taskId,
    nonce: t.nonce,
    action: approveName(t),
    source: 'bulk',
    data: approvalData(t),
  }));
  try {
    const res = await postBulk(entries);
    const results = (res && res.results) || [];
    const failures = results.filter((r) => r && !r.ok);
    if (failures.length === 0) {
      toast(`${targets.length}件まとめて承認しました`);
    } else {
      toast(`一括承認: ${targets.length - failures.length}/${targets.length}件 (失敗 ${failures.length})`);
    }
  } catch {
    // Offline: queue each reply like singles (FR-2.3).
    for (const e of entries) {
      state.queue.push({ taskId: e.taskId, nonce: e.nonce, actionName: e.action, source: e.source, data: e.data });
    }
    persistQueue();
    toast('オフライン: 一括操作をキューに保存しました');
    render();
  }
}

function approveName(task) {
  const right = task.actions && task.actions.onSwipeRight;
  return (right && right.actionName) || 'approve';
}

/**
 * Delegate a card (I-703): the card stays pending — the hub only tags it
 * `delegatedTo` and broadcasts delegateTask. Optimistic badge locally.
 */
export async function delegate(task, to) {
  if (!to) return;
  task.delegatedTo = to;
  recordProcessed({
    taskId: task.taskId,
    action: 'delegate',
    source: 'delegate',
    agent: agentName(task),
    summary: task.summary || '',
  });
  render();
  try {
    const result = await postDelegate(task.taskId, task.nonce, to);
    if (result === 'ok') {
      toast(`「${to}」へ回しました`);
    } else {
      task.delegatedTo = null;
      render();
      toast(result === 'not_found' ? 'タスクが見つかりません' : '処理済み — 回せませんでした');
    }
  } catch {
    toast('オフライン: 回送できませんでした（表示だけ更新）');
  }
}

/* ---------------- row-select (DiffBox selectable) ---------------- */

/** Row ids of a selectable DiffBox (explicit id, else its index). */
function selectableRows(comp) {
  const rows = comp && comp.properties && Array.isArray(comp.properties.rows)
    ? comp.properties.rows.filter((r) => r && typeof r === 'object')
    : [];
  return rows.map((r, i) => (r.id !== undefined && r.id !== null ? String(r.id) : String(i)));
}

/** Selection set for a component; first read defaults to all-selected. */
export function rowSelection(taskId, componentId, ids) {
  let perTask = state.rowSelections.get(taskId);
  if (!perTask) {
    perTask = new Map();
    state.rowSelections.set(taskId, perTask);
  }
  let set = perTask.get(componentId);
  if (!set) {
    set = new Set(ids);
    perTask.set(componentId, set);
  }
  return set;
}

/** Flip one row; false when nothing changed. */
export function toggleRow(taskId, componentId, rowId, ids) {
  const set = rowSelection(taskId, componentId, ids);
  if (set.has(rowId)) set.delete(rowId);
  else set.add(rowId);
  return true;
}

/**
 * `acceptedRows` for an approve payload — undefined when every row is
 * still selected ("omit when all"), else the remaining ids.
 */
export function acceptedRows(task) {
  const list = Array.isArray(task.components) ? task.components : [];
  const comps = list.filter(
    (c) => c && c.component === 'DiffBox' && c.properties && c.properties.selectable,
  );
  if (comps.length === 0) return undefined;
  let total = 0;
  const chosen = [];
  for (const c of comps) {
    const ids = selectableRows(c);
    total += ids.length;
    const set = state.rowSelections.get(task.taskId)?.get(c.id);
    const sel = set ? ids.filter((id) => set.has(id)) : ids;
    chosen.push(...sel);
  }
  if (total === 0 || chosen.length === total) return undefined;
  return chosen;
}

/* ---------------- editable (value adjust, I-114) ---------------- */

/** Seed for the inline stepper: the component's `after`/`default`, else 0/now. */
export function editSeed(task) {
  const e = task.editable || {};
  const comp = (Array.isArray(task.components) ? task.components : [])
    .find((c) => c && c.id === e.componentId);
  const p = (comp && comp.properties) || {};
  if (e.kind === 'datetime') {
    return parseEditDateTime(p.after ?? p.default) || new Date().toISOString();
  }
  const n = parseEditNumber(p.after ?? p.default);
  return Number.isFinite(n) ? n : 0;
}

/** Current inline-edit value for the card (seeds and stores on first read). */
export function editedValue(task, write) {
  if (write !== undefined) {
    state.edits.set(task.taskId, write);
    return write;
  }
  if (state.edits.has(task.taskId)) return state.edits.get(task.taskId);
  const v = editSeed(task);
  state.edits.set(task.taskId, v);
  return v;
}

/* ---------------- optimistic triage (FR-2.1/2.2/2.3) ---------------- */

/** Which swipe binding (if any) an actionName maps to, for the history icon. */
function verdictOf(task, actionName) {
  const right = task.actions && task.actions.onSwipeRight;
  const left = task.actions && task.actions.onSwipeLeft;
  if (left && actionName === left.actionName) return 'reject';
  if (right && actionName === right.actionName) return 'approve';
  if (actionName === 'reject' || actionName === 'deny') return 'reject';
  if (actionName === 'approve') return 'approve';
  return 'other';
}

export function triage(task, { actionName, data, source }) {
  const risk = riskLevel(task);
  removeFromStack(task.taskId);
  rememberUndoable(task);
  recordProcessed({
    taskId: task.taskId,
    action: actionName,
    source: 'user',
    verdict: verdictOf(task, actionName),
    agent: agentName(task),
  });
  // Rubber-stamp watch (I-401): the guard is one-shot — any careful
  // high-risk triage (gated 2-click, hold, deliberate reject) consumes it
  // and restarts the watch; fast approvals otherwise feed it.
  if (state.rubberStamp && risk !== 'normal') {
    state.rubberStamp = false;
    state.stampArm = null;
    state.stampTimes = [];
    renderStampBanner();
  } else if (actionName === 'approve' && (risk === 'high' || risk === 'locked')) {
    recordStamp();
  }
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

/** I-401: ≥3 sub-1s approvals of high/locked cards trips the rubber stamp. */
function recordStamp() {
  const now = Date.now();
  state.stampTimes.push(now);
  while (state.stampTimes.length > 3) state.stampTimes.shift();
  if (state.stampTimes.length === 3) {
    const [a, b, c] = state.stampTimes;
    if (c - b < 1000 && b - a < 1000 && !state.rubberStamp) {
      state.rubberStamp = true;
      render();
      toast('連続承認検知 — 高リスクの承認は2回タップになります');
    }
  }
}

export async function deliver(reply, task) {
  try {
    const result = await postAction(reply);
    if (result === 'ok') {
      toast(`${reply.actionName} しました`, { undo: () => undo(task.taskId) });
    } else if (result === 'conflict') {
      toast('処理済み — このタスクはすでに別デバイスで処理されています');
    } else if (result === 'not_found') {
      toast('タスクが見つかりません');
    }
  } catch {
    // Offline / 5xx: persist FIFO (FR-2.3); snapshot sync excludes queued ids.
    state.queue.push(reply);
    persistQueue();
    toast('オフライン: 操作をキューに保存しました', { undo: () => undo(task.taskId) });
    render();
  }
}

export async function flushQueue() {
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

/**
 * Revert a triage decision (I-104). Offline-queued decisions are dropped
 * locally; sent ones ask the hub, which re-broadcasts the card via
 * createTaskCard (next snapshot restores it regardless).
 */
export async function undo(taskId) {
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

/** `z`: undo the most recent decision made on this device (I-136). */
export function undoLast() {
  const ids = [...state.undoable.keys()];
  const id = ids[ids.length - 1];
  if (!id) {
    toast('元に戻せる操作がありません');
    return;
  }
  undo(id);
}

/* ---------------- keyboard selection (I-136) ---------------- */

export function clampSelection() {
  const n = visibleUnits().length;
  if (n === 0) {
    state.selected = 0;
  } else if (state.selected >= n) {
    state.selected = n - 1;
  } else if (state.selected < 0) {
    state.selected = 0;
  }
}

/** Move the visual focus ring through the stack (`j`/`k`). */
export function moveSelection(delta) {
  const n = visibleUnits().length;
  if (n === 0) return;
  selectIndex(state.selected + delta);
}

export function selectIndex(i) {
  const n = visibleUnits().length;
  if (n === 0) return;
  state.kbActive = true;
  state.selected = Math.max(0, Math.min(n - 1, i));
  render();
}
