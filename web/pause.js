/* Emergency stop (I-403, client side): optimistic pause state + red banner.
 * POST /api/v1/pause {until} pauses (+8h auto-resume) and POST /resume
 * resumes; a 404 means the hub predates these endpoints and only the local
 * guard applies. */
import { state, persistPaused } from './store.js';
import { el, clear, toast } from './dom.js';
import { postPause, postResume } from './net.js';
import { render } from './render.js';

/** The default pause duration: the hub auto-resumes after 8h. */
export function pauseUntilDefault() {
  return new Date(Date.now() + 8 * 3600e3).toISOString();
}

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
  if (state.paused) {
    setPaused(false); // optimistic — the local guard lifts even if the hub is down
    try {
      const result = await postResume();
      if (result === 'unsupported') toast('ハブ未対応（この端末のみ再開）');
      else toast('再開しました');
    } catch {
      toast('再開要求を送れませんでした（この端末のみ再開中）');
    }
    return;
  }
  const until = pauseUntilDefault();
  setPaused(true, { until }); // optimistic
  try {
    const result = await postPause(until);
    if (result === 'unsupported') toast('ハブ未対応（この端末のみ停止中）');
    else toast('緊急停止しました');
  } catch {
    toast('停止要求を送れませんでした（この端末のみ停止中）');
  }
}

export function renderPauseBanner() {
  const banner = document.getElementById('pause-banner');
  if (!banner) return;
  clear(banner);
  banner.hidden = !state.paused;
  if (!state.paused) return;
  banner.appendChild(el('span', 'pause-glyph', '■'));
  const text = state.pausedUntil
    ? `緊急停止中 — 承認は無効です (${new Date(state.pausedUntil).toLocaleString('ja-JP', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' })}まで)`
    : '緊急停止中 — 承認は無効です';
  banner.appendChild(el('span', 'pause-text', text));
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
