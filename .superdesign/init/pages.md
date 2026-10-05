# Pages

Single page. Full dependency "tree" (vanilla JS — script tags, no imports):

## `/` (Triage)
Entry: `web/index.html`
Dependencies:
- web/app.js
  - DOM render: `el()`, `toast()`, `render()` → `renderCard()` → `countdownParts()/updateCountdown()`, `renderComponent()`, hold-to-confirm, reject reason chips
  - inspect sheet: `openInspect()/renderInspect()` (dynamic form catalog)
  - data: SSE `connect()`, `fetchState()`, `postAction()`, `postUndo()`, `flushQueue()`, `undo()`, `triage()`, `snooze()`, keyboard shortcuts (←/→/i/s)
- web/style.css (all styling)

No other pages. Settings panel is an inline collapsible section, not a route.
