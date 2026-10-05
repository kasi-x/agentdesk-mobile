/* Keyboard shortcuts (I-136). Existing ←/→/i/s kept; j/k/z/1-9/?/Shift+→ added.
 * Typing in a form field always wins; the shortcut overlay captures ? and Esc. */
import { state, visibleStack } from './store.js';
import { triage, snooze, undoLast, moveSelection } from './actions.js';
import { openInspect, closeInspect } from './inspect.js';

function isTyping(e) {
  return e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement;
}

function overlay() {
  return document.getElementById('kbd-overlay');
}

function overlayOpen() {
  const o = overlay();
  return !!(o && !o.hidden);
}

function toggleOverlay(force) {
  const o = overlay();
  if (!o) return;
  o.hidden = force === undefined ? !o.hidden : !force;
}

/** Click the n-th (1-based) button matching `selector`; false when absent. */
function clickNth(selector, n) {
  const node = document.querySelectorAll(selector)[n - 1];
  if (!node) return false;
  node.click();
  return true;
}

function approve(task) {
  const right = task.actions && task.actions.onSwipeRight;
  triage(task, {
    actionName: (right && right.actionName) || 'approve',
    data: right && right.payload,
    source: 'web_ui',
  });
}

/** Shift+→: 二段スワイプ相当 — approve and propose automating the rule (I-101). */
function twoStageApprove(task) {
  const right = task.actions && task.actions.onSwipeRight;
  const data = Object.assign({}, (right && right.payload) || {}, { proposeAutomation: true });
  triage(task, {
    actionName: (right && right.actionName) || 'approve',
    data,
    source: 'web_ui',
  });
}

function reject(task) {
  const left = task.actions && task.actions.onSwipeLeft;
  triage(task, {
    actionName: (left && left.actionName) || 'reject',
    data: left && left.payload,
    source: 'web_ui',
  });
}

function onKeyDown(e) {
  if (isTyping(e)) return;
  if (e.metaKey || e.ctrlKey || e.altKey) return; // leave browser shortcuts alone

  if (e.key === '?') {
    e.preventDefault();
    toggleOverlay();
    return;
  }
  if (overlayOpen()) {
    if (e.key === 'Escape') {
      e.preventDefault();
      toggleOverlay(false);
    }
    return;
  }

  // Inspect sheet: Esc closes; 1-9 pick a quick-option chip.
  if (state.inspectTask) {
    if (e.key === 'Escape') {
      closeInspect();
      return;
    }
    if (/^[1-9]$/.test(e.key)) clickNth('#inspect-sheet .chip', Number(e.key));
    return;
  }

  // Reject-reason chips: 1-9 picks one while the row is expanded.
  if (/^[1-9]$/.test(e.key)) {
    if (clickNth('.reason-chips .chip', Number(e.key))) return;
  }

  const vis = visibleStack();
  const top = vis[state.selected] || vis[0];
  switch (e.key) {
    case 'j':
      e.preventDefault();
      moveSelection(1);
      break;
    case 'k':
      e.preventDefault();
      moveSelection(-1);
      break;
    case 'z':
      e.preventDefault();
      undoLast();
      break;
    case 'i':
      if (top) openInspect(top);
      break;
    case 's':
      if (top) snooze(top);
      break;
    case 'ArrowRight':
      if (!top || state.paused) break; // approvals are disabled while paused (I-403)
      e.preventDefault();
      if (e.shiftKey) twoStageApprove(top);
      else approve(top);
      break;
    case 'ArrowLeft':
      if (!top) break;
      e.preventDefault();
      reject(top);
      break;
  }
}

export function wireKeyboard() {
  document.addEventListener('keydown', onKeyDown);
}
