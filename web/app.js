/* AgentDesk web triage UI — zero-build entry point (native ES modules).
 *
 * NFR-2.1: every payload string reaches the DOM only via textContent /
 * createElement — never innerHTML or eval.
 * FR-2.1/2.2/2.3: optimistic removal, async POST, localStorage offline queue.
 * FR-3.2/3.3: dismissTask removes cards everywhere; 409 → "処理済み" toast.
 *
 * Modules: net (REST + SSE) · store (state/persistence) · actions (triage/undo)
 * · render (components/card/stack) · inspect (sheet) · history (tray/audit)
 * · fleet (agent lanes) · pause (emergency stop) · keyboard · settings
 * · stamp (rubber-stamp guard) · quiet (chips render via render.js).
 */
import { setConnected, toast } from './dom.js';
import { state, quietWindowActive, wireOrder, applyOrder, _setSortTasks } from './store.js';
import { fetchState, connect, applyEnvelope } from './net.js';
import { wireSettings } from './settings.js';
import { wireKeyboard } from './keyboard.js';
import { wireFleet } from './fleet.js';
import { wirePauseControls, renderPauseBanner } from './pause.js';
import { closeHistory, renderTray } from './history.js';
import { closeInspect } from './inspect.js';
import { renderStampBanner } from './stamp.js';
import { render } from './render.js';

// I-206: delayed priority import — styled degrade when the cache is stale.
import('./priority.js').then(({ sortTasks }) => {
  _setSortTasks(sortTasks);
  applyOrder();
  render();
}).catch(() => { /* stale cache — keep arrival order until the next snapshot */ });

export async function bootstrap() {
  if (state.reconnectTimer) {
    clearTimeout(state.reconnectTimer);
    state.reconnectTimer = null;
  }
  setConnected(false);
  // Cold start (NFR-1.2): snapshot before SSE connects.
  if (state.token) {
    try {
      const data = await fetchState();
      applyEnvelope(data);
    } catch {
      // SSE snapshot will reconcile.
    }
  }
  connect();
}

/** PWA shell (I-701): manifest link lives in index.html; the service worker
 * gives offline static shell + push handling. Skipped in preview/drafts. */
function registerServiceWorker() {
  if (!('serviceWorker' in navigator)) return;
  if (/(^|\/)preview\.html$/.test(location.pathname)) return;
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('/sw.js').catch(() => {
      /* best-effort shell caching — the app works without it */
    });
  });
}
/** Chips are informational — a tap explains what they count. */
function wireChips() {
  const snz = document.getElementById('snoozed-chip');
  if (snz) {
    snz.addEventListener('click', () => {
      const items = state.serverSnoozed;
      if (!items.length) return;
      const next = items
        .map((s) => Date.parse(s.until))
        .filter((t) => Number.isFinite(t))
        .sort((a, b) => a - b)[0];
      toast(next
        ? `スヌーズ中 ${items.length}件 — 次は ${new Date(next).toLocaleString('ja-JP', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' })} に再表示`
        : `スヌーズ中 ${items.length}件`);
    });
  }
  const quiet = document.getElementById('quiet-chip');
  if (quiet) {
    quiet.addEventListener('click', () => {
      toast(`おやすみ時間中 (${state.quiet.start}〜${state.quiet.end}) — 重要なカード以外を保留しています`);
    });
  }
}

function start() {
  const backdrop = document.getElementById('sheet-backdrop');
  if (backdrop) backdrop.addEventListener('click', closeInspect);
  const historyBackdrop = document.getElementById('history-backdrop');
  if (historyBackdrop) historyBackdrop.addEventListener('click', closeHistory);

  wireKeyboard();
  wireSettings({ onSave: bootstrap });
  wireFleet();
  wirePauseControls();
  wireOrder();
  renderPauseBanner();
  renderStampBanner();
  renderTray();
  registerServiceWorker();
  wireChips();

  // I-402: parked cards must leave/return the stack at the window edges even
  // when no SSE traffic arrives — poll the boundary once a minute.
  let quietWas = null;
  setInterval(() => {
    const now = quietWindowActive(state.quiet);
    if (quietWas === null) {
      quietWas = now;
      return;
    }
    if (now !== quietWas) {
      quietWas = now;
      render();
    }
  }, 60_000);

  bootstrap();
}

start();
