# Components (vanilla JS render functions)

No component framework. Every "component" is a render function in `web/app.js` that builds DOM via `el(tag, className, text)` (textContent only — payload strings must never be interpreted as markup, NFR-2.1). CSS lives in `web/style.css`.

## el() — DOM helper (all components use it)
Source: `web/app.js:64`
```js
function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined && text !== null) node.textContent = String(text);
  return node;
}
```

## TriageCard (`renderCard`)
Source: `web/app.js:494` — the main card. Composition order: countdown strip (I-203, only when `expiresAt`) → header (avatar / agent name / time-ago / severity badge) → impact row (「承認すると…」 + reversible/cost badges, I-202) → confidence bar + reason chips → summary → A2UI components (`renderComponent`) → actions row (Reject / Inspect / Approve; locked cards swap Approve for a hold-to-confirm ring).
```js
function renderCard(task) {
  const card = el('div', 'card');
  const inner = el('div', 'card-inner');

  if (typeof task.expiresAt === 'string' && task.expiresAt) {
    const strip = el('div', 'countdown');
    strip.dataset.expires = task.expiresAt;
    strip.dataset.onexpire = task.onExpire || 'drop';
    updateCountdown(strip);
    inner.appendChild(strip);
  }

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
  const agentCol = el('div', 'card-agent');
  agentCol.appendChild(el('div', 'agent-name', agent.name || 'Agent'));
  agentCol.appendChild(el('div', 'card-meta', timeAgo(task.createdAt)));
  header.appendChild(agentCol);
  const sev = task.severity === 'critical' ? 'critical' : task.severity === 'warning' ? 'warning' : 'info';
  header.appendChild(el('span', `badge ${sev}`, sev));
  inner.appendChild(header);

  const impact = task.impact;
  if (impact && typeof impact === 'object') {
    const row = el('div', 'impact-row');
    if (typeof impact.summary === 'string' && impact.summary) {
      row.appendChild(el('span', 'impact-text', `承認すると ${impact.summary}`));
    }
    const impactBadge = (text, cls) => row.appendChild(el('span', `impact-badge ${cls}`, text));
    if (impact.reversible === false) impactBadge('取り消し不可', 'no');
    else if (impact.reversible === true) impactBadge('取り消し可', 'yes');
    if (impact.cost && typeof impact.cost === 'object' &&
        typeof impact.cost.amount === 'number' && impact.cost.currency) {
      impactBadge(`${impact.cost.currency} ${impact.cost.amount}`, 'cost');
    }
    inner.appendChild(row);
  }

  if (typeof task.confidence === 'number') {
    const conf = el('div', 'confidence');
    const pct = Math.round(Math.min(1, Math.max(0, task.confidence)) * 100);
    conf.appendChild(el('span', 'confidence-label', `Confidence: ${pct}%`));
    const bar = el('div', 'confidence-bar');
    const fill = el('div', `confidence-fill ${confidenceClass(task.confidence)}`);
    fill.style.width = `${pct}%`;
    bar.appendChild(fill);
    conf.appendChild(bar);
    inner.appendChild(conf);
    const reasons = Array.isArray(task.confidenceReasons) ? task.confidenceReasons : [];
    if (task.confidence < 0.9 && reasons.length) {
      const rs = el('div', 'reasons');
      for (const r of reasons) rs.appendChild(el('span', 'reason-chip', r));
      inner.appendChild(rs);
    }
  }

  inner.appendChild(el('div', 'summary', task.summary || ''));
  for (const comp of orderedComponents(task)) inner.appendChild(renderComponent(comp, task));
  card.appendChild(inner);

  const actions = el('div', 'card-actions');
  const right = task.actions && task.actions.onSwipeRight;
  const left = task.actions && task.actions.onSwipeLeft;
  const approve = el('button', 'btn ok', `✓ ${(right && right.label) || 'Approve'}`);
  approve.type = 'button';
  approve.addEventListener('click', () =>
    triage(task, { actionName: (right && right.actionName) || 'approve', data: right && right.payload, source: 'web_ui' }),
  );
  // … reject (with optional inline reason chips I-118) / hold-to-confirm (locked) / Inspect / Snooze buttons
  const inspect = el('button', 'btn primary', 'Inspect');
  const snz = el('button', 'btn dim', 'Snooze');
  actions.append(reject, inspect, snz);
  card.appendChild(actions);
  return card;
}
```

## A2UI component renderer (`renderComponent`)
Source: `web/app.js:392` — maps protocol components to DOM. `Text` (variants caption/body/title; `source: "external"` adds the `.text-external` quote block, NFR-2.2), `DiffBox` (highlight bar info/warning/critical + before/after rows + optional `rows[]` + optional `inline` unified diff with +/− coloring), `Chips` (action chips; no `actionName` → openInspect), default → `.fallback` card (FR-1.3).
```js
function renderComponent(comp, task) {
  const box = el('div', 'comp');
  switch (comp.component) {
    case 'Text': {
      const p = comp.properties || {};
      const variant = p.variant === 'title' ? 'title' : p.variant === 'body' ? 'body' : 'caption';
      const t = el('div', `text-${variant}`, p.text || '');
      if (p.source === 'external') t.classList.add('text-external');
      box.appendChild(t);
      return box;
    }
    case 'DiffBox': {
      const p = comp.properties || {};
      const wrap = el('div', 'diffbox');
      const hl = p.highlight === 'warning' ? 'warning' : p.highlight === 'critical' ? 'critical' : 'info';
      wrap.appendChild(el('div', `diffbox-highlight ${hl}`));
      const addPair = (parent, label, before, after) => {
        const row = el('div', 'diffbox-row');
        if (label) row.appendChild(el('div', 'diffbox-title', label));
        else if (p.title && parent === wrap) row.appendChild(el('div', 'diffbox-title', p.title));
        row.appendChild(el('div', 'diff-before', before || ''));
        row.appendChild(el('div', 'diff-after', `→ ${after || ''}`));
        parent.appendChild(row);
      };
      addPair(wrap, null, p.before, p.after);
      if (Array.isArray(p.rows)) for (const r of p.rows) { if (r && typeof r === 'object') addPair(wrap, r.label || null, r.before, r.after); }
      if (typeof p.inline === 'string' && p.inline) {
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
      for (const opt of (Array.isArray(p.options) ? p.options : [])) {
        const chip = el('button', 'chip', (opt && opt.label) || '?');
        chip.type = 'button';
        chip.addEventListener('click', () => {
          if (opt && opt.actionName) triage(task, { actionName: opt.actionName, data: opt.payload, source: 'quick_chip' });
          else openInspect(task);
        });
        wrap.appendChild(chip);
      }
      box.appendChild(wrap);
      return box;
    }
    default: {
      const f = el('div', 'fallback');
      f.appendChild(el('div', 'fallback-label', `${comp.component || 'unknown'} — 未対応コンポーネント`));
      f.appendChild(el('div', 'fallback-text', JSON.stringify(comp.properties || {})));
      box.appendChild(f);
      return box;
    }
  }
}
```

## Countdown strip text (`countdownParts` / `updateCountdown`)
Source: `web/app.js:467` — `残り Xm · 期限で自動承認|自動却下|緊急化|破棄`; classes `soon` (≤30m), `urgent` (≤5m), `past`. Refreshed text-only every 5s.
```js
function countdownParts(expiresAt, onExpire) {
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
```

## Hold-to-confirm approve (locked cards, I-102/I-103)
Source: `web/app.js:622` — `.btn.ok.hold`; pointerdown appends `.hold-progress` span animated scaleX 0→1 over 1200ms; early release cancels; success triages with `source: 'hold_confirm'`.

## Reject reason chips (I-118)
Source: `web/app.js:597` — clicking Reject hides it and expands `.reason-chips` (agent-supplied `rejectReasons` + 「理由なし」); 4s timeout auto-rejects without a reason; chosen id goes out as `data.reason`.

## Toast
Source: `web/app.js:75` — pill toast in fixed `#toasts` bottom-center; optional 「元に戻す」 action button (undo, I-104).
```js
function toast(message, { undoTaskId } = {}) {
  const t = el('div', 'toast', message);
  if (undoTaskId) {
    const btn = el('button', 'toast-undo', '元に戻す');
    btn.type = 'button';
    btn.onclick = () => { t.remove(); undo(undoTaskId); };
    t.appendChild(btn);
  }
  document.getElementById('toasts').appendChild(t);
  setTimeout(() => t.remove(), undoTaskId ? 5000 : TOAST_MS);
}
```

## Inspect sheet form fields (`renderInspect`)
Source: `web/app.js:724` — bottom sheet: title → card components → dynamic form (`TimePicker` → input[type=time], `DatePicker` → input[type=date], `Slider` → range + live value, `Segmented` → pill buttons, `TextField` → input/textarea, unknown → fallback) → actions 「キャンセル」「修正して承認」 (values merged over `onSwipeRight.payload`, `source: 'inspect_form'`).
