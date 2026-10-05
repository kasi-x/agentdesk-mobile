/* Settings panel: hub URL + client token, quiet hours (I-402),
 * device pairing with a QR code (I-808) and Web Push subscribe (I-701). */
import { state, LS_HUB, LS_TOKEN, persistQuiet } from './store.js';
import { el, clear, toast } from './dom.js';
import { postPair, fetchVapidKey, postPushSub } from './net.js';
import { renderQr } from './qr.js';

/* ---------------- quiet hours (I-402) ---------------- */

function wireQuiet() {
  const start = document.getElementById('quiet-start');
  const end = document.getElementById('quiet-end');
  if (!start || !end) return;
  start.value = state.quiet.start || '';
  end.value = state.quiet.end || '';
  const save = () => {
    state.quiet = { start: start.value || '', end: end.value || '' };
    persistQuiet();
  };
  start.addEventListener('change', save);
  end.addEventListener('change', save);
}

/* ---------------- device pairing (I-808) ---------------- */

function pairingUrl(payload) {
  if (payload && payload.url) return payload.url;
  const code = (payload && payload.code) || '';
  return `${state.hub.replace(/\/$/, '')}/pair?code=${encodeURIComponent(code)}`;
}

function renderPairResult(host, payload) {
  clear(host);
  if (!payload || !payload.code) {
    host.appendChild(el('div', 'pair-error', 'コードを発行できませんでした'));
    return;
  }
  const url = pairingUrl(payload);
  host.appendChild(el('div', 'pair-code', payload.code));
  const urlRow = el('div', 'pair-url');
  urlRow.appendChild(el('span', '', url));
  const copy = el('button', 'btn sm', 'コピー');
  copy.type = 'button';
  copy.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(url);
      toast('ペアリングURLをコピーしました');
    } catch {
      toast('コピーできませんでした（手動で選択してください）');
    }
  });
  urlRow.appendChild(copy);
  host.appendChild(urlRow);
  // QR canvas — local encoder (qr.js), never a network fetch.
  try {
    const canvas = el('canvas', 'pair-qr');
    renderQr(canvas, url, { margin: 2, scale: 4 });
    host.appendChild(canvas);
  } catch {
    host.appendChild(el('div', 'pair-error', 'QRを生成できませんでした（URLを手動で入力してください）'));
  }
  if (payload.expiresAt) {
    const at = new Date(payload.expiresAt);
    host.appendChild(el('div', 'pair-exp',
      Number.isNaN(at.getTime()) ? '' : `有効期限: ${at.toLocaleString('ja-JP', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' })}`));
  }
}

function wirePairing() {
  const btn = document.getElementById('pair-btn');
  const host = document.getElementById('pair-result');
  if (!btn || !host) return;
  btn.addEventListener('click', async () => {
    btn.disabled = true;
    try {
      const payload = await postPair('web', '');
      if (payload === 'unsupported') {
        toast('ハブ未対応 — ペアリングは使えません');
      } else {
        renderPairResult(host, payload);
      }
    } catch {
      toast('ペアリングコードを発行できませんでした');
    } finally {
      btn.disabled = false;
    }
  });
}

/* ---------------- Web Push (I-701, web side) ---------------- */

function b64ToBytes(b64) {
  const norm = String(b64).replace(/-/g, '+').replace(/_/g, '/');
  const bin = atob(norm + '='.repeat((4 - (norm.length % 4)) % 4));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/** Hide the push button when push is impossible here (or VAPID unset). */
export async function refreshPushButton() {
  const btn = document.getElementById('push-btn');
  if (!btn) return;
  const supported = 'serviceWorker' in navigator &&
    'PushManager' in window &&
    'showNotification' in ServiceWorkerRegistration.prototype;
  if (!supported || !state.token) {
    btn.hidden = true;
    return;
  }
  const key = await fetchVapidKey();
  btn.hidden = !key;
  btn.dataset.vapid = key || '';
}

async function subscribePush() {
  const btn = document.getElementById('push-btn');
  try {
    const perm = await Notification.requestPermission();
    if (perm !== 'granted') {
      toast('通知が許可されませんでした');
      return;
    }
    const vapid = (btn && btn.dataset.vapid) || (await fetchVapidKey());
    if (!vapid) {
      toast('ハブ未対応 — 通知は使えません');
      if (btn) btn.hidden = true;
      return;
    }
    const reg = await navigator.serviceWorker.ready;
    const sub = await reg.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: b64ToBytes(vapid),
    });
    const json = sub.toJSON();
    await postPushSub({
      endpoint: json.endpoint,
      keys: { p256dh: json.keys && json.keys.p256dh, auth: json.keys && json.keys.auth },
    });
    toast('通知を有効にしました');
  } catch {
    toast('通知の登録に失敗しました');
  }
}

function wirePush() {
  const btn = document.getElementById('push-btn');
  if (btn) btn.addEventListener('click', subscribePush);
  refreshPushButton();
}

/* ---------------- entry ---------------- */

export function wireSettings({ onSave } = {}) {
  const toggle = document.getElementById('settings-toggle');
  const panel = document.getElementById('settings');
  const hubInput = document.getElementById('hub-input');
  const tokenInput = document.getElementById('token-input');
  const save = document.getElementById('save-settings');
  if (!toggle || !panel || !hubInput || !tokenInput || !save) return;

  hubInput.value = state.hub;
  tokenInput.value = state.token;
  panel.hidden = !!state.token; // open until a token exists

  toggle.addEventListener('click', () => {
    panel.hidden = !panel.hidden;
  });
  save.addEventListener('click', () => {
    state.hub = hubInput.value.trim() || location.origin;
    state.token = tokenInput.value.trim();
    localStorage.setItem(LS_HUB, state.hub);
    localStorage.setItem(LS_TOKEN, state.token);
    panel.hidden = true;
    refreshPushButton();
    if (onSave) onSave();
  });

  wireQuiet();
  wirePairing();
  wirePush();
}
