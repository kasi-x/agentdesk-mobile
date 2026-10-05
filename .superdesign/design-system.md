# AgentDesk — Design System

## Product context

AgentDesk Mobile is a mobile-first Human-in-the-Loop triage interface for supervising autonomous agents. The user's mental model: **a deck of cards, one decision at a time** — right = approve, left = reject, down = snooze, tap = inspect & modify. The web UI (`web/`) is the desktop sibling of the Flutter mobile app: same tokens, same information design, keyboard instead of thumb.

Job to be done: "移動中やスキマ時間に、エージェントの判断待ちを素早く安全に捌きたい" — process a queue of agent requests in seconds each, without reading long logs, without ever double-executing a dangerous action.

Key surfaces (single page): focused TriageCard + queue of mini rows + inspect bottom sheet + toasts. Sample content is Japanese; agents send DiffBox diffs, confidence, impact statements, expiry countdowns.

## Non-negotiable design principles (docs/philosophy.md — hard constraints)

1. **Diff-first**: the card front answers「承認したら何が起きるか」in 0.5s. Diffs (red before / green after) and impact line outrank any prose. Thinking logs go behind Inspect.
2. **Weight ∝ risk**: friction is a tool — irreversible/critical cards must feel heavier (locked state, hold-to-confirm). Never make dangerous actions merely colorful.
3. **Confidence is a number, not a vibe**: ≥0.9 green ("swipe without reading") → <0.6 red, with reason tags when low.
4. **Calm chrome**: the stack carries the color; the shell stays quiet. No dashboards, no timelines, no gamification, no notification spam aesthetics.
5. **Countdown = display only**: expiry strip shows what the hub will do (自動承認/自動却下/緊急化/破棄) and must always read as "automatic", never as a fake human decision.
6. **No code rendering**: every payload string is text (NFR-2.1); external-origin text sits in the italic quote block, visually separated from system UI (NFR-2.2).

## Visual language — "calm iOS" (2026-10, current direction)

Apple-minimal per user feedback (「本当に必要な情報をミニマルに出す」):
the front carries only what the decision needs, one level deeper holds
the context.

- **Neutral elevated cards** on true-black (`#0A0A0B` bg, `#1C1C1E`
  card, `#2C2C2E` inset lists) — severity is a single 7px dot
  (blue/orange/red), not a colored surface.
- iOS system grays for text hierarchy: label `#FFFFFF`,
  secondaryLabel `rgba(235,235,245,.6)`, tertiaryLabel `.3`;
  fills `rgba(120,120,128,.24/.36)`; separator `rgba(84,84,88,.65)`.
- Accent = systemBlue `#0A84FF`; semantic green `#30D158` /
  red `#FF453A` / orange `#FF9F0A` only where meaning demands.
- System font (-apple-system/SF, no webfont); headline 17px w600
  tracking -0.02em; body 15px leading ~1.5; tabular-nums everywhere
  numbers move.
- Front layout: agent+dot+time (quiet row) → summary headline →
  承認すると… line (result first, P3) → value-aware diff (calendar /
  money chips + day timeline) → quiet meta (信頼度 · deadline, colored
  only when it matters) → 詳細を見る toggle → actions (却下/Inspect/後で
  gray-tinted + 承認 full-width tinted row; locked = red hold).
- 詳細を見る expands an inset grouped list downward (grid-rows 0fr→1fr,
  critically damped): なぜ / 誰が / 参加者(status dots) / 出典(link) /
  金額 / 注意点 / 期限 — the TaskContext block.
- Translucent materials: topbar/sheet/toast `backdrop-filter: blur()`
  with content scrolling under; vibrancy = heavier weight + contrast on
  translucent surfaces; scroll-edge hairlines only where chrome floats.
- Motion: critically damped springs `cubic-bezier(.32,.72,0,1)`
  (damping 1.0, response ~0.35s — Apple default); feedback on
  pointer-down (`:active scale(.97)`); bounce only where momentum
  exists (mobile swiper). prefers-reduced-motion / reduced-transparency
  / contrast:more all respected.

## Motion patterns allowed

- Entrance: subtle fade/rise ≤200ms for cards/toasts. Never delay interaction.
- Feedback: countdown urgency color shifts; hold-ring progress; connection dot.
- Prohibited: parallax, large bouncy springs, decorative particles, autoplaying video.

## Project requirements

- Japanese UI copy; keep existing labels (承認すると…, 取り消し不可, 修正して承認, 元に戻す, 残り N 件…).
- Must stay implementable in plain CSS (no Tailwind/build step) and in Flutter Material 3 (tokens shared with `mobile/lib/ui/theme.dart`).
- Single-column, max-width 520px; must work at ≤480px and on desktop.
- Density: power users triage dozens of cards — avoid airy marketing spacing, but keep breathing room between the card sections.
