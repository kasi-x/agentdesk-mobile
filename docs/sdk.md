# AgentDesk SDK — agent-side integration

How an agent posts a card, waits for the human decision, and verifies the
signed reply callback. Three equivalent clients ship in this repo:

| Language | Location | Dependencies |
|---|---|---|
| TypeScript / JavaScript (ESM) | [`sdk/typescript/`](../sdk/typescript/) | none (Node >= 18 `fetch`) |
| Python | [`sdk/python/agentdesk.py`](../sdk/python/) | stdlib only (`urllib`, `hmac`, `json`) |
| MCP server (stdio) | [`tools/mcp-server/`](../tools/mcp-server/) | none (Node >= 18) |

All three implement the wire contract in [`docs/protocol.md`](protocol.md):
`POST /api/v1/tasks`, the agent result long-poll, `update` / `withdraw`, and
the `X-AgentDesk-Signature` callback HMAC.

## The happy path

```text
agent                                  hub (TaskHub DO)                human
  │  POST /api/v1/tasks ────────────────▶ enqueue, nonce, broadcast      │
  │◀─ 201 {taskId, nonce, …}             │                               │
  │  GET …/result?wait=60 ──────────────▶ (hold up to 60s) ──── swipe ───▶│
  │◀─ {status:"approved", action:{…}} ───│                               │
  │  …                                              POST replyUrl ◀──────│ (after undo grace)
```

`ask()` = enqueue + long-poll loop. `update()` re-broadcasts a revised card
(rotated nonce); `withdraw()` cancels it.

## TypeScript / JavaScript

```js
import { createClient } from "@agentdesk/sdk"; // or "./sdk/typescript/index.mjs"

const desk = createClient({ hubUrl: process.env.HUB_URL, agentToken: process.env.AGENT_TOKEN });

const { actionName, data, source } = await desk.ask(card, { timeout: 600_000 });
// actionName: "approve" | "reject" | whatever the binding declared
// data:       the binding payload merged with any inspect-form values
// source:     "swipe_gesture" | "quick_chip" | "inspect_form" | "hold_confirm" | "web_ui" | "on_expire"

await desk.update(taskId, { ...fullReplacementCard });
await desk.withdraw(taskId);
```

`ask()` resolves with `{ taskId, status, actionName, data, source, action, delivery }`.
`status` is the terminal outcome: `approved` / `rejected` / `withdrawn` / `expired`.

## Python

```python
import os
from agentdesk import Desk

desk = Desk(os.environ["HUB_URL"], os.environ["AGENT_TOKEN"])
decision = desk.ask(card, timeout=600)   # seconds
print(decision["actionName"], decision["data"], decision["source"])

desk.update(task_id, full_replacement_card)
desk.withdraw(task_id)
```

`desk.result(task_id, wait=60)` exposes the raw long-poll. `DeskError` carries
`.status` / `.code` (e.g. `409 duplicate_task`, `409 bad_nonce`);
`DeskTimeoutError` is raised when `ask()`'s budget elapses.

## MCP server

```jsonc
// claude_desktop_config.json
{ "mcpServers": { "agentdesk": {
  "command": "node",
  "args": ["/abs/path/tools/mcp-server/server.mjs"],
  "env": { "HUB_URL": "https://desk.example.com", "AGENT_TOKEN": "…" }
} } }
```

Tools: `agentdesk_ask({summary, severity?, components?, replyUrl?})` (blocks
until decided) and `agentdesk_result({taskId})` (non-blocking poll). See
[`tools/mcp-server/README.md`](../tools/mcp-server/README.md).

## Long-poll semantics (`GET /api/v1/tasks/{id}/result`)

Auth: `Authorization: Bearer $AGENT_TOKEN`. Query `?wait=<seconds>`
(long-poll) — **maximum 60 s per request**; the hub holds the connection until
the task is terminal or the wait elapses, then returns the current state:

```json
{
  "taskId": "task_98234",
  "status": "approved",
  "action": { "name": "approve", "data": { "decision": "ACCEPT" }, "source": "swipe_gesture", "at": "2026-10-04T09:52:11Z" },
  "delivery": { "attempts": 1, "failed": false }
}
```

- Terminal statuses: `approved`, `rejected`, `withdrawn`, `expired`. Anything
  else (`pending`, `committing`) means "still waiting" — poll again.
- `action` is absent until a decision exists. `data` is the binding payload
  merged with inspect-form values; `source` records who decided.
- `delivery` reports the `replyUrl` delivery state (attempts / `failed` /
  `lastError`) once the hub has tried.
- String values use the same conventions as the rest of the protocol: treat
  everything as display-only text and compare `actionName`, not `label`.

**Retry policy (client side).** The SDK loops `?wait=60` until its own
`timeout` budget is exhausted. `wait` is capped server-side at 60 s; a
misbehaving client cannot ask for longer. On network errors, retry the GET with
exponential backoff (1s → 2s → … → 30s cap). A long wait never consumes the
decision: the result stays available after `ask()` times out, so calling
`result(taskId)` later still returns it. `ask()` keeps every intermediate poll
inside its budget: it computes `wait = min(60, remaining)` so it never overshoots
the caller's timeout by more than one round trip.

## Update and withdraw (agent endpoints)

| Method | Path | Body | Effect |
|---|---|---|---|
| `POST` | `/api/v1/tasks/{id}/update` | full replacement card | rotates the nonce, broadcasts `createTaskCard` with `revised: true` |
| `POST` | `/api/v1/tasks/{id}/withdraw` | — | broadcasts `withdrawTask {taskId}`, task ends as `withdrawn` |

Both require the agent token and only apply to a **pending** task. `update()`
rotates the nonce, so any client that still holds the old card must take the
new one from the `createTaskCard` broadcast (replace in place). After a terminal
decision both return a conflict — the decision is final.

## Reply delivery and signature verification

When a card carries `replyUrl`, the hub POSTs the decision JSON (same shape as
the action reply in `docs/protocol.md`) to it **after the undo grace window**,
retrying with exponential backoff (1s→2s→4s→8s→16s, max 5 attempts). Every
attempt is signed:

```
X-AgentDesk-Signature: t=1730794321,v1=<hex>
X-AgentDesk-Event: triage_reply
Content-Type: application/json
```

- `t` — unix seconds when the request was sent.
- `v1` — lowercase hex `HMAC-SHA256(secret, "<t>.<raw body>")`.
- secret — env `REPLY_SIGNING_SECRET`, falling back to `AGENT_TOKEN`.
- `X-AgentDesk-Event` — `triage_reply` (human decision) or `expire` (deadline).

**Verify over the raw body.** Buffer the exact bytes the hub sent and compute
the HMAC over `"<t>." + rawBody`. Re-serializing parsed JSON changes the bytes
and will fail.

```js
// Node — Express-free
const replies = desk.replyHandler(); // secret: AGENTDESK_SECRET → REPLY_SIGNING_SECRET → AGENT_TOKEN
const { event, reply } = replies.handle(req.headers, rawBody); // throws DeskError on mismatch
```

```python
# Python
from agentdesk import verify_signature
if not verify_signature(headers, raw_body, SECRET, max_skew=300):
    return 401
```

Rules for both verifiers:

1. Compare in constant time (`crypto.timingSafeEqual` / `hmac.compare_digest`).
2. Reject when `t` is missing, `v1` is missing, or the secret is empty.
3. `max_skew` is **opt-in** (ms in JS, seconds in Python) for replay protection;
   enable it when your clock is reliable. The hub retries up to 5 times, so
   allow a window comfortably larger than the backoff (~16 s + RTT) if you use it.
4. `handle()` / the SDK also parse the JSON, but only after the signature
   passes; treat the body as untrusted until then.

Final delivery failure is recorded on the hub (`StoredTask.delivery.failed`) and
surfaced to clients via `deliveryFailed` SSE + `/state`, so a human can see the
agent never received the answer.

## Environment summary

| Variable | Used by | Meaning |
|---|---|---|
| `HUB_URL` | all | hub origin (default `http://127.0.0.1:8787`) |
| `AGENT_TOKEN` | all | agent bearer token |
| `AGENTDESK_SECRET` | TS SDK | preferred callback secret |
| `REPLY_SIGNING_SECRET` | hub + SDK fallback | callback signing secret |
| `AGENTDESK_AGENT_NAME` | MCP | agent name printed on cards |
| `AGENTDESK_MCP_TIMEOUT_MS` | MCP | default `ask` budget (ms) |
