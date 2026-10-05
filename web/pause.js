/* Emergency stop (I-403, client side): optimistic pause state + red banner.
 * The hub endpoint may not exist yet — a 404 is tolerated with a toast. */
import { state, persistPaused } from './store.js';
import { el, clear, toast } from './dom.js';
import { postPause } from './net.js';
import { render } from './render.js';

export function setPaused(paused, { remote = false, until = null } = {}) {
  const next = !!paused;
  const changed = state.paused !== next;
  state.paused = next;
  state.pausedUntil = until || null;
  persistPaused();
  renderPauseBanner();
  render();
  if (remote && changed) {
    toast(next ? 'ハブ: 全エージェントを一時停止しました' : 'ハブ: 一時停止を解除しました');
  }
}

export async function togglePause() {
  const next = !state.paused;
  setPaused(next); // optimistic — the local guard applies even if the hub is down
  try {
    const result = await postPause(next);
    if (result === 'unsupported') {
      toast('ハブ未対応');
    } else {
      toast(next ? '緊急停止しました' : '再開しました');
    }
  } catch {
    toast(next ? '停止要求を送れませんでした（この端末のみ停止中）' : '再開要求を送れませんでした');
  }
}

export function renderPauseBanner() {
  const banner = document.getElementById('pause-banner');
  if (!banner) return;
  clear(banner);
  banner.hidden = !state.paused;
  if (!state.paused) return;
  banner.appendChild(el('span', 'pause-glyph', '■'));
  banner.appendChild(el('span', 'pause-text', '緊急停止中 — 承認は無効です'));
  const resume = el('button', 'btn sm pause-resume', '再開');
  resume.type = 'button';
  resume.addEventListener('click', togglePause);
  banner.appendChild(resume);
}

export function wirePauseControls() {
  for (const id of ['pause-btn', 'settings-pause']) {
    const btn = document.getElementById(id);
    if (btn) btn.addEventListener('click', togglePause);
  }
}
