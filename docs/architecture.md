# Architecture

```
┌─────────────────┐   POST /api/v1/tasks (Bearer AGENT_TOKEN)
│  Agents          │──────────────────────────────────────┐
│  LangGraph /     │                 ┌────────────────────▼──────────────┐
│  Dify / Claude   │                 │  Hub — Cloudflare Workers          │
│  Code / n8n      │◄────────────────│  POST /tasks    → validate, fill   │
└─────────────────┘   POST replyUrl │                  taskId/nonce     │
   (agent callback)  (triage reply) │  GET  /stream   → SSE fan-out     │
                                    │  POST /actions  → nonce CAS lock  │
        ┌──────────────┐            │  GET  /state    → snapshot        │
        │ Web UI (P2)   │◄──SSE──────┤  (same Worker, `web/` assets)    │
        └──────────────┘            │                                   │
        ┌──────────────┐   SSE      │  TaskHub Durable Object (single,  │
        │ Mobile Flutter│◄──────────┤  "global"): task store (DO SQL    │
        │ card stack    │──────────►│  KV), sessions map, sweep alarm   │
        └──────────────┘  POST      └───────────────────────────────────┘
                          /actions

## Why a single Durable Object

All tasks and all live SSE sessions funnel through one `TaskHub`
instance (name `"global"`):

- **One source of truth** for pending/processed state — the mobile app,
  the future web UI and APNs/FCM workers all see identical state.
- **Cheap atomicity**: Durable Object *input gates* guarantee that while
  a handler is awaiting storage I/O, no other event is delivered to the
  same object. The read→decide→write cycle in
  `backend/src/task-hub.ts` (`storage.get` → status check →
  `storage.put`) is therefore race-free without an explicit
  transaction. **Do not** interleave non-storage awaits between the
  read and the write.
- Storage keys: `task:<taskId>` → `StoredTask {task, status, nonce,
  createdAt, processedAt?, processedBy?}`. Processed tasks are kept for
  1h (so late duplicate actions get `409 already_processed` instead of
  `404`) and purged by the storage alarm.

## Flows

### Enqueue
1. Agent POSTs the TaskCard payload (docs/protocol.md).
2. Router validates (`src/protocol.ts`), fills `taskId`/`nonce`/
   `createdAt` if absent, forwards to the DO.
3. DO rejects a *pending* duplicate `taskId` (`409 duplicate_task`),
   persists, broadcasts `createTaskCard` to every session.
   Push (APNs/FCM) hooks in here in Phase 3.

### Triage (optimistic UI)
1. User swipes → the client completes the 0ms animation and removes the
   card from the stack immediately (FR-2.1); the reply (7.2 payload) is
   POSTed asynchronously (FR-2.2).
2. If POST fails with a network error / 5xx, the reply is persisted to
   the on-device queue (shared_preferences) and flushed on SSE
   reconnect / app start (FR-2.3). Tasks whose ids sit in the offline
   queue are excluded from snapshot reconciliation so a queued decision
   is not resurrected.
3. DO CAS: pending + nonce match → `committing` (undo grace, I-104),
   broadcast `dismissTask`, forward to `replyUrl` when the commit alarm
   fires. Already decided → `409` → client shows the “処理済み” toast
   (FR-3.3).

### Expiry (I-203)
Cards with `expiresAt` join the unified DO alarm's deadline set. When a
deadline passes, the hub runs the card's `onExpire` default behavior and
records it as automatic: approve/reject execute the declared swipe
binding immediately (no undo grace — nobody is present), drop finishes
the task with an `expire/EXPIRED` reply to `replyUrl`, escalate
re-broadcasts the card (severity critical, rotated nonce) and clients
replace it in place. Full semantics: docs/protocol.md.

### Reconnect / cold start
SSE (re)connect always receives a `snapshot` of pending tasks first;
the client rebuilds the stack from it (locally-snoozed ids move to the
bottom). `GET /api/v1/state` exists for the 500ms cold-start budget
(NFR-1.2): render the cached/snapshotted stack before SSE connects.

## Client-side state (mobile)

`TaskRepository` (ChangeNotifier) owns: `stack` (newest first, snoozed
at the tail), `snoozedIds`, `offlineQueue` (persisted), `connected`.
The component catalog (`lib/ui/widgets/component_renderer.dart`) maps
protocol components to native widgets; unknown ids fall back to a
generic text card (FR-1.3). All rendering is plain Flutter widgets fed
by parsed data — no WebView/eval anywhere (NFR-2.1).

## Security

- Two bearer-token realms: `AGENT_TOKEN` (agents → hub) and
  `CLIENT_TOKEN` (clients → hub). Long-lived, rotated via wrangler
  secrets in production; per-device short-lived tokens + per-endpoint
  data fetch (NFR-2.3) land with Phase 2.
- External-origin text must be sent by agents as `Text` components with
  `properties.source = "external"` and renders in the quote-block style
  (NFR-2.2). Agents must never embed credentials in payloads.

## Phase 2 status (done)

- Web triage UI: `web/` (zero-build static assets on the same Worker) —
  SSE + snapshot, optimistic triage, offline queue, inspect sheet.
- Inspect sheet: genui (`package:genui` A2UI engine, `mobile/lib/ui/genui_form.dart`)
  renders the 5 form types; the hand-rolled catalog stays as per-component
  fallback (FR-1.3). DiffBox gains `rows` + `inline` (§protocol catalog v0).
- Same-origin browser POST fix: the Worker rebuilds the DO subresponse
  before `cors()` header mutation (`backend/src/index.ts`) — immutable
  subresponse headers surfaced browser POSTs as 500.

## Known MVP deviations (tracked for Phase 3)

- Inspect is tap-only; up-swipe is reserved because flutter_card_swiper
  cannot cancel a committed swipe.
- Snooze is client-local (moves to stack tail); timed re-notification
  is not implemented.
- No APNs/FCM push yet; no Live Activities yet (Phase 3).
