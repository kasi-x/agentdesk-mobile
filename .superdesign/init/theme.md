# Theme

## Part 1 — Compact token summary

Colors (dark-only, no light theme):
| Token | Value | Use |
|---|---|---|
| `--bg` | `#0a0d13` | page background (+ faint accent radial glow) |
| `--surface` | `#151a24` | cards (gradient #1a2130→surface), sheet |
| `--surface-2` | `#1b212e` | buttons, inputs, diffbox |
| `--surface-3` | `#222a3a` | hover states |
| `--border` | `#293348` | strong borders; `--border-soft` rgba(255,255,255,.07) hairlines |
| `--text` | `#e9edf5` | primary text |
| `--muted` | `#9aa6ba` | secondary text; `--faint #66738a` decorative only |
| `--accent` | `#6b9bff` / `--accent-strong` `#5b8def` | primary accent, focus rings |
| `--accent-dim` | `#3d63b8` | avatar gradient, external-quote border |
| `--green` | `#4ade80` | Approve btn (ink `#052e16`), confidence high, diff-after |
| `--yellow` | `#f5c451` | warning badge, reason chips, countdown soon |
| `--red` | `#ff6b6b` | Reject, critical, countdown urgent/past, diff-before |

Severity/status alpha-tints (bg @ ~0.18, text tinted): info `#9ec0ff`, warning `#f5c451`, critical `#ff5b5b`. Impact badges: no `#ff7b7b`, yes `#6fd3a0`, cost `#ffbf60`.

Typography: system stack — `-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Hiragino Kaku Gothic ProN", "Noto Sans JP", sans-serif`; monospace for inline diff. Scale: 11px (badges/hints) · 12px (meta/labels/chips) · 13px (body-sm/buttons) · 14px (inputs/agent name) · 15px (summary) · 16px (brand/sheet title). Weights 400–700.

Spacing: card padding 16px · card-inner gap 14px · stack padding 20px 16px 40px · component gaps 6–12px.

Radii: card 18px · sheet 20px top · mini 12px · buttons/inputs 9–10px · diffbox 12px · pills 999px.

Shadows: sheet `0 -8px 30px rgba(0,0,0,.5)` · toast `0 4px 16px rgba(0,0,0,.4)` · none on cards (border-defined elevation only).

Motion: card-in fade+rise 0.18s; sheet-in 0.22s cubic-bezier(.2,.8,.2,1); toast-in 0.18s; hover/focus transitions 0.16s; hold-progress 1200ms scaleX; countdown text refresh 5s. All disabled under prefers-reduced-motion.

Breakpoint: ≤480px (tighter padding, buttons wrap 1 1 40%).

## Part 2 — Raw source

### `web/style.css` — `:root` tokens
```css
:root {
  --bg: #0b0e14;
  --surface: #171b24;
  --surface-2: #1d2330;
  --surface-3: #232936;
  --border: #2a3242;
  --text: #e8ecf4;
  --muted: #9aa4b5;
  --accent: #5b8def;
  --accent-dim: #3d63b8;
  --green: #3ddc84;
  --yellow: #f5c451;
  --red: #ff5b5b;
}
```

### Key component styles (excerpt)
```css
body { background: var(--bg); color: var(--text); font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Hiragino Kaku Gothic ProN", "Noto Sans JP", sans-serif; }
.card { width: 100%; max-width: 520px; background: var(--surface); border: 1px solid var(--border); border-radius: 16px; overflow: hidden; }
.card-inner { padding: 16px; display: flex; flex-direction: column; gap: 14px; }
.card-actions { display: flex; gap: 8px; border-top: 1px solid var(--border); padding: 12px; }
.card-actions .btn { flex: 1; }
.btn { appearance: none; border: 1px solid var(--border); background: var(--surface-2); color: var(--text); border-radius: 10px; padding: 8px 14px; font-size: 13px; font-weight: 600; cursor: pointer; }
.btn.ok { background: var(--green); border-color: var(--green); color: #06230f; }
.btn.no { background: transparent; border-color: var(--red); color: var(--red); }
.btn.primary { background: var(--accent); border-color: var(--accent); color: #fff; }
.badge { font-size: 11px; font-weight: 700; border-radius: 999px; padding: 2px 8px; text-transform: uppercase; letter-spacing: 0.04em; }
.diffbox { border: 1px solid var(--border); border-radius: 10px; overflow: hidden; }
.diff-before { color: var(--red); text-decoration: line-through; opacity: 0.85; }
.diff-after { color: var(--green); }
.text-external { border-left: 3px solid var(--accent-dim); background: var(--surface-3); padding: 10px 12px; border-radius: 6px; font-size: 13px; color: var(--muted); font-style: italic; }
.mini { background: var(--surface); border: 1px solid var(--border); border-radius: 12px; padding: 10px 12px; display: flex; align-items: center; gap: 10px; opacity: 0.72; }
```

Full theme source: `web/style.css` (the only stylesheet; icons are inline/mask SVG data-URIs, font Inter via Google Fonts with full system fallback). Flutter mirror: `mobile/lib/ui/theme.dart` — not yet synced with the 2026-10 web refresh.
