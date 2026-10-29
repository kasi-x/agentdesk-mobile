/* Tiny DOM helpers — textContent only (NFR-2.1): never innerHTML/eval. */
import { TOAST_MS } from './store.js';

export function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined && text !== null) node.textContent = String(text);
  return node;
}

export function clear(node) {
  node.textContent = '';
}

/** Pill toast in #toasts; `undo` adds a 「元に戻す」 action button (I-104).
 * `actions: [{label, onClick}]` (I-1005) renders extra action buttons —
 * each removes the toast then runs its handler. */
export function toast(message, { undo, duration, actions } = {}) {
  const t = el('div', 'toast', message);
  const act = (label, fn) => {
    const btn = el('button', 'toast-undo', label);
    btn.type = 'button';
    btn.onclick = () => {
      t.remove();
      fn();
    };
    t.appendChild(btn);
  };
  if (Array.isArray(actions)) {
    for (const a of actions) {
      if (a && typeof a.label === 'string' && typeof a.onClick === 'function') {
        act(a.label, a.onClick);
      }
    }
  }
  if (undo) act('元に戻す', undo);
  const host = document.getElementById('toasts');
  if (!host) return;
  host.appendChild(t);
  setTimeout(() => t.remove(), duration || (undo || (actions && actions.length) ? 6000 : TOAST_MS));
}

export function setConnected(on) {
  const dot = document.getElementById('status-dot');
  if (dot) dot.classList.toggle('on', !!on);
}
