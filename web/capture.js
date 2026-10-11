/* Audio/image capture fields (I-1001, web side): shared builders for the
 * inspect-form `AudioCapture` / `ImageCapture` components and the card-body
 * tiles in render.js. Every payload string reaches the DOM via textContent /
 * createElement (NFR-2.1) — never innerHTML, never eval.
 *
 * Each builder returns { node, read }: `read()` yields null when nothing was
 * captured, { kind, blob, contentType } for media, or { text } for the
 * plain-text fallback. Callers upload media holders via uploadHolder() on
 * submit and put { attachmentId, kind, contentType } into the same form-data
 * passthrough other components use. Unavailable capture (insecure context,
 * denied permission, missing API) degrades to a disabled notice plus the
 * text fallback — the form still submits.
 */
import { el } from './dom.js';
import { postAttachment } from './net.js';

/** Image picker size cap (10 MiB) — the hub rejects giant uploads. */
const MAX_IMAGE_BYTES = 10 * 1024 * 1024;

function dataBase64Of(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      const url = String(reader.result || '');
      const comma = url.indexOf(',');
      resolve(comma >= 0 ? url.slice(comma + 1) : url);
    };
    reader.onerror = () => reject(reader.error || new Error('read failed'));
    reader.readAsDataURL(blob);
  });
}

/** Upload one captured holder → { attachmentId, kind, contentType }. */
export async function uploadHolder(holder) {
  const dataBase64 = await dataBase64Of(holder.blob);
  const res = await postAttachment({
    kind: holder.kind,
    contentType: holder.contentType,
    dataBase64,
  });
  return {
    attachmentId: res && res.attachmentId !== undefined ? res.attachmentId : res && res.id,
    kind: holder.kind,
    contentType: holder.contentType,
  };
}

/** Disabled notice + plain-text fallback; returns its `read` function. */
function fallbackRead(box, placeholder) {
  box.appendChild(el('div', 'capture-status', '利用できません — テキストで回答できます'));
  const input = el('input', 'capture-text');
  input.type = 'text';
  input.placeholder = placeholder || 'テキストで回答';
  box.appendChild(input);
  return () => {
    const v = input.value.trim();
    return v ? { text: v } : null;
  };
}

function pickAudioMime() {
  const candidates = ['audio/webm', 'audio/mp4', 'audio/ogg'];
  for (const c of candidates) {
    try {
      if (window.MediaRecorder && MediaRecorder.isTypeSupported(c)) return c;
    } catch {
      /* isTypeSupported may throw on old implementations */
    }
  }
  return '';
}

/** Recorder UI: 録音/停止 → playback → 削除. read() → audio holder | null. */
export function renderAudioField(p) {
  const props = p || {};
  const box = el('div', 'capture-box');
  box.appendChild(el('div', 'capture-label', props.label || '音声'));
  const usable = typeof window !== 'undefined'
    && window.isSecureContext !== false
    && !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia)
    && typeof window.MediaRecorder !== 'undefined';
  if (!usable) return { node: box, read: fallbackRead(box, 'テキストで回答') };

  let holder = null;
  let recorder = null;
  let chunks = [];
  let stream = null;
  let objectUrl = null;
  const status = el('div', 'capture-status', '未録音');
  const row = el('div', 'capture-row');
  const rec = el('button', 'btn dim sm', '録音');
  rec.type = 'button';
  const player = document.createElement('audio');
  player.controls = true;
  player.hidden = true;
  player.className = 'capture-player';
  const remove = el('button', 'btn dim sm', '削除');
  remove.type = 'button';
  remove.hidden = true;
  const stopTracks = () => {
    if (stream) {
      for (const t of stream.getTracks()) t.stop();
      stream = null;
    }
  };
  const setIdle = () => {
    recorder = null;
    chunks = [];
    rec.textContent = '録音';
    rec.setAttribute('aria-pressed', 'false');
  };
  rec.addEventListener('click', async () => {
    if (recorder) {
      recorder.stop(); // the 'stop' handler below finalizes the take
      return;
    }
    status.textContent = 'マイク要求中…';
    let next;
    try {
      next = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch {
      status.textContent = '許可されませんでした';
      return;
    }
    stream = next;
    chunks = [];
    const mime = pickAudioMime();
    let active;
    try {
      active = mime ? new MediaRecorder(stream, { mimeType: mime }) : new MediaRecorder(stream);
    } catch {
      status.textContent = '録音できません';
      stopTracks();
      setIdle();
      return;
    }
    recorder = active;
    recorder.ondataavailable = (e) => {
      if (e.data && e.data.size > 0) chunks.push(e.data);
    };
    recorder.onstop = () => {
      const type = (active && active.mimeType) || mime || 'audio/webm';
      const blob = new Blob(chunks, { type });
      holder = { kind: 'audio', blob, contentType: blob.type || 'audio/webm' };
      if (objectUrl) URL.revokeObjectURL(objectUrl);
      objectUrl = URL.createObjectURL(blob);
      player.src = objectUrl;
      player.hidden = false;
      remove.hidden = false;
      status.textContent = '録音済み';
      stopTracks();
      setIdle();
    };
    recorder.start();
    rec.textContent = '停止';
    rec.setAttribute('aria-pressed', 'true');
    status.textContent = '録音中…';
  });
  remove.addEventListener('click', () => {
    holder = null;
    if (objectUrl) {
      URL.revokeObjectURL(objectUrl);
      objectUrl = null;
    }
    player.removeAttribute('src');
    player.hidden = true;
    remove.hidden = true;
    status.textContent = '未録音';
  });
  row.append(rec, remove);
  box.append(status, row, player);
  return { node: box, read: () => holder };
}

/** Picker UI: file input + thumbnail + 削除. read() → image holder | null. */
export function renderImageField(p) {
  const props = p || {};
  const box = el('div', 'capture-box');
  box.appendChild(el('div', 'capture-label', props.label || '画像'));
  let holder = null;
  let objectUrl = null;
  const status = el('div', 'capture-status', '未選択');
  const input = document.createElement('input');
  input.type = 'file';
  input.accept = 'image/*';
  input.setAttribute('capture', '');
  input.className = 'capture-file';
  const thumb = document.createElement('img');
  thumb.className = 'capture-preview';
  thumb.alt = '';
  thumb.hidden = true;
  const remove = el('button', 'btn dim sm', '削除');
  remove.type = 'button';
  remove.hidden = true;
  input.addEventListener('change', () => {
    const file = input.files && input.files[0];
    if (!file) return;
    if (file.type && !file.type.startsWith('image/')) {
      status.textContent = '画像を選んでください';
      input.value = '';
      return;
    }
    if (file.size > MAX_IMAGE_BYTES) {
      status.textContent = '大きすぎます（10MBまで）';
      input.value = '';
      return;
    }
    holder = { kind: 'image', blob: file, contentType: file.type || 'image/jpeg' };
    if (objectUrl) URL.revokeObjectURL(objectUrl);
    objectUrl = URL.createObjectURL(file);
    thumb.src = objectUrl;
    thumb.hidden = false;
    remove.hidden = false;
    status.textContent = file.name || '選択済み';
  });
  remove.addEventListener('click', () => {
    holder = null;
    input.value = '';
    if (objectUrl) {
      URL.revokeObjectURL(objectUrl);
      objectUrl = null;
    }
    thumb.removeAttribute('src');
    thumb.hidden = true;
    remove.hidden = true;
    status.textContent = '未選択';
  });
  box.append(status, input, thumb, remove);
  return { node: box, read: () => holder };
}
