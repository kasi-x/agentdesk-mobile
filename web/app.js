/* AgentDesk web triage UI — zero-build entry point (native ES modules).
 *
 * NFR-2.1: every payload string reaches the DOM only via textContent /
 * createElement — never innerHTML or eval.
 * FR-2.1/2.2/2.3: optimistic removal, async POST, localStorage offline queue.
 * FR-3.2/3.3: dismissTask removes cards everywhere; 409 → "処理済み" toast.
 *
 * Modules: net (REST + SSE) · store (state/persistence) · actions (triage/undo)
 * · render (components/card/stack) · inspect (sheet) · history (tray/audit)
 * · fleet (agent lanes) · pause (emergency stop) · keyboard · settings.
 */
import { setConnected } from './dom.js';
import { state } from './store.js';
import { fetchState, connect } from './net.js';
import { applySnapshot, flushQueue } from './actions.js';
import { wireSettings } from './settings.js';
import { wireKeyboard } from './keyboard.js';
import { wireFleet } from './fleet.js';
import { wirePauseControls, renderPauseBanner } from './pause.js';
import { closeHistory, renderTray } from './history.js';
import { closeInspect } from './inspect.js';

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
      applySnapshot(data.tasks || []);
      flushQueue();
    } catch {
      // SSE snapshot will reconcile.
    }
  }
  connect();
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
  renderPauseBanner();
  renderTray();

  bootstrap();
}

start();
