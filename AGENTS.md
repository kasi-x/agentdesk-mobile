# AgentDesk Mobile

Mobile-first Human-in-the-Loop (HITL) triage UI for autonomous agents.
The user supervises many long-running agents from a phone: a card stack
where every card is an agent request ("Needs Input"), resolved with
one-thumb swipes — approve / reject / snooze / inspect. Optimistic UI,
diff-first information design, A2UI-style declarative dynamic forms
(strictly no code execution on the client).

Three layers:

1. **Agents** (LangGraph, Dify, Claude Code, n8n, custom) POST task cards
   to the hub webhook (`POST /api/v1/tasks`).
2. **Hub** (`backend/`): Cloudflare Workers + one Durable Object
   (`TaskHub`) that owns task state, fans out to SSE clients, and
   enforces one-shot nonces + optimistic locking (double-approve
   protection, FR-3.1/3.3).
3. **Mobile client** (`mobile/`): Flutter app — card stack
   (flutter_card_swiper), SSE client with reconnect + snapshot resync,
   offline action queue, declarative component renderer with safe
   fallback (FR-1.3).

## Commands

### Backend (Cloudflare Workers, TypeScript)

```bash
cd backend
npm install
npm run dev          # wrangler dev on http://127.0.0.1:8787
npm run typecheck    # tsc --noEmit
npm test             # vitest (pure protocol/locking logic)
npm run smoke        # end-to-end smoke test against a running `wrangler dev`
```

Local dev secrets live in `backend/.dev.vars` (git-ignored; copy from
`.dev.vars.example`): `AGENT_TOKEN`, `CLIENT_TOKEN`,
optional `VAPID_PUBLIC_KEY` / `VAPID_PRIVATE_KEY` / `VAPID_SUBJECT`
(Web Push sender; push silently skipped when unset). In production:
`wrangler secret put AGENT_TOKEN` / `wrangler secret put CLIENT_TOKEN`
(/ `VAPID_*`).

### Mock agent (`tools/`)

Dependency-free Node script for local E2E:

```bash
node tools/mock-agent.mjs listen             # prints triage replies (verifies HMAC signature)
node tools/mock-agent.mjs send               # POSTs 3 sample task cards to the hub
node tools/mock-agent.mjs update [taskId]    # replace a pending card (nonce rotates)
node tools/mock-agent.mjs withdraw [taskId]  # retract a pending card
node tools/mock-agent.mjs result <taskId>    # long-poll the decision result
# env: HUB_URL (default http://127.0.0.1:8787), AGENT_TOKEN, CALLBACK_PORT
```

### SDKs (`sdk/`) and MCP server (`tools/mcp-server/`)

- `sdk/typescript/` (zero-dep, node >= 18): `desk.ask(card, {timeout})`
  blocks via `GET /api/v1/tasks/{id}/result?wait=60` until a human
  decides; `desk.update` / `desk.withdraw`, `replyHandler()` verifies
  `X-AgentDesk-Signature`.
- `sdk/python/` (stdlib-only): same API (`Desk.ask/update/withdraw`,
  `verify_signature`). See `docs/sdk.md`.
- `tools/mcp-server/`: dependency-free stdio MCP server exposing
  `agentdesk_ask` / `agentdesk_result` (HUB_URL/AGENT_TOKEN from env).

### Mobile (Flutter)

Flutter SDK is installed (`~/sdk/flutter`, 3.47.x track). Platform
folders `mobile/ios/` + `mobile/android/` are committed and tracked;
only IDE files (`.idea/`, `*.iml`) are excluded. Conventions:

```bash
cd mobile
export PATH=$PATH:~/sdk/flutter/bin
flutter pub get
flutter analyze      # must be clean
flutter test
flutter run
```

Point the app at the hub via the in-app Settings screen (hub URL +
client token, persisted with shared_preferences; dev defaults match
`backend/.dev.vars.example`).

Interfaces for optional hub surfaces stay probe-based (`api is HubApiV2`
→ local fallback; `api is HubRulesApi` → read-only rules sheet), so
the app degrades cleanly against older hubs.

## Directory layout

```
backend/              Cloudflare Worker: webhook + SSE + action endpoints + web assets
  src/index.ts        router, bearer auth, CORS, static-asset fallback
  src/task-hub.ts     Durable Object: task store, SSE sessions, nonce lock
  src/protocol.ts     wire types, validation, pure CAS decision (unit-tested)
  src/protocol.test.ts
  src/webpush.ts      RFC 8291 aes128gcm + VAPID sender (WebCrypto only)
mobile/               Flutter app (card stack UI, SSE, offline queue)
  lib/models/         tolerant JSON parsing of the card payload
  lib/services/       HubApi (+HubApiV2, +HubRulesApi), SseClient, TaskRepository (state + queue)
  lib/ui/             triage stack, card view, component catalog, inspect sheet
  lib/ui/genui_form.dart  genui A2UI adapter for inspect-form rendering
  ios/ android/       committed platform folders (IDE files excluded)
web/                  zero-build browser triage UI (served as Worker assets):
                      native ES modules (app.js = bootstrap; net/store/render/
                      actions/inspect/history/fleet/pause/keyboard/settings/…),
                      sw.js + manifest.webmanifest (PWA), qr.js (pairing encoder)
tools/                mock-agent.mjs (send/listen/update/withdraw/result), mcp-server/
sdk/typescript|python/ agent SDKs (ask/update/withdraw + HMAC verify)
docs/                 requirements (JA), protocol spec, architecture, philosophy, design-philosophy, sdk.md
IDEA.md               idea backlog (I-xxx ids, status)
TODO.md               prioritized plan derived from IDEA.md

## Constraints

- **Worktree protocol**: never edit the main checkout directly — use
  `dev-wt new <branch>` per the global rules.
- **No code execution on clients** (NFR-2.1): agent payloads are pure
  data. No WebView, no HTML/JS rendering, no eval — ever. Unknown
  component types must render as a fallback text card (FR-1.3),
  never crash.
- **External-origin text** (mail bodies, PR comments) renders in the
  quote-block style (`Text` component with `properties.source:
  "external"`), visually separated from system UI text (NFR-2.2).
- **Protocol changes** update `docs/protocol.md`,
  `backend/src/protocol.ts` and `mobile/lib/models/task_card.dart` in
  the same commit.
- **Secrets** never appear in A2UI payloads or the repo; sensitive data
  is fetched by the client with its own short-lived bearer token
  (NFR-2.3).
- **DO concurrency**: rely on Durable Object input gates for the
  read-decide-write cycle in `task-hub.ts`; do not "optimize" the
  storage awaits away (see docs/architecture.md).
- **Ideas → IDEA.md, plans → TODO.md, principles → docs/philosophy.md / design-philosophy.md.**
  New ideas go to `IDEA.md` first (with an `I-xxx` id and status); only
  accepted ones become tasks in `TODO.md`. When a task is done, tick it
  in `TODO.md` and set the idea to `done` in `IDEA.md` in the same commit.
  Feature decisions should be checkable against `docs/philosophy.md` and
  UI decisions against `docs/design-philosophy.md`.
- Update this file in the same commit when introducing a new convention.

## Status / roadmap

- [x] Phase 1 (MVP): card stack (swipe right=approve, left=reject,
      down=snooze, tap=inspect sheet), webhook → DO → SSE pipeline,
      optimistic UI, offline queue, nonce + optimistic lock (409 on
      double submit), remote dismiss broadcast, agent callback delivery.
- [x] Phase 2: genui (`GenUiFormAdapter`, per-component hand-rolled
      fallback) for the inspect sheet, richer Diff (`rows` + `inline`,
      mobile + web), Web triage UI (`web/` static assets on the Worker),
      same-origin browser POST fix (rebuild DO subresponse before cors).
- [ ] Phase 3: iOS Live Activities / Dynamic Island (WidgetKit via
      MethodChannel — Swift evaluated, deferred until a macOS/Xcode host
      exists), multi-device real-time sync polish, push (APNs/FCM).
- [x] Protocol v1 + full TODO sweep: server snooze, update/withdraw,
      reply retry+HMAC, priority sort, groupKey+bulk, pause/resume,
      delegate, 2-party approvals, rules+leases, pairing+user DOs,
      PWA+Web Push, SDKs+MCP, mobile gestures/tray/fleet/choose.

Known MVP deviations from the spec (see docs/architecture.md):
inspect is tap-only (up-swipe reserved so the card does not fly away);
snooze is server-side (synced) with offline local fallback; push
works via Web Push/PWA, APNs/FCM native credentials still pending.
