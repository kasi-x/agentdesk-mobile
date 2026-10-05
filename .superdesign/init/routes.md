# Routes

Single route, no router, no build step.

| URL path | Entry | Layout | Renders |
|---|---|---|---|
| `/` (any path — Worker serves assets) | `web/index.html` → `web/app.js` → `web/style.css` | topbar + settings panel + `#stack` | Triage stack: 1 focused card + queue of mini rows; bottom sheet inspect; toasts |

State comes from the hub over SSE (`/api/v1/stream`) + `/api/v1/state` snapshot; no URL-driven state.
