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

## Visual language (current baseline to respect or deliberately evolve)

- Dark, near-black blue-charcoal page (`#0b0e14`), card surfaces `#171b24`, hairline borders `#2a3242` — elevation comes from borders and one soft sheet shadow, not heavy drop shadows.
- Accent `#5b8def` (info/primary), semantic green `#3ddc84` / yellow `#f5c451` / red `#ff5b5b` with ~0.12–0.18 alpha tint backgrounds for badges/strips.
- System font stack incl. Hiragino/Noto Sans JP; scale 11–16px; weights 400/600/700.
- Radii: 16px cards, 18px sheet top, 999px pills. Max content width 520px.
- Motion: minimal — toast slide, 0.2s dot transition, hold-progress fill. 0ms-optimistic feel; nothing bouncy.

## Motion patterns allowed

- Entrance: subtle fade/rise ≤200ms for cards/toasts. Never delay interaction.
- Feedback: countdown urgency color shifts; hold-ring progress; connection dot.
- Prohibited: parallax, large bouncy springs, decorative particles, autoplaying video.

## Project requirements

- Japanese UI copy; keep existing labels (承認すると…, 取り消し不可, 修正して承認, 元に戻す, 残り N 件…).
- Must stay implementable in plain CSS (no Tailwind/build step) and in Flutter Material 3 (tokens shared with `mobile/lib/ui/theme.dart`).
- Single-column, max-width 520px; must work at ≤480px and on desktop.
- Density: power users triage dozens of cards — avoid airy marketing spacing, but keep breathing room between the card sections.
