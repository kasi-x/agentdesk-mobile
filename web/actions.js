/* Triage actions: optimistic removal, delivery, offline queue, undo, stack. */
import {
  state,
  persistQueue,
  persistSnoozed,
  rememberUndoable,
  removeFromStack,
  queuedTaskIds,
  visibleStack,
} from './store.js';
import { toast } from './dom.js';
import { agentName } from './util.js';
import { postAction, postUndo } from './net.js';
import { render } from './render.js';
import { recordProcessed } from './history.js';

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
  if (i >= 0) {
    state.stack[i] = task;
  } else if (state.snoozedIds.has(task.taskId)) {
    state.stack.push(task);
  } else {
    state.stack.unshift(task);
  }
  render();
}

/** Snooze locally: the card moves to the tail of the stack (client-local). */
export function snooze(task) {
  const i = state.stack.findIndex((t) => t.taskId === task.taskId);
  if (i < 0) return;
  const [t] = state.stack.splice(i, 1);
  state.snoozedIds.add(t.taskId);
  persistSnoozed();
  state.stack.push(t);
  recordProcessed({
    taskId: t.taskId,
    action: 'snooze',
    source: 'snooze',
    agent: agentName(t),
    summary: t.summary || '',
  });
  render();
  toast('スヌーズ — 山札の最後尾へ');
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
  removeFromStack(task.taskId);
  rememberUndoable(task);
  recordProcessed({
    taskId: task.taskId,
    action: actionName,
    source: 'user',
    verdict: verdictOf(task, actionName),
    agent: agentName(task),
    summary: task.summary || '',
  });
  clampSelection();
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
  const n = visibleStack().length;
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
  const n = visibleStack().length;
  if (n === 0) return;
  selectIndex(state.selected + delta);
}

export function selectIndex(i) {
  const n = visibleStack().length;
  if (n === 0) return;
  state.kbActive = true;
  state.selected = Math.max(0, Math.min(n - 1, i));
  render();
}
