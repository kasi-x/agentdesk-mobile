/* Rubber-stamp guard (I-401): after ≥3 sub-1s approvals of high/locked
 * cards, high-risk approvals need a two-click confirm (armed state).
 * The banner is one-shot-dismissable; the gate is consumed by the next
 * high-risk triage. Arm/disarm state lives in store.js. */
import { state } from './store.js';
import { riskLevel } from './util.js';
import { el, clear } from './dom.js';

/** True when this card's approve needs two clicks (I-401). */
export function isGated(task) {
  return state.rubberStamp && riskLevel(task) === 'high';
}

/**
 * Shared two-click gate for button + keyboard approvals. True = proceed
 * (first click arms and returns false instead). Never renders — the caller
 * owns its own armed affordance (button label / toast).
 */
export function passGate(task) {
  if (!isGated(task)) return true;
  if (state.stampArm === task.taskId) {
    state.stampArm = null;
    return true;
  }
  state.stampArm = task.taskId;
  return false;
}

export function dismissStamp() {
  state.rubberStamp = false;
  state.stampArm = null;
  state.stampTimes = [];
  renderStampBanner();
}

export function renderStampBanner() {
  const banner = document.getElementById('stamp-banner');
  if (!banner) return;
  clear(banner);
  banner.hidden = !state.rubberStamp;
  if (!state.rubberStamp) return;
  banner.appendChild(el('span', 'stamp-glyph', '⚠'));
  banner.appendChild(el('span', 'stamp-text', '連続承認検知 — 高リスクの承認は2回タップになります'));
  const close = el('button', 'btn sm stamp-close', '閉じる');
  close.type = 'button';
  close.addEventListener('click', dismissStamp);
  banner.appendChild(close);
}
