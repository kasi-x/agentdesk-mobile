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
`.dev.vars.example`): `AGENT_TOKEN`, `CLIENT_TOKEN`. In production:
`wrangler secret put AGENT_TOKEN` / `wrangler secret put CLIENT_TOKEN`.

### Mock agent (`tools/`)

Dependency-free Node script for local E2E (Phase 1 verification:
"swipe decisions reach the agent callback URL"):

```bash
node tools/mock-agent.mjs listen   # prints triage replies delivered back to the agent
node tools/mock-agent.mjs send     # POSTs 3 sample task cards to the hub
# env: HUB_URL (default http://127.0.0.1:8787), AGENT_TOKEN, CALLBACK_PORT
```

### Mobile (Flutter)

No Flutter SDK was available when this project was scaffolded. After
installing Flutter (>= 3.5), bootstrap the platform folders once:

```bash
cd mobile
flutter create --platforms=ios,android --org dev.agentdesk .
flutter pub get
flutter analyze
flutter test
flutter run
```

Point the app at the hub via the in-app Settings screen (hub URL +
client token, persisted with shared_preferences; dev defaults match
`backend/.dev.vars.example`).

## Directory layout

```
backend/              Cloudflare Worker: webhook + SSE + action endpoints + web assets
  src/index.ts        router, bearer auth, CORS, static-asset fallback
  src/task-hub.ts     Durable Object: task store, SSE sessions, nonce lock
  src/protocol.ts     wire types, validation, pure CAS decision (unit-tested)
  src/protocol.test.ts
mobile/               Flutter app (card stack UI, SSE, offline queue)
  lib/models/         tolerant JSON parsing of the card payload
  lib/services/       HubApi, SseClient, TaskRepository (state + queue)
  lib/ui/             triage stack, card view, component catalog, inspect sheet
  lib/ui/genui_form.dart  genui A2UI adapter for inspect-form rendering
web/                  zero-build browser triage UI (served as Worker assets)
tools/                mock-agent.mjs (send / listen) for local E2E
docs/                 requirements (JA), protocol spec, architecture, philosophy
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
- **Ideas → IDEA.md, plans → TODO.md, principles → docs/philosophy.md.**
  New ideas go to `IDEA.md` first (with an `I-xxx` id and status); only
  accepted ones become tasks in `TODO.md`. When a task is done, tick it
  in `TODO.md` and set the idea to `done` in `IDEA.md` in the same commit.
  Feature decisions should be checkable against `docs/philosophy.md`;
  changing a principle requires updating its revision log.
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

Known MVP deviations from the spec (see docs/architecture.md):
inspect is tap-only (up-swipe reserved so the card does not fly away);
snooze is client-local; push notifications (APNs/FCM) are not wired yet.
