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

/** Pill toast in #toasts; `undo` adds a 「元に戻す」 action button (I-104). */
export function toast(message, { undo, duration } = {}) {
  const t = el('div', 'toast', message);
  if (undo) {
    const btn = el('button', 'toast-undo', '元に戻す');
    btn.type = 'button';
    btn.onclick = () => {
      t.remove();
      undo();
    };
    t.appendChild(btn);
  }
  const host = document.getElementById('toasts');
  if (!host) return;
  host.appendChild(t);
  setTimeout(() => t.remove(), duration || (undo ? 5000 : TOAST_MS));
}

export function setConnected(on) {
  const dot = document.getElementById('status-dot');
  if (dot) dot.classList.toggle('on', !!on);
}
