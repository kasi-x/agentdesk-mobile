/* Processed tray + history / audit trail (I-120 / I-512) — client-side only.
 *
 * Every dismiss (local triage, local snooze, remote dismissTask, withdraw)
 * appends a minimal audit entry {taskId, action, source, at, agent, …}.
 * Entries persist in localStorage (cap 200) and group per local day.
 */
import { state, persistHistory, HISTORY_LIMIT } from './store.js';
import { el, clear } from './dom.js';
import { timeAgo } from './util.js';

const SOURCE_LABEL = {
  user: '自分',
  snooze: 'スヌーズ',
  auto: '自動',
  expire: '期限',
  withdraw: '取下げ',
};

const WEEKDAYS_JA = '日月火水木金土';

function metaFor(entry) {
  const a = String(entry.action || '');
  if (entry.source === 'snooze' || a === 'snooze') return { glyph: '⏱', cls: 'dim', label: '後で' };
  if (entry.source === 'expire' || a === 'expire') return { glyph: '⌛', cls: 'warn', label: '期限' };
  if (entry.source === 'withdraw' || a === 'withdraw') return { glyph: '↩', cls: 'warn', label: '取下げ' };
  if (entry.verdict === 'reject') return { glyph: '✕', cls: 'no', label: '却下' };
  if (entry.verdict === 'approve') return { glyph: '✓', cls: 'ok', label: '承認' };
  return { glyph: '•', cls: 'dim', label: a || '処理' };
}

/** Append one audit entry (newest first, capped). Data only — caller renders. */
export function recordProcessed(entry) {
  const row = {
    taskId: entry.taskId,
    action: entry.action || 'dismiss',
    source: SOURCE_LABEL[entry.source] ? entry.source : 'auto',
    verdict: entry.verdict || 'other',
    at: entry.at || new Date().toISOString(),
    agent: entry.agent || 'Agent',
    summary: entry.summary || '',
  };
  state.history.unshift(row);
  if (state.history.length > HISTORY_LIMIT) state.history.length = HISTORY_LIMIT;
  persistHistory();
}

function dayKey(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return 'unknown';
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

function todayKey() {
  return dayKey(new Date().toISOString());
}

function dayLabel(key) {
  if (key === 'unknown') return '日付不明';
  const now = todayKey();
  if (key === now) return '今日';
  const y = new Date();
  y.setDate(y.getDate() - 1);
  if (key === dayKey(y.toISOString())) return '昨日';
  const [yy, mm, dd] = key.split('-').map(Number);
  if (!yy) return key;
  const d = new Date(yy, mm - 1, dd);
  return `${mm}月${dd}日(${WEEKDAYS_JA[d.getDay()]})`;
}

function entryRow(entry) {
  const m = metaFor(entry);
  const row = el('button', 'hist-row');
  row.type = 'button';
  row.appendChild(el('span', `hist-ic ${m.cls}`, m.glyph));
  const body = el('span', 'hist-body');
  body.appendChild(el('span', 'hist-summary', entry.summary || entry.action));
  body.appendChild(el('span', 'hist-meta', `${entry.agent} · ${SOURCE_LABEL[entry.source] || entry.source}`));
  row.appendChild(body);
  row.appendChild(el('span', 'hist-time', timeAgo(entry.at)));
  return row;
}

/** Bottom-edge strip of today's processed cards (I-120). */
export function renderTray() {
  const tray = document.getElementById('tray');
  if (!tray) return;
  clear(tray);
  const today = todayKey();
  const todays = state.history.filter((e) => dayKey(e.at) === today);
  if (todays.length === 0) {
    tray.hidden = true;
    return;
  }
  tray.hidden = false;

  const toggle = el('button', 'tray-toggle');
  toggle.type = 'button';
  toggle.setAttribute('aria-expanded', String(false));
  toggle.appendChild(el('span', 'tray-label', `今日の処理 ${todays.length}`));
  toggle.appendChild(el('span', 'tray-chev'));
  toggle.addEventListener('click', openHistory);
  tray.appendChild(toggle);

  const items = el('div', 'tray-items');
  for (const entry of todays) {
    const m = metaFor(entry);
    const chip = el('button', 'tray-chip');
    chip.type = 'button';
    chip.title = entry.summary || entry.action;
    chip.appendChild(el('span', `hist-ic ${m.cls}`, m.glyph));
    chip.appendChild(el('span', 'tray-chip-text', entry.summary || entry.action));
    chip.appendChild(el('span', 'tray-chip-time', timeAgo(entry.at)));
    chip.addEventListener('click', openHistory);
    items.appendChild(chip);
  }
  tray.appendChild(items);
}

export function openHistory() {
  renderHistory();
  const panel = document.getElementById('history-panel');
  const backdrop = document.getElementById('history-backdrop');
  if (panel) panel.hidden = false;
  if (backdrop) backdrop.hidden = false;
}

export function closeHistory() {
  const panel = document.getElementById('history-panel');
  const backdrop = document.getElementById('history-backdrop');
  if (panel) panel.hidden = true;
  if (backdrop) backdrop.hidden = true;
}

/** Scrollable per-day history panel (I-512). */
export function renderHistory() {
  const panel = document.getElementById('history-panel');
  if (!panel) return;
  clear(panel);

  const head = el('div', 'sheet-head');
  head.appendChild(el('div', 'sheet-title', '処理履歴'));
  const close = el('button', 'btn dim sm', '閉じる');
  close.type = 'button';
  close.addEventListener('click', closeHistory);
  head.appendChild(close);
  panel.appendChild(head);

  if (state.history.length === 0) {
    panel.appendChild(el('div', 'hist-empty', 'まだ処理したカードはありません'));
    return;
  }

  const list = el('div', 'hist-list');
  let currentKey = null;
  for (const entry of state.history) {
    const key = dayKey(entry.at);
    if (key !== currentKey) {
      currentKey = key;
      list.appendChild(el('div', 'hist-day', dayLabel(key)));
    }
    list.appendChild(entryRow(entry));
  }
  panel.appendChild(list);
}
