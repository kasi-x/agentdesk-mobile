/* Keyboard shortcuts (I-136). Existing ←/→/i/s kept; j/k/z/1-9/?/Shift+→ added.
 * Typing in a form field always wins; the shortcut overlay captures ? and Esc.
 * Wave-2: ↑/↓ choose on choose cards; Enter runs the group's 一括承認. */
import { state, selectedUnit, SNOOZE_OPTIONS } from './store.js';
import { triage, snooze, undoLast, moveSelection, approve, choose, bulkApprove } from './actions.js';
import { openInspect, closeInspect } from './inspect.js';
import { isChooseTask } from './util.js';

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

function rejectTask(task) {
  const left = task.actions && task.actions.onSwipeLeft;
  triage(task, {
    actionName: (left && left.actionName) || 'reject',
    data: left && left.payload,
    source: 'web_ui',
  });
}

/** Shift+→: 二段スワイプ相当 — approve and propose automating the rule (I-101). */
function twoStageApprove(task) {
  approve(task, {
    source: 'web_ui',
    extra: { proposeAutomation: true },
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

  const unit = selectedUnit();
  const top = unit ? (unit.type === 'group' ? null : unit.task) : null;
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
      if (unit) openInspect(unit.type === 'group' ? unit.members[0] : unit.task);
      break;
    case 's':
      if (!unit) break;
      if (unit.type === 'group') {
        for (const t of unit.members) snooze(t, SNOOZE_OPTIONS[0].until());
      } else if (top) {
        snooze(top, SNOOZE_OPTIONS[0].until());
      }
      break;
    case 'ArrowUp':
      if (top && isChooseTask(top) && !state.paused) {
        e.preventDefault();
        choose(top, 0);
      }
      break;
    case 'ArrowDown':
      if (top && isChooseTask(top) && !state.paused) {
        e.preventDefault();
        choose(top, 1);
      }
      break;
    case 'ArrowRight':
      if (!unit || state.paused) break; // approvals are disabled while paused (I-403)
      e.preventDefault();
      if (unit.type === 'group') {
        bulkApprove(unit.members); // Enter-side action for a bundle
      } else if (isChooseTask(top)) {
        break; // choose cards use ↑/↓ — → is disabled
      } else if (e.shiftKey) {
        twoStageApprove(top);
      } else {
        approve(top, { source: 'web_ui' });
      }
      break;
    case 'ArrowLeft':
      if (!top) break;
      e.preventDefault();
      if (isChooseTask(top)) rejectTask(top); // ← still rejects, reasons included
      else if (unit.type === 'card') rejectTask(top);
      break;
  }
}

export function wireKeyboard() {
  document.addEventListener('keydown', onKeyDown);
}
