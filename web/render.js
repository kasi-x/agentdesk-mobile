/* Rendering: A2UI component catalog, card, stack, diff/value helpers.
 * Every payload string reaches the DOM only via textContent/createElement
 * (NFR-2.1) — never innerHTML, never eval. */
import { el, clear } from './dom.js';
import { state, visibleStack, visibleUnits, parkedCount, SNOOZE_OPTIONS } from './store.js';
import { riskLevel, timeAgo, fmtEditDateTime, isChooseTask, snoozeUntilLabel } from './util.js';
import {
  triage, snooze, selectIndex, approve, choose, bulkApprove, delegate,
  rowSelection, toggleRow, editedValue,
} from './actions.js';
import { openInspect } from './inspect.js';
import { renderTray } from './history.js';
import { renderFleet } from './fleet.js';
import { renderStampBanner } from './stamp.js';

/* Animate UI counting-number, translated: tween the pending count so a
 * batch of dismissals ticks down instead of jumping. */
let _pendingShown = null;
let _pendingRaf = 0;

export function setPendingCount(target) {
  const el2 = document.getElementById('pending-count');
  if (!el2) return;
  const from = _pendingShown;
  _pendingShown = target;
  if (from === null || from === target) {
    el2.textContent = `${target} pending`;
    return;
  }
  cancelAnimationFrame(_pendingRaf);
  const start = performance.now();
  const DURATION = 420;
  const step = (now) => {
    const t = Math.min(1, (now - start) / DURATION);
    const eased = 1 - Math.pow(1 - t, 3); // easeOutCubic
    el2.textContent = `${Math.round(from + (target - from) * eased)} pending`;
    if (t < 1) _pendingRaf = requestAnimationFrame(step);
  };
  _pendingRaf = requestAnimationFrame(step);
}

/** Render order: children of TriageCard if present, else array order. */
export function orderedComponents(task) {
  const list = Array.isArray(task.components) ? task.components : [];
  const root = list.find((c) => c && c.component === 'TriageCard');
  if (root && Array.isArray(root.children)) {
    const byId = new Map(list.map((c) => [c && c.id, c]));
    const resolved = root.children
      .map((id) => byId.get(id))
      .filter((c) => c && c.component !== 'TriageCard');
    // Include any stray components not referenced by the root.
    const rest = list.filter((c) => c && !root.children.includes(c.id));
    return resolved.concat(rest.filter((c) => c.component !== 'TriageCard'));
  }
  return list.filter((c) => c && c.component !== 'TriageCard');
}

/* ---------------- value-aware diff rendering ----------------
 * 「2026-10-05 14:00 → 16:30」はカレンダーの変更に、「$120 → $80」は
 * 金額の変更に見えるように。パースできる値だけ意味づけし、それ以外は
 * 従来のテキスト差分にフォールバックする(どちらも純粋なテキスト描画)。 */
const WEEKDAYS_JA = '日月火水木金土';

export function parseValue(raw) {
  const s = String(raw ?? '').trim();
  if (!s) return null;
  let m = s.match(/^(\d{4})-(\d{1,2})-(\d{1,2})[ T](\d{1,2}):(\d{2})(?::\d{2})?$/);
  if (m) {
    const d = new Date(+m[1], +m[2] - 1, +m[3]);
    return {
      kind: 'datetime',
      dateKey: `${m[1]}-${m[2]}-${m[3]}`,
      date: `${+m[2]}月${+m[3]}日(${WEEKDAYS_JA[d.getDay()]})`,
      time: `${String(+m[4]).padStart(2, '0')}:${m[5]}`,
    };
  }
  m = s.match(/^(\d{1,2}):(\d{2})$/);
  if (m) return { kind: 'time', time: `${String(+m[1]).padStart(2, '0')}:${m[2]}` };
  m = s.match(/^([^0-9\s]+)\s*([\d,]+(?:\.\d+)?)$/);
  if (m && /^(?:[$¥€£]|usd|jpy|eur)/i.test(m[1])) {
    return { kind: 'money', symbol: m[1], amount: parseFloat(m[2].replace(/,/g, '')) };
  }
  return null;
}

function minutesOf(time) {
  const [h, m] = time.split(':').map(Number);
  return h * 60 + m;
}

function deltaLabel(bv, av) {
  if (bv.kind === 'datetime' && av.kind === 'datetime' && bv.dateKey === av.dateKey) {
    const diff = minutesOf(av.time) - minutesOf(bv.time);
    const sign = diff >= 0 ? '+' : '−';
    const abs = Math.abs(diff);
    const h = Math.floor(abs / 60);
    const mm = abs % 60;
    return sign + (h ? `${h}時間${mm ? `${mm}分` : ''}` : `${mm}分`);
  }
  if (bv.kind === 'money' && av.kind === 'money' && bv.symbol === av.symbol) {
    const diff = av.amount - bv.amount;
    const sign = diff >= 0 ? '+' : '−';
    return `${sign}${bv.symbol}${Math.abs(diff).toLocaleString('en-US')}`;
  }
  return null;
}

function diffIcon(name, cls) {
  return el('span', `dvv-ic dvv-ic-${name} ${cls || ''}`);
}

function valueChip(v, isBefore) {
  const chip = el('span', `dvv-chip ${isBefore ? 'before' : 'after'}`);
  if (v.kind !== 'money') chip.appendChild(diffIcon('clock'));
  chip.appendChild(el('span', 'dvv-chip-text',
    v.kind === 'money' ? `${v.symbol}${v.amount.toLocaleString('en-US')}` : v.time));
  return chip;
}

/* その日の予定表で「枠がどこへ移動したか」を空間的に描く:
 * 開始も終了も変わるので、ゴースト枠(変更前 [b, b+dur])と、そこから
 * スライドしてくる白い枠(変更後 [a, a+dur])を重ね、 displacement を
 * 開始・終了の両境界を目盛りに示す。すべて表示計算のみ。 */
function dayTimeline(bv, av, durationMin) {
  const dur = Number.isFinite(durationMin) && durationMin > 0 ? durationMin : 60;
  const b = minutesOf(bv.time);
  const a = minutesOf(av.time);
  let start = Math.max(0, Math.floor(Math.min(b, a) / 60) * 60);
  let end = Math.min(24 * 60, Math.ceil((Math.max(b, a) + dur) / 60) * 60);
  if (end - start < 120) start = Math.max(0, end - 120);
  const span = end - start;
  const pos = (m) => ((m - start) / span) * 100;
  const fmt = (m) => `${String(Math.floor(m / 60) % 24).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;
  const slotLabel = (m) => `${fmt(m)} – ${fmt(m + dur)}`;

  const track = el('div', 'dvv-tl');

  // bars: ghost (before) + the slot that slid into place (after).
  // The delta chip already rides the chips row above — no bracket lane.
  const bars = el('div', 'dvv-tl-bars');
  const ghost = el('div', 'dvv-tl-bar ghost', slotLabel(b));
  ghost.style.left = `${pos(b)}%`;
  ghost.style.width = `${(dur / span) * 100}%`;
  const slot = el('div', 'dvv-tl-bar slot', slotLabel(a));
  slot.style.left = `${pos(a)}%`;
  slot.style.width = `${(dur / span) * 100}%`;
  // 空間の移動: the block starts where the ghost is and slides to its
  // new position (shift in element-widths; sign handles either direction)
  slot.style.setProperty('--shift', `${((b - a) / dur) * 100}%`);
  bars.append(ghost, slot);
  track.appendChild(bars);

  // No tick row: both boundary times already ride the slot labels above —
  // information is shown once, not three times.
  return track;
}

function renderValuePair(parent, label, beforeRaw, afterRaw, opts = {}) {
  const row = el('div', 'diffbox-row');
  if (label) row.appendChild(el('div', 'diffbox-rowlabel', label));
  const bv = parseValue(beforeRaw);
  const av = parseValue(afterRaw);
  if (bv && av && bv.kind === av.kind) {
    const chips = el('div', 'dvv-chips');
    if (bv.kind === 'datetime') {
      const dateChip = el('span', 'dvv-date');
      dateChip.appendChild(diffIcon('calendar'));
      dateChip.appendChild(el('span', 'dvv-date-text', bv.date));
      chips.appendChild(dateChip);
    }
    chips.appendChild(valueChip(bv, true));
    chips.appendChild(diffIcon('arrow-right', 'dvv-arrow'));
    chips.appendChild(valueChip(av, false));
    const delta = deltaLabel(bv, av);
    if (delta) chips.appendChild(el('span', 'dvv-delta', delta));
    row.appendChild(chips);
    if (bv.kind === 'datetime' && bv.dateKey === av.dateKey) {
      row.appendChild(dayTimeline(bv, av, opts.durationMin));
    }
  } else {
    row.appendChild(el('div', 'diff-before', beforeRaw || ''));
    row.appendChild(el('div', 'diff-after', `→ ${afterRaw || ''}`));
  }
  parent.appendChild(row);
}

export function renderComponent(comp, task) {
  const box = el('div', 'comp');
  switch (comp.component) {
    case 'Text': {
      const p = comp.properties || {};
      const variant = p.variant === 'title' ? 'title' : p.variant === 'body' ? 'body' : 'caption';
      const t = el('div', `text-${variant}`, p.text || '');
      if (p.source === 'external') t.classList.add('text-external'); // NFR-2.2 quote block
      box.appendChild(t);
      return box;
    }
    case 'DiffBox': {
      const p = comp.properties || {};
      const wrap = el('div', 'diffbox');
      const hl = p.highlight === 'warning' ? 'warning' : p.highlight === 'critical' ? 'critical' : 'info';
      wrap.appendChild(el('div', `diffbox-highlight ${hl}`));
      if (p.title && typeof p.title === 'string') {
        wrap.appendChild(el('div', 'diffbox-title', p.title));
      }
      const pairOpts = { durationMin: Number(p.duration) };
      renderValuePair(wrap, null, p.before, p.after, pairOpts);
      if (Array.isArray(p.rows)) {
        const objects = p.rows.filter((r) => r && typeof r === 'object');
        if (p.selectable && comp.id !== undefined && objects.length > 0) {
          // Row-select: DiffBox rows are toggleable checkboxes — the approve
          // payload carries the remaining ids as `acceptedRows`, omitted
          // when everything stays checked. Defaults to all-selected.
          const ids = objects.map((r, i) =>
            (r.id !== undefined && r.id !== null ? String(r.id) : String(i)));
          const sel = rowSelection(task.taskId, comp.id, ids);
          objects.forEach((r, i) => {
            const btn = el('button', 'diffrow-check' + (sel.has(ids[i]) ? ' on' : ''));
            btn.type = 'button';
            btn.setAttribute('aria-pressed', String(sel.has(ids[i])));
            btn.title = sel.has(ids[i]) ? '承認に含む' : '承認から外す';
            btn.appendChild(el('span', 'diffrow-box', sel.has(ids[i]) ? '✓' : ''));
            const body = el('span', 'diffrow-body');
            renderValuePair(body, r.label || null, r.before, r.after, pairOpts);
            btn.appendChild(body);
            btn.addEventListener('click', () => {
              toggleRow(task.taskId, comp.id, ids[i], ids);
              render();
            });
            wrap.appendChild(btn);
          });
        } else {
          for (const r of objects) {
            renderValuePair(wrap, r.label || null, r.before, r.after, pairOpts);
          }
        }
      }
      if (typeof p.inline === 'string' && p.inline) {
        // Unified-diff style: + green, - red, context dim. Plain text only.
        const pre = el('div', 'diffbox-inline');
        for (const line of p.inline.split('\n')) {
          const cls = line.startsWith('+') ? 'diff-line-add' : line.startsWith('-') ? 'diff-line-del' : 'diff-line-ctx';
          pre.appendChild(el('div', cls, line === '' ? ' ' : line));
        }
        wrap.appendChild(pre);
      }
      box.appendChild(wrap);
      return box;
    }
    case 'Chips': {
      const p = comp.properties || {};
      const wrap = el('div', 'chips');
      const options = Array.isArray(p.options) ? p.options : [];
      for (const opt of options) {
        const chip = el('button', 'chip', (opt && opt.label) || '?');
        chip.type = 'button';
        chip.addEventListener('click', () => {
          if (opt && opt.actionName) {
            triage(task, { actionName: opt.actionName, data: opt.payload, source: 'quick_chip' });
          } else {
            openInspect(task);
          }
        });
        wrap.appendChild(chip);
      }
      box.appendChild(wrap);
      return box;
    }
    default: {
      // FR-1.3 fallback card for unknown component types.
      const f = el('div', 'fallback');
      f.appendChild(el('div', 'fallback-label', `${comp.component || 'unknown'} — 未対応コンポーネント`));
      f.appendChild(el('div', 'fallback-text', JSON.stringify(comp.properties || {})));
      box.appendChild(f);
      return box;
    }
  }
}

/* ---------------- expiry countdown (I-203) ---------------- */

export function countdownParts(expiresAt, onExpire) {
  const ms = Date.parse(expiresAt) - Date.now();
  const verb = { approve: '期限で自動承認', reject: '期限で自動却下', escalate: '期限で緊急化' }[onExpire] || '期限で破棄';
  if (!(ms > 0)) return { cls: 'past', text: '期限切れ · まもなく自動処理' };
  const min = Math.floor(ms / 60000);
  const sec = Math.floor((ms % 60000) / 1000);
  let left;
  if (min >= 60) left = `${Math.floor(min / 60)}時間${min % 60}分`;
  else if (min >= 10) left = `${min}分`;
  else if (min >= 1) left = `${min}分${sec}秒`;
  else left = `${sec}秒`;
  const cls = min <= 5 ? 'urgent' : min <= 30 ? 'soon' : '';
  return { cls, text: `残り ${left} · ${verb}` };
}

/** Text-only refresh — a full render() every few seconds would break
 *  pointer-holds and drags mid-gesture. */
function updateCountdown(el2) {
  const parts = countdownParts(el2.dataset.expires, el2.dataset.onexpire);
  el2.classList.toggle('soon', parts.cls === 'soon');
  el2.classList.toggle('urgent', parts.cls === 'urgent' || parts.cls === 'past');
  el2.textContent = parts.text;
}

setInterval(() => {
  document.querySelectorAll('.countdown[data-expires]').forEach(updateCountdown);
}, 5000);

const expandedIds = new Set();

export function renderCard(task, { focused = false } = {}) {
  const sev = task.severity === 'critical' ? 'critical' : task.severity === 'warning' ? 'warning' : 'info';
  const impact = task.impact && typeof task.impact === 'object' ? task.impact : null;
  const ctx = task.context && typeof task.context === 'object' ? task.context : null;
  const reasons = Array.isArray(task.confidenceReasons) ? task.confidenceReasons : [];
  const pct = typeof task.confidence === 'number'
    ? Math.round(Math.min(1, Math.max(0, task.confidence)) * 100) : null;

  const card = el('div', `card sev-${sev}` + (focused ? ' kb-focus' : ''));
  const inner = el('div', 'card-inner');

  // Header: avatar, agent name (secondary), severity dot, time.
  const header = el('div', 'card-header');
  const avatar = el('div', 'avatar');
  const agent = task.agent || {};
  if (agent.avatarUrl) {
    const img = el('img');
    img.src = agent.avatarUrl;
    img.alt = '';
    img.referrerPolicy = 'no-referrer';
    avatar.appendChild(img);
  } else {
    avatar.textContent = (agent.name || '?').slice(0, 1).toUpperCase();
  }
  header.appendChild(avatar);
  header.appendChild(el('span', 'card-agent', agent.name || 'Agent'));
  if (task.delegatedTo) header.appendChild(el('span', 'deleg-badge', `→${task.delegatedTo}`));
  header.appendChild(el('span', `sev-dot ${sev === 'info' ? '' : sev}`.trim()));
  const timeWrap = el('span', 'card-meta-time', timeAgo(task.createdAt));
  header.appendChild(timeWrap);
  inner.appendChild(header);

  // Headline: the summary. The 承認すると… result statement lives in
  // 詳細 (結果 row) — the front stays as short as possible.
  inner.appendChild(el('div', 'summary', task.summary || ''));

  // Information reduction (P1/P8): caption/external texts are 裏面 material —
  // they render inside the details panel, not on the front.
  const movedTexts = [];
  for (const comp of orderedComponents(task)) {
    const isNarrative = comp.component === 'Text' &&
      (comp.properties?.variant === 'caption' || comp.properties?.source === 'external');
    if (isNarrative) movedTexts.push(comp);
    else inner.appendChild(renderComponent(comp, task));
  }

  // Quiet meta: ONLY the urgent countdown (<=5m / past). 信頼度 is gone
  // (user decision); the full deadline lives in 詳細 — one place, never two.
  if (typeof task.expiresAt === 'string' && task.expiresAt) {
    const parts = countdownParts(task.expiresAt, task.onExpire || 'drop');
    if (parts.cls === 'urgent' || parts.cls === 'past') {
      const meta = el('div', 'meta');
      const cd = el('span', 'meta-item countdown urgent');
      cd.dataset.expires = task.expiresAt;
      cd.dataset.onexpire = task.onExpire || 'drop';
      updateCountdown(cd);
      meta.appendChild(cd);
      inner.appendChild(meta);
    }
  }

  // Wave-2 status line (I-604/I-902, display-only): multi-approval progress + delivery trouble.
  const req = Number(task.requiredApprovals || 1);
  const got = Number(state.approvalProgress[task.taskId] || 0);
  if (req > 1 && got > 0) {
    inner.appendChild(el('div', 'approve-progress', `承認 ${got}/${req}`));
  }
  if (state.deliveryFailed.has(task.taskId)) {
    inner.appendChild(el('div', 'delivery-warn', '⚠ エージェントに返信できませんでした'));
  }

  // 詳細を見る — 結果/理由/誰が/参加者/出典/金額/注意点 expand downward.
  const hasContext = !!(ctx && (ctx.reasoning || ctx.requester?.name ||
    (Array.isArray(ctx.participants) && ctx.participants.length) || ctx.source?.label));
  const hasExtra = hasContext || movedTexts.length > 0 || (impact && impact.summary) ||
    (impact && impact.cost) ||
    (pct !== null && pct < 90 && reasons.length > 0) || !!task.expiresAt;
  if (hasExtra) {
    const wrap = el('div', 'details');
    const toggle = el('button', 'details-toggle');
    toggle.type = 'button';
    const expanded = expandedIds.has(task.taskId);
    const label = el('span', 'details-label', expanded ? '詳細を隠す' : '詳細を見る');
    const chev = el('span', 'details-chev');
    toggle.append(label, chev);
    const panel = el('div', 'details-panel' + (expanded ? ' open' : ''));
    if (expanded) toggle.classList.add('open');
    const clip = el('div', 'details-clip');
    clip.appendChild(buildDetailsList(task, { ctx, impact, reasons, movedTexts }));
    panel.appendChild(clip);
    toggle.addEventListener('click', () => {
      const open = !panel.classList.contains('open');
      panel.classList.toggle('open', open);
      toggle.classList.toggle('open', open);
      label.textContent = open ? '詳細を隠す' : '詳細を見る';
      if (open) expandedIds.add(task.taskId);
      else expandedIds.delete(task.taskId);
    });
    wrap.append(toggle, panel);
    inner.appendChild(wrap);
  }

  card.appendChild(inner);
  // Choose cards (decisionKind 'choose'): two stacked options — A on top,
  // B below. ArrowUp/ArrowDown pick directly; → is disabled; ← still rejects.
  const chooseMode = isChooseTask(task);
  const choices = chooseMode ? task.choices : [];
  if (chooseMode) {
    const bind = (i) => (task.actions || {})[i === 0 ? 'onSwipeUp' : 'onSwipeDown'];
    const pick = (i) => choose(task, i);
    const box = el('div', 'choose-options');
    choices.slice(0, 2).forEach((c, i) => {
      const b = el('button', 'choose-opt' + (i === 0 ? ' top' : ' bottom'));
      b.type = 'button';
      const kbd = el('span', 'choose-key', i === 0 ? '↑ A' : '↓ B');
      b.appendChild(kbd);
      b.appendChild(el('span', 'choose-label', (c && c.label) || `選択肢${i + 1}`));
      b.disabled = !!state.paused;
      b.addEventListener('click', () => pick(i));
      box.appendChild(b);
    });
    card.appendChild(box);
  }

  // Editable hint (I-114): number stepper / datetime ±step controls inline.
  // The value rides the approve payload as data.edited.
  if (task.editable && task.editable.kind && !chooseMode) {
    const e = task.editable;
    const step = Number.isFinite(Number(e.step)) && Number(e.step) > 0 ? Number(e.step) : 1;
    const wrap = el('div', 'editrow');
    if (e.kind === 'number') {
      const dec = el('button', 'edit-step', '−');
      const inc = el('button', 'edit-step', '＋');
      dec.type = inc.type = 'button';
      const val = el('span', 'edit-value', String(editedValue(task)));
      const bump = (d) => {
        let v = Number(editedValue(task)) || 0;
        v += d * step;
        if (Number.isFinite(Number(e.min))) v = Math.max(Number(e.min), v);
        if (Number.isFinite(Number(e.max))) v = Math.min(Number(e.max), v);
        editedValue(task, v);
        val.textContent = String(v);
      };
      dec.addEventListener('click', () => bump(-1));
      inc.addEventListener('click', () => bump(1));
      wrap.append(dec, val, inc);
    } else if (e.kind === 'datetime') {
      const span = Number(step);
      const back = el('button', 'edit-step', '−');
      const fwd = el('button', 'edit-step', '＋');
      back.type = fwd.type = 'button';
      back.title = `−${span}分`;
      fwd.title = `＋${span}分`;
      const val = el('span', 'edit-value', fmtEditDateTime(editedValue(task)));
      const shift = (d) => {
        const cur = Date.parse(editedValue(task)) || Date.now();
        const next = new Date(cur + d * span * 60000).toISOString();
        editedValue(task, next);
        val.textContent = fmtEditDateTime(next);
      };
      back.addEventListener('click', () => shift(-1));
      fwd.addEventListener('click', () => shift(1));
      wrap.append(back, val, fwd);
    }
    if (wrap.children.length) card.appendChild(wrap);
  }

  // Actions row: two decisions + snooze + delegate. 承認 carries the weight.
  const actions = el('div', 'card-actions');
  const right = task.actions && task.actions.onSwipeRight;
  const left = task.actions && task.actions.onSwipeLeft;

  const approveBtn = el('button', 'btn ok', `${(right && right.label) || 'Approve'}`);
  approveBtn.type = 'button';
  approveBtn.addEventListener('click', () => {
    // I-401: approve() arms on the first click while gated (returns false)
    // — the armed label is local so a re-render never wipes it mid-gesture.
    const sent = approve(task, { source: 'web_ui' });
    if (!sent) {
      approveBtn.classList.add('armed');
      approveBtn.textContent = 'もう一度で承認';
      clearTimeout(approveBtn._armT);
      approveBtn._armT = setTimeout(() => {
        if (state.stampArm === task.taskId) {
          state.stampArm = null;
          render();
        }
      }, 4000);
    }
  });
  // Choose cards use ↑/↓ — → is disabled.
  if (chooseMode) {
    approveBtn.disabled = true;
    approveBtn.classList.add('paused');
    approveBtn.title = '↑↓ で選択してください';
  }
  // Emergency stop (I-403): no approvals while the hub is paused.
  if (state.paused) {
    approveBtn.disabled = true;
    approveBtn.classList.add('paused');
    approveBtn.title = '緊急停止中 — 承認は無効です';
  }

  // Reject reason chips (I-118): when the agent supplied candidates,
  // expand them inline; ignoring them (timeout) rejects without a reason.
  const rejectReasons = (task.actions && task.actions.rejectReasons) || [];
  let reasonTimer = null;
  const sendReject = (reasonId) => {
    clearTimeout(reasonTimer);
    const data = Object.assign({}, (left && left.payload) || {});
    if (reasonId != null) data.reason = reasonId;
    triage(task, {
      actionName: (left && left.actionName) || 'reject',
      data,
      source: 'web_ui',
    });
  };
  const reject = el('button', 'btn no', `${(left && left.label) || 'Reject'}`);
  reject.type = 'button';
  if (rejectReasons.length) {
    reject.addEventListener('click', () => {
      reject.style.display = 'none';
      const row = el('div', 'reason-chips');
      row.appendChild(el('span', 'reason-title', '理由 (任意):'));
      for (const r of rejectReasons) {
        const chip = el('button', 'chip', r.label || '?');
        chip.type = 'button';
        chip.addEventListener('click', (e) => { e.stopPropagation(); sendReject(r.id); });
        row.appendChild(chip);
      }
      const skip = el('button', 'chip dim', '理由なし');
      skip.type = 'button';
      skip.addEventListener('click', (e) => { e.stopPropagation(); sendReject(null); });
      row.appendChild(skip);
      actions.appendChild(row);
      reasonTimer = setTimeout(() => sendReject(null), 4000);
    });
  } else {
    reject.addEventListener('click', () => sendReject(null));
  }
  actions.appendChild(approveBtn);

  // Locked (critical + irreversible): approve becomes a hold-to-confirm
  // ring (I-102/I-103). Pointer press fills it; early release cancels.
  if (riskLevel(task) === 'locked') {
    approveBtn.textContent = `${(right && right.label) || '長押しで承認'}`;
    approveBtn.classList.add('hold');
    let holdTimer = null;
    let progress = null;
    const HOLD_MS = 1200;
    approveBtn.addEventListener('pointerdown', (e) => {
      e.preventDefault();
      approveBtn.classList.add('holding');
      progress = el('span', 'hold-progress');
      approveBtn.appendChild(progress);
      progress.animate(
        [{ transform: 'scaleX(0)' }, { transform: 'scaleX(1)' }],
        { duration: HOLD_MS, fill: 'forwards' },
      );
      holdTimer = setTimeout(() => {
        cleanup();
        approve(task, { source: 'hold_confirm' });
      }, HOLD_MS);
    });
    const cleanup = () => {
      clearTimeout(holdTimer);
      holdTimer = null;
      approveBtn.classList.remove('holding');
      progress?.remove();
      progress = null;
    };
    approveBtn.addEventListener('pointerup', cleanup);
    approveBtn.addEventListener('pointerleave', cleanup);
    approveBtn.addEventListener('pointercancel', cleanup);
    approveBtn.addEventListener('contextmenu', (e) => e.preventDefault());
  }
  // Snooze menu (I-702): +1h default, 明日朝 option — server-side first,
  // local move-to-tail fallback when the POST fails.
  const snz = el('button', 'btn dim', '後で');
  snz.type = 'button';
  snz.addEventListener('click', (e) => {
    e.stopPropagation();
    const open = snz.parentElement.querySelector('.snooze-menu');
    if (open) {
      open.remove();
      return;
    }
    closePopups();
    const menu = el('div', 'snooze-menu');
    for (const opt of SNOOZE_OPTIONS) {
      const item = el('button', 'snooze-opt', opt.label);
      item.type = 'button';
      item.addEventListener('click', (ev) => {
        ev.stopPropagation();
        menu.remove();
        snooze(task, opt.until());
      });
      menu.appendChild(item);
    }
    snz.parentElement.appendChild(menu);
    setTimeout(() => document.addEventListener('click', function once() {
      menu.remove();
    }, { once: true }), 0);
  });

  // Delegate (I-703): 「回す」 opens an inline target field inside the card;
  // the hub only tags delegatedTo — the card stays pending.
  const dlg = el('button', 'btn ghost', '回す');
  dlg.type = 'button';
  dlg.title = '他の人に回す';
  dlg.addEventListener('click', (e) => {
    e.stopPropagation();
    closePopups();
    const row = el('div', 'delegate-row');
    row.appendChild(el('span', 'delegate-label', '回す先:'));
    const input = el('input', 'delegate-input');
    input.type = 'text';
    input.placeholder = '名前 / チーム';
    input.value = task.delegatedTo || '';
    row.appendChild(input);
    const send = el('button', 'btn primary sm', '回す');
    send.type = 'button';
    const cancel = el('button', 'btn dim sm', '取消');
    cancel.type = 'button';
    const submit = () => {
      const to = input.value.trim();
      if (to) delegate(task, to);
      row.remove();
    };
    send.addEventListener('click', (ev) => { ev.stopPropagation(); submit(); });
    input.addEventListener('keydown', (ev) => {
      if (ev.key === 'Enter') submit();
      if (ev.key === 'Escape') row.remove();
      ev.stopPropagation();
    });
    cancel.addEventListener('click', (ev) => { ev.stopPropagation(); row.remove(); });
    row.append(send, cancel);
    actions.appendChild(row);
    input.focus();
  });

  actions.append(reject, snz, dlg, approveBtn);
  card.appendChild(actions);
  return card;
}

/** Close transient card popups (snooze menu / delegate row) before opening another. */
function closePopups() {
  document.querySelectorAll('.snooze-menu, .delegate-row').forEach((n) => n.remove());
}

/* 詳細パネル: 理由 / 誰が / 参加者 / 出典 / 金額 / 注意点 (P1: 裏面)。
 * All payload strings render via textContent (NFR-2.1); links are
 * restricted to http(s) so a payload can never become javascript:. */
function buildDetailsList(task, { ctx, impact, reasons, movedTexts = [] }) {
  const list = el('div', 'details-list');

  // horizontal row: icon + label left, value right (short values)
  const rowH = (icon, label, valueNode) => {
    const r = el('div', 'drow drow-h');
    r.appendChild(el('span', `drow-ic dvv-ic dvv-ic-${icon}`));
    r.appendChild(el('span', 'drow-label', label));
    const v = el('span', 'drow-value');
    v.appendChild(valueNode);
    r.appendChild(v);
    list.appendChild(r);
    return r;
  };
  // stacked row: icon + label on one line, value below (long values)
  const rowW = (icon, label, valueNode) => {
    const r = el('div', 'drow');
    const head = el('div', 'drow-head');
    head.appendChild(el('span', `drow-ic dvv-ic dvv-ic-${icon}`));
    head.appendChild(el('span', 'drow-label', label));
    r.appendChild(head);
    r.appendChild(valueNode);
    list.appendChild(r);
    return r;
  };
  const safeHref = (url) =>
    typeof url === 'string' && /^https?:\/\//i.test(url) ? url : null;

  // 結果 — the decision statement, always first
  if (impact && typeof impact.summary === 'string' && impact.summary) {
    const v = el('div', 'drow-value', `承認すると ${impact.summary}`);
    if (impact.reversible === false) {
      v.appendChild(el('div', 'sub warn', 'この操作は取り消せません'));
    }
    rowW('bolt', '結果', v);
  }
  // なぜ — caption texts (moved off the front) + context.reasoning
  const narrative = movedTexts.filter(
    (comp) => comp.component === 'Text' && comp.properties?.source !== 'external',
  );
  const quotes = movedTexts.filter(
    (comp) => comp.component === 'Text' && comp.properties?.source === 'external',
  );
  if (narrative.length > 0 || (ctx && ctx.reasoning)) {
    const v = el('div', 'drow-value');
    for (const comp of narrative) {
      v.appendChild(el('div', '', String(comp.properties?.text ?? '')));
    }
    if (ctx && ctx.reasoning) v.appendChild(el('div', '', ctx.reasoning));
    rowW('bulb', 'なぜ', v);
  }
  for (const comp of quotes) {
    rowW('mail', '引用', renderComponent(comp, task).firstChild);
  }
  if (ctx && ctx.requester && ctx.requester.name) {
    const v = el('div', 'drow-value');
    v.appendChild(el('span', '', ctx.requester.name));
    if (ctx.requester.onBehalfOf) {
      v.appendChild(el('span', 'sub', ` · ${ctx.requester.onBehalfOf} の依頼`));
    }
    rowH('person', '誰が', v);
  }
  if (ctx && Array.isArray(ctx.participants) && ctx.participants.length) {
    const wrap = el('div', 'drow-value');
    wrap.style.display = 'flex';
    wrap.style.flexWrap = 'wrap';
    wrap.style.gap = '6px';
    wrap.style.justifyContent = 'flex-end';
    for (const p of ctx.participants) {
      const chip = el('span', 'dpart');
      const status = (p.status || '').toLowerCase();
      const dot = el('span', `dpart-dot${status.includes('free') ? ' free' : status.includes('busy') || status.includes('重複') ? ' busy' : ''}`);
      chip.append(dot, el('span', '', p.name));
      if (p.status) chip.appendChild(el('span', 'sub', p.status));
      wrap.appendChild(chip);
    }
    rowH('group', '参加者', wrap);
  }
  if (ctx && ctx.source && ctx.source.label) {
    const href = safeHref(ctx.source.url);
    const v = el('div', 'drow-value');
    if (href) {
      const a = el('a', 'dlink', ctx.source.label);
      a.href = href;
      a.target = '_blank';
      a.rel = 'noopener noreferrer';
      v.appendChild(a);
    } else {
      v.appendChild(el('span', '', ctx.source.label));
    }
    rowH('link', '出典', v);
  }
  if (impact && impact.cost && typeof impact.cost === 'object' &&
      typeof impact.cost.amount === 'number' && impact.cost.currency) {
    rowH('payments', '金額', el('span', '', `${impact.cost.currency} ${impact.cost.amount.toLocaleString('en-US')}`));
  }
  if (reasons.length > 0) {
    const wrap = el('div', 'drow-value');
    wrap.style.display = 'flex';
    wrap.style.flexWrap = 'wrap';
    wrap.style.gap = '6px';
    wrap.style.justifyContent = 'flex-end';
    for (const r of reasons) wrap.appendChild(el('span', 'dtag', r));
    rowH('warning', '注意点', wrap);
  }
  // 期限: shown here ONLY while the front shows no urgent countdown —
  // the deadline is displayed in exactly one place at any moment.
  if (typeof task.expiresAt === 'string' && task.expiresAt) {
    const parts = countdownParts(task.expiresAt, task.onExpire || 'drop');
    const onFront = parts.cls === 'urgent' || parts.cls === 'past';
    if (!onFront) {
      const at = new Date(task.expiresAt);
      const when = Number.isNaN(at.getTime())
        ? task.expiresAt
        : at.toLocaleString('ja-JP', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' });
      const verb = { approve: '自動承認', reject: '自動却下', escalate: '緊急化' }[task.onExpire] || '自動破棄';
      rowH('schedule', '期限', el('span', '', `${when} — ${verb}`));
    }
  }

  // form editing lives behind one clear affordance at the panel bottom
  const form = task.actions && Array.isArray(task.actions.inspectForm)
    ? task.actions.inspectForm : [];
  if (form.length > 0) {
    const edit = el('button', 'btn primary details-edit', '✎ 修正して承認');
    edit.type = 'button';
    edit.addEventListener('click', () => openInspect(task));
    list.appendChild(edit);
  }
  return list;
}

const groupOpen = new Set(); // groupKeys expanded in the stack (I-201)

function renderMini(task, index) {
  const mini = el('div', 'mini' + (state.kbActive && state.selected === index ? ' kb-focus' : ''));
  mini.setAttribute('role', 'button');
  mini.tabIndex = 0;
  mini.title = '選択';
  const sev = task.severity === 'critical' ? 'critical' : task.severity === 'warning' ? 'warning' : 'info';
  mini.appendChild(el('span', `mini-badge ${sev}`, sev));
  mini.appendChild(el('span', 'mini-agent', (task.agent && task.agent.name) || 'Agent'));
  mini.appendChild(el('span', 'mini-summary', task.summary || ''));
  if (state.snoozedIds.has(task.taskId)) mini.appendChild(el('span', 'mini-badge info', 'snoozed'));
  if (task.delegatedTo) mini.appendChild(el('span', 'deleg-badge', `→${task.delegatedTo}`));
  const pick = () => selectIndex(index);
  mini.addEventListener('click', pick);
  mini.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      pick();
    }
  });
  return mini;
}

/**
 * A groupKey bundle (I-201): 「N件まとめ」 + representative summary + an
 * expand toggle listing members + 一括承認 for the whole bundle.
 * Exceptions never join a bundle (they render as full cards at their own
 * position), so bulk here only ever covers ordinary cards.
 */
function renderGroupCard(members, { focused = false } = {}) {
  const first = members[0];
  const card = el('div', 'card group-card' + (focused ? ' kb-focus' : ''));
  const inner = el('div', 'card-inner');

  inner.appendChild(el('div', 'group-count', `${members.length}件まとめ`));
  inner.appendChild(el('div', 'summary', first.summary || ''));
  const agents = [...new Set(members.map((t) => (t.agent && t.agent.name) || 'Agent'))];
  inner.appendChild(el('div', 'group-agents', agents.join(' · ')));
  card.appendChild(inner);

  const key = first.groupKey;
  const open = groupOpen.has(key);
  const toggle = el('button', 'details-toggle group-toggle');
  toggle.type = 'button';
  const label = el('span', 'details-label', open ? '明細を隠す' : '明細を見る');
  const chev = el('span', 'details-chev');
  toggle.append(label, chev);
  toggle.addEventListener('click', () => {
    if (groupOpen.has(key)) groupOpen.delete(key);
    else groupOpen.add(key);
    render();
  });
  card.appendChild(toggle);

  if (open) {
    const list = el('div', 'group-members');
    for (const t of members) {
      const row = el('button', 'group-member');
      row.type = 'button';
      row.appendChild(el('span', 'mini-agent', (t.agent && t.agent.name) || 'Agent'));
      row.appendChild(el('span', 'mini-summary', t.summary || ''));
      row.addEventListener('click', () => openInspect(t));
      list.appendChild(row);
    }
    card.appendChild(list);
  }

  const actions = el('div', 'card-actions');
  const bulk = el('button', 'btn ok', `一括承認 (${members.length}件)`);
  bulk.type = 'button';
  if (state.paused) {
    bulk.disabled = true;
    bulk.classList.add('paused');
    bulk.title = '緊急停止中 — 承認は無効です';
  }
  bulk.addEventListener('click', () => bulkApprove(members));
  actions.appendChild(bulk);
  card.appendChild(actions);
  return card;
}

function renderGroupMini(key, members, index) {
  const mini = el('div', 'mini group-mini' +
    (state.kbActive && state.selected === index ? ' kb-focus' : ''));
  mini.setAttribute('role', 'button');
  mini.tabIndex = 0;
  mini.title = `${members.length}件まとめ — 選択`;
  mini.appendChild(el('span', 'mini-badge group', `${members.length}件`));
  mini.appendChild(el('span', 'mini-summary', members[0].summary || ''));
  const pick = () => selectIndex(index);
  mini.addEventListener('click', pick);
  mini.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      pick();
    }
  });
  return mini;
}

/** Header chips: server snooze count + quiet-hours parked count. */
export function renderChips() {
  const snoozed = document.getElementById('snoozed-chip');
  if (snoozed) {
    const items = state.serverSnoozed;
    if (items.length === 0) {
      snoozed.hidden = true;
    } else {
      snoozed.hidden = false;
      snoozed.textContent = `あとで ${items.length}`;
      const next = items
        .map((s) => Date.parse(s.until))
        .filter((t) => Number.isFinite(t))
        .sort((a, b) => a - b)[0];
      snoozed.title = next
        ? `次は ${snoozeUntilLabel(new Date(next).toISOString())} に再表示`
        : 'サーバーでスヌーズ中';
    }
  }
  const quiet = document.getElementById('quiet-chip');
  if (quiet) {
    const n = parkedCount();
    quiet.hidden = n === 0;
    if (n > 0) {
      quiet.textContent = `おやすみ中 ${n}`;
      quiet.title = `おやすみ時間中は重要でないカードを保留します (${state.quiet.start}〜${state.quiet.end})`;
    }
  }
}

export function render() {
  const stackEl = document.getElementById('stack');
  if (!stackEl) return;
  clear(stackEl);

  const units = visibleUnits();
  if (state.selected >= units.length) state.selected = units.length ? units.length - 1 : 0;
  if (state.selected < 0) state.selected = 0;

  const count = document.getElementById('pending-count');
  if (count) {
    if (visibleStack().length) {
      count.hidden = false;
      setPendingCount(visibleStack().length);
    } else {
      count.hidden = true;
    }
  }
  renderChips();
  renderStampBanner();

  if (!units.length) {
    const empty = el('div', 'empty');
    empty.appendChild(el('div', '', state.fleet ? `${state.fleet} に未処理はありません` : 'すべてのタスクが処理済み'));
    empty.appendChild(el('div', '',
      state.fleet ? '絞り込みを解除すると他のエージェントも表示されます' : '新しい要求が届くとここに表示されます'));
    stackEl.appendChild(empty);
    renderTray();
    renderFleet();
    return;
  }

  const [top, ...rest] = units;
  stackEl.appendChild(renderUnit(top, state.kbActive && state.selected === 0));

  if (rest.length > 0) {
    const queue = el('div', 'queue');
    queue.appendChild(el('div', 'queue-label', `残り ${rest.length} 件`));
    rest.forEach((u, idx) => queue.appendChild(renderUnitMini(u, idx + 1)));
    stackEl.appendChild(queue);
  }

  renderTray();
  renderFleet();
}

function renderUnit(unit, focused) {
  return unit.type === 'group'
    ? renderGroupCard(unit.members, { focused })
    : renderCard(unit.task, { focused });
}

function renderUnitMini(unit, index) {
  return unit.type === 'group'
    ? renderGroupMini(unit.key, unit.members, index)
    : renderMini(unit.task, index);
}
