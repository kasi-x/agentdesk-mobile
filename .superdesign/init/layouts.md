# Layouts

Single-page app. Full DOM skeleton in `web/index.html`; everything below `#stack` is rendered by `app.js`.

## App shell (`web/index.html` — full source)
```html
<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>AgentDesk Triage</title>
  <link rel="stylesheet" href="/style.css" />
</head>
<body>
  <header id="topbar">
    <div class="brand">
      <span class="brand-name">AgentDesk</span>
      <span id="status-dot" class="dot" title="接続状態"></span>
    </div>
    <span id="pending-count" class="count" hidden></span>
    <button id="settings-toggle" class="btn ghost sm" type="button">⚙ 設定</button>
  </header>

  <section id="settings" class="settings" hidden>
    <label class="field">
      <span>Hub URL</span>
      <input id="hub-input" type="url" placeholder="https://hub.example.com" />
    </label>
    <label class="field">
      <span>Client token</span>
      <input id="token-input" type="password" autocomplete="off" placeholder="dev-client-token" />
    </label>
    <div class="settings-actions">
      <button id="save-settings" class="btn primary" type="button">接続</button>
    </div>
  </section>

  <main id="stack"></main>

  <div id="inspect-sheet" class="sheet" hidden></div>
  <div id="toasts" class="toasts"></div>

  <script src="/app.js"></script>
</body>
</html>
```

## Stack layout (`render()` in `web/app.js:672`)
One focused card at top (max-width 520px, centered), then a "残り N 件" queue of compact `.mini` rows (badge + agent + summary, snoozed marker). Empty state: centered 2-line message.
```js
function render() {
  const stackEl = document.getElementById('stack');
  clear(stackEl);
  const count = document.getElementById('pending-count');
  if (state.stack.length) { count.hidden = false; count.textContent = `${state.stack.length} pending`; }
  else count.hidden = true;

  if (!state.stack.length) {
    const empty = el('div', 'empty');
    empty.appendChild(el('div', '', 'すべてのタスクが処理済み'));
    empty.appendChild(el('div', '', '新しい要求が届くとここに表示されます'));
    stackEl.appendChild(empty);
    return;
  }
  stackEl.appendChild(renderCard(state.stack[0]));
  if (state.stack.length > 1) {
    const queue = el('div', 'queue');
    queue.appendChild(el('div', 'queue-label', `残り ${state.stack.length - 1} 件`));
    for (const t of state.stack.slice(1)) {
      const mini = el('div', 'mini');
      const sev = t.severity === 'critical' ? 'critical' : t.severity === 'warning' ? 'warning' : 'info';
      mini.appendChild(el('span', `mini-badge ${sev}`, sev));
      mini.appendChild(el('span', 'mini-agent', (t.agent && t.agent.name) || 'Agent'));
      mini.appendChild(el('span', 'mini-summary', t.summary || ''));
      if (state.snoozedIds.has(t.taskId)) mini.appendChild(el('span', 'mini-badge info', 'snoozed'));
      queue.appendChild(mini);
    }
    stackEl.appendChild(queue);
  }
}
```

## Overlay layers
- `#inspect-sheet` (`position: fixed; inset: auto 0 0 0;` rounded-top bottom sheet, max-height 82vh, shadow `0 -8px 30px rgba(0,0,0,.5)`).
- `#toasts` fixed bottom-center pill stack.
- `#topbar` sticky, surface background + bottom border.
