# AgentDesk Hub — Wire Protocol v0

Authoritative spec for all traffic between agents, the hub (Cloudflare
Worker + `TaskHub` Durable Object) and triage clients (mobile Flutter,
future web UI). When this file changes, update `backend/src/protocol.ts`
and `mobile/lib/models/task_card.dart` in the same commit.

Payloads are **pure data** (A2UI-style, flat adjacent list). Clients must
treat every string as display-only text: no HTML, no JS, no WebView
(NFR-2.1). Unknown component types render as a fallback text card
(FR-1.3) — adding a component type is therefore backward compatible.

## Endpoints

| Method | Path | Auth | Caller | Purpose |
|---|---|---|---|---|
| POST | `/api/v1/tasks` | `Authorization: Bearer $AGENT_TOKEN` | agent | enqueue a task card |
| GET | `/api/v1/stream` | Bearer `$CLIENT_TOKEN` (or `?token=` for EventSource) | client | SSE event stream |
| GET | `/api/v1/state` | Bearer `$CLIENT_TOKEN` | client | snapshot of pending tasks (cold-start priming, NFR-1.2) |
| POST | `/api/v1/actions` | Bearer `$CLIENT_TOKEN` | client | deliver a triage decision (7.2 payload) |
| GET | `/healthz` | none | ops | liveness |

Errors: `401` bad/missing token · `400` invalid payload (message says why)
· `404` `task_not_found` · `409` `already_processed` / `bad_nonce` /
`duplicate_task`. CORS: `ALLOWED_ORIGINS` env (comma-separated, `*` for dev).

## SSE events (`GET /api/v1/stream`)

```
event: snapshot        data: {"tasks":[TaskCard,...]}   (oldest→newest; sent on every (re)connect)
event: createTaskCard  data: TaskCard
event: dismissTask     data: {"taskId":"…","by":"swipe_gesture"}   (FR-3.2: remove from every device)
: ping                                                  (heartbeat comment every 15s)
```

Reconnect policy (client): exponential backoff 1s→30s; on reconnect the
fresh `snapshot` reconciles the stack, so no Last-Event-ID replay is
needed in v0.

## TaskCard (hub ⇐ agent, hub ⇒ clients)

Agents POST this to `/api/v1/tasks`. `taskId`, `nonce`, `createdAt` are
filled in by the hub when absent.

```json
{
  "type": "createTaskCard",
  "taskId": "task_98234",
  "nonce": "tok_sec_abc123",
  "agent": { "name": "Calendar & Meeting Agent", "avatarUrl": "https://assets.example.com/calendar-bot.png" },
  "confidence": 0.94,
  "confidenceReasons": [],
  "severity": "info",
  "summary": "ミーティングの日程変更リクエスト",
  "surfaceId": "card_surface_98234",
  "createdAt": "2026-10-04T09:50:00Z",
  "replyUrl": "https://agent.example.com/callback/task_98234",
  "components": [
    { "id": "root_card", "component": "TriageCard", "children": ["diff_view", "reasoning_text"] },
    {
      "id": "diff_view", "component": "DiffBox",
      "properties": {
        "title": "定例ミーティング時間",
        "before": "2026-10-05 14:00", "after": "2026-10-05 16:30",
        "highlight": "warning"
      }
    },
    {
      "id": "reasoning_text", "component": "Text",
      "properties": {
        "text": "参加者3名中2名が14:00に重複予定があるため、全員が空いている16:30への変更を提案します。",
        "variant": "caption"
      }
    },
    {
      "id": "quick_options", "component": "Chips",
      "properties": { "options": [
        { "label": "別の日程を提案" },
        { "label": "このまま承認", "actionName": "approve", "payload": { "decision": "ACCEPT" } }
      ] }
    }
  ],
  "actions": {
    "onSwipeRight": { "actionName": "approve", "payload": { "decision": "ACCEPT", "newTime": "2026-10-05 16:30" } },
    "onSwipeLeft":  { "actionName": "reject",  "payload": { "decision": "DECLINE" } },
    "inspectForm": [
      { "id": "time_picker", "component": "TimePicker", "properties": { "label": "別の時間を指定", "default": "16:30" } }
    ]
  }
}
```

Field notes:

| Field | Req | Notes |
|---|---|---|
| `taskId` | hub fills | unique; re-POST of a *pending* taskId → `409 duplicate_task` |
| `nonce` | hub fills | one-shot token; consumed by the first accepted action (FR-3.1) |
| `confidence` | opt | 0.0–1.0; drives the indicator colors (≥0.9 green … <0.6 red) |
| `confidenceReasons` | opt | tags shown when confidence is low (“要確認” reasons, §3.2) |
| `severity` | opt | `info` / `warning` / `critical` header badge |
| `replyUrl` | opt | https URL; the hub POSTs the 7.2 reply here after a decision |
| `components` | req | adjacent list; render order = `TriageCard.children`, else array order |
| `actions.inspectForm` | opt | bottom-sheet form components (§3.3) |

## Component catalog v0

Card surface: `TriageCard` (root shell), `Text` (`variant`: `caption` |
`body` | `title`; `source: "external"` renders the quote-block style
required by NFR-2.2), `DiffBox` (`before` red / `after` green,
`highlight`: `info` | `warning` | `critical`), `Chips`
(`options[].label`, optional `actionName`+`payload` — tap sends that
action with `source: "quick_chip"`, options without `actionName` open
the inspect sheet).

Inspect-form catalog: `TimePicker`, `DatePicker`, `Slider`
(`min`/`max`/`default`/`divisions`), `Segmented` (`options`),
`TextField` (`label`, `multiline`).

On submit the sheet collects `{ componentId: value }` for every form
component, merges the `onSwipeRight.payload` underneath, and sends
`actionName: "approve"` with `source: "inspect_form"`.

## Action reply (client ⇒ hub, hub ⇒ `replyUrl`)

```json
{
  "taskId": "task_98234",
  "nonce": "tok_sec_abc123",
  "actionName": "approve",
  "timestamp": "2026-10-04T09:52:11Z",
  "source": "swipe_gesture",
  "data": { "decision": "ACCEPT", "newTime": "2026-10-05 16:30" }
}
```

`source` ∈ `swipe_gesture` | `quick_chip` | `inspect_form` |
`lock_screen` (Phase 3) | `web_ui` | `snooze_local`.

Hub semantics (FR-3.3): the first accepted action flips the task to
`processed` and consumes the nonce; concurrent duplicates get
`409 {"error":"already_processed"}` and clients show a “処理済み” toast.
A wrong nonce → `409 bad_nonce`. Unknown task → `404`. Accepted actions
are broadcast as `dismissTask` to all connected devices and forwarded to
`replyUrl` when present.
