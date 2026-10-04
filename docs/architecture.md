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
        │ Web UI (P3)   │◄──SSE──────┤                                   │
        └──────────────┘            │  TaskHub Durable Object (single,  │
        ┌──────────────┐   SSE      │  "global"): task store (DO SQL    │
        │ Mobile Flutter│◄──────────┤  KV), sessions map, sweep alarm   │
        │ card stack    │──────────►│                                   │
        └──────────────┘  POST      └───────────────────────────────────┘
                          /actions
```

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
3. DO CAS: pending + nonce match → `processed`, broadcast
   `dismissTask`, forward to `replyUrl`. Already processed → `409`
   → client shows the “処理済み” toast (FR-3.3).

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

## Known MVP deviations (tracked for Phase 2/3)

- Inspect is tap-only; up-swipe is reserved because flutter_card_swiper
  cannot cancel a committed swipe.
- Snooze is client-local (moves to stack tail); timed re-notification
  is not implemented.
- No APNs/FCM push yet; no Live Activities yet (Phase 3).
- The inspect-sheet catalog is a hand-rolled v0 subset; Phase 2 swaps
  in Google `genui` behind the same renderer interface.
