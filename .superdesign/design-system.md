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

## Visual language — "color-pop" (2026-10, user-approved direction)

Reference: bold color-coded task cards on warm dark chrome with pill UI.

- **The card surface IS the severity**: lime gradient `#D6EC86→#C2DF5F` = info,
  amber `#F7D452→#EFBA2F` = warning, coral `#F4695C→#E94A3D` = critical.
  Near-black ink text (`#1B1E16`) on the card; chrome stays warm dark
  (`#191B16` bg, `#23251F` surfaces).
- White pills (`rgba(255,255,255,.93)`) carry content components (DiffBox,
  external quotes); dark pills (`rgba(20,22,16,.92)`) carry actions with
  lime/coral icon accents; amber `#F5C842` is the CTA (pending pill,
  Inspect, 修正して承認, segmented selection).
- Urgent countdown flips to a white pill with red text; soon = white pill
  with dark amber.
- Inter + Hiragino/Noto Sans JP; tabular-nums for all numeric meta;
  uppercase tracked micro-labels.
- Radii: 24px cards, 24px sheet top, 999px pills. Max content width 540px.
- Motion (meaning-serving, reduced-motion-safe): **Animate UI motion DNA**
  translated to CSS — sampled framer spring (stiffness 200 / damping 20) as a
  `linear()` easing token, blur reveal (blur 10→0) on cards/toasts with 40ms
  per-element stagger, shine sweep (skewX -15°) on the amber CTA, counting
  number tween on the pending pill, press `scale(.96)`, urgent pulse,
  connected-dot breathing.
- Flutter mirror: `mobile/lib/ui/colors.dart` (PopColors) + `theme.dart`.

## Motion patterns allowed

- Entrance: subtle fade/rise ≤200ms for cards/toasts. Never delay interaction.
- Feedback: countdown urgency color shifts; hold-ring progress; connection dot.
- Prohibited: parallax, large bouncy springs, decorative particles, autoplaying video.

## Project requirements

- Japanese UI copy; keep existing labels (承認すると…, 取り消し不可, 修正して承認, 元に戻す, 残り N 件…).
- Must stay implementable in plain CSS (no Tailwind/build step) and in Flutter Material 3 (tokens shared with `mobile/lib/ui/theme.dart`).
- Single-column, max-width 520px; must work at ≤480px and on desktop.
- Density: power users triage dozens of cards — avoid airy marketing spacing, but keep breathing room between the card sections.
