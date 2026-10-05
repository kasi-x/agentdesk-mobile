# Init — AgentDesk Mobile (web triage UI)

- Framework: **none** — zero-build vanilla JS single page (`web/index.html` + `web/style.css` + `web/app.js`), served as Cloudflare Worker static assets.
- Component library: none; all UI is hand-rolled DOM via `el()` helper (textContent-only, NFR-2.1).
- CSS approach: single vanilla stylesheet with CSS custom properties (`:root`). No Tailwind, no PostCSS.
- Companion Flutter app (`mobile/`) mirrors the same tokens in `mobile/lib/ui/theme.dart`; the web UI is the renderable design surface.
- Page language: Japanese UI copy, dark theme, desktop-first with a ≤480px breakpoint.

Former defects (fixed 2026-10 in feat/ui-polish — do not reintroduce):
- stray `[SCOPE]` token that killed the `.field` settings styles — removed.
- duplicate `.chip` block with hardcoded colors — unified to tokens.
