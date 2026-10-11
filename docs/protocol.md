# AgentDesk Hub — Wire Protocol v1

Authoritative spec for all traffic between agents, the hub (Cloudflare
Worker + `TaskHub` Durable Object) and triage clients (mobile Flutter,
future web UI). When this file changes, update `backend/src/protocol.ts`
and `mobile/lib/models/task_card.dart` in the same commit.

**Version (I-606):** every card carries `protocolVersion`, and `1` is
current (`PROTOCOL_VERSION` in `backend/src/protocol.ts`). v0 payloads
carry no field at all — the hub reads them as `1`, so old producers keep
working unchanged. The `snapshot` event and `GET /state` envelope also
carry `protocolVersion` so a client can detect a server it does not
understand. Additive fields (`groupKey`, `decisionKind`, `editable`,
`priority`, `revised`, `requiredApprovals`, `choices`, `delegatedTo`,
`actions.onSwipeDown`, `paused`, `rules`, `approvalProgress`,
`Rule.action`, `Rule.source`, `RuleMatch.minConfidence`,
`ActionReply.learnRule`) do not bump
the version; clients must tolerate unknown ones.

Payloads are **pure data** (A2UI-style, flat adjacent list). Clients must
treat every string as display-only text: no HTML, no JS, no WebView
(NFR-2.1). Unknown component types render as a fallback text card
(FR-1.3) — adding a component type is therefore backward compatible.

## Endpoints

| Method | Path | Auth | Caller | Purpose |
|---|---|---|---|---|
| POST | `/api/v1/tasks` | `Authorization: Bearer $AGENT_TOKEN` | agent | enqueue a task card |
| POST | `/api/v1/tasks/{id}/update` | Bearer `$AGENT_TOKEN` | agent | replace a pending card, rotating its nonce (I-204) |
| POST | `/api/v1/tasks/{id}/withdraw` | Bearer `$AGENT_TOKEN` | agent | cancel a pending card everywhere (I-205) |
| GET | `/api/v1/tasks/{id}/result?wait=<sec>` | Bearer `$AGENT_TOKEN` | agent | resolve the outcome, long-polling up to 60s (I-901) |
| GET | `/api/v1/stream` | Bearer `$CLIENT_TOKEN` (or `?token=` for EventSource) | client | SSE event stream |
| GET | `/api/v1/state` | Bearer `$CLIENT_TOKEN` | client | snapshot: tasks + snoozed + delivery + paused + rules + approvalProgress |
| POST | `/api/v1/actions` | Bearer `$CLIENT_TOKEN` | client | triage decision, snooze, delegation or partial approval (7.2 payload) |
| POST | `/api/v1/actions/bulk` | Bearer `$CLIENT_TOKEN` | client | deliver many triage decisions, each CASed independently (I-201) |
| POST | `/api/v1/actions/undo` | Bearer `$CLIENT_TOKEN` | client | revert a decision still inside the undo grace window (I-104) |
| POST | `/api/v1/pause` | Bearer `$CLIENT_TOKEN` | client | pause the fleet (I-403) |
| POST | `/api/v1/resume` | Bearer `$CLIENT_TOKEN` | client | resume the fleet (I-403) |
| GET/PUT | `/api/v1/rules` | Bearer `$CLIENT_TOKEN` | client | read / replace auto-approval/-rejection rules (I-304/I-807/I-1002) |
| POST | `/api/v1/pair` | Bearer `$CLIENT_TOKEN` | client | mint a one-time pairing code (I-808) |
| POST | `/api/v1/pair/redeem` | none (the code is the credential) | client | redeem a code into a device token (I-808) |
| POST/DELETE | `/api/v1/push/subscribe` | Bearer `$CLIENT_TOKEN` | client | register / remove a Web Push subscription (I-701) |
| GET | `/api/v1/push/vapid` | Bearer `$CLIENT_TOKEN` | client | VAPID public key for subscriptions (I-701) |
| POST/DELETE | `/api/v1/push/native` | Bearer `$CLIENT_TOKEN` | client | register / remove a native APNs/FCM token (I-701 follow-up) |
| POST | `/api/v1/rules/simulate` | Bearer `$CLIENT_TOKEN` | client | dry-run rules (+ optional candidate) over recent cards (I-1002) |
| POST | `/api/v1/attachments` | Bearer `$CLIENT_TOKEN` | client | upload a small audio/image blob (I-1001) |
| GET | `/api/v1/attachments/{id}` | Bearer `$CLIENT_TOKEN` **or** `$AGENT_TOKEN` | client/agent | download the raw bytes (I-1001) |
| GET | `/healthz` | none | ops | liveness |

Client auth accepts the shared `$CLIENT_TOKEN` **or any issued device
token** (`dev_…`, I-808/I-809). A device token binds a `user` and routes
that request to the per-user Durable Object (`user:<user>`);
`$CLIENT_TOKEN` routes to the shared `global` DO. Unknown tokens → `401`.

Errors: `401` bad/missing token · `400` invalid payload (message says why)
· `404` `task_not_found` / `invalid_code` · `409` `already_processed` /
`bad_nonce` / `duplicate_task` / `too_late`. CORS: `ALLOWED_ORIGINS` env
(comma-separated, `*` for dev).

## SSE events (`GET /api/v1/stream`)

```
event: snapshot        data: {"protocolVersion":1,"tasks":[TaskCard,...],"snoozed":[...],"delivery":[...],"paused":false,"rules":[...],"approvalProgress":{}}
event: createTaskCard  data: TaskCard   (a taskId the client already holds means: replace in place — I-203 escalate / I-204 update / I-501 delegate / I-502 partial approval)
event: dismissTask     data: {"taskId":"…","by":"swipe_gesture"}   (FR-3.2: remove from every device)
event: withdrawTask    data: {"taskId":"…"}                        (I-205: the agent cancelled the card)
event: deliveryFailed  data: {"taskId":"…","lastError":"HTTP 500"} (I-604: replyUrl retries exhausted)
event: pauseState      data: {"paused":true,"until":"…"} / {"paused":false}   (I-403: fleet pause; `until` omitted = indefinite)
event: delegateTask    data: {"taskId":"…","to":"alice"}           (I-501: the card moved to a colleague; the revised card also arrives as `createTaskCard`)
event: approvalProgress data: {"taskId":"…","count":1,"required":2}  (I-502: a partial approval landed; the card keeps waiting)
event: ruleChanged     data: {"rules":[…]}                         (I-807: the rule set was replaced)
: ping                                                  (heartbeat comment every 15s)
```

`snapshot` (also `GET /api/v1/state`) is the reconnect resync envelope:

| Field | Notes |
|---|---|
| `protocolVersion` | wire version of the hub (currently `1`) |
| `tasks` | pending, **non-snoozed** cards, ordered priority desc / createdAt asc (I-206) |
| `snoozed` | `[{taskId, until}]` — hidden by a server-side snooze until `until` |
| `delivery` | `[{taskId, lastError?, attempts}]` — terminal replyUrl failures (I-604) |
| `paused` | fleet pause flag (I-403); advisory — agents SHOULD stop starting new work while true |
| `rules` | current auto-approval rules (I-304/I-807) |
| `approvalProgress` | `{taskId: count}` — partial approvals recorded so far for `requiredApprovals > 1` cards (I-502) |

`dismissTask.by` is the action `source` (`swipe_gesture`, `web_ui`,
`on_expire`, `auto_rule`, …) or the hub-side values `snooze` / `withdraw`;
a snooze dismissal also carries `snoozedUntil` (ISO 8601).

Reconnect policy (client): exponential backoff 1s→30s; on reconnect the
fresh `snapshot` reconciles the stack, so no Last-Event-ID replay is
needed in v1.

## TaskCard (hub ⇐ agent, hub ⇒ clients)

Agents POST this to `/api/v1/tasks`. `taskId`, `nonce`, `createdAt` are
filled in by the hub when absent; `priority`, `revised` and (on
delegation) `delegatedTo` are added by the hub (agents never send them).

```json
{
  "type": "createTaskCard",
  "taskId": "task_98234",
  "nonce": "tok_sec_abc123",
  "protocolVersion": 1,
  "agent": { "name": "Calendar & Meeting Agent", "avatarUrl": "https://assets.example.com/calendar-bot.png" },
  "confidence": 0.94,
  "confidenceReasons": [],
  "severity": "info",
  "summary": "ミーティングの日程変更リクエスト",
  "surfaceId": "card_surface_98234",
  "createdAt": "2026-10-04T09:50:00Z",
  "replyUrl": "https://agent.example.com/callback/task_98234",
  "groupKey": "calendar_meeting",
  "decisionKind": "approve",
  "editable": { "componentId": "time_picker", "kind": "datetime" },
  "priority": 68.6,
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
    "onSwipeRight": { "actionName": "approve", "label": "16:30 に変更する", "payload": { "decision": "ACCEPT", "newTime": "2026-10-05 16:30" } },
    "onSwipeLeft":  { "actionName": "reject", "label": "却下", "payload": { "decision": "DECLINE" } },
    "inspectForm": [
      { "id": "time_picker", "component": "TimePicker", "properties": { "label": "別の時間を指定", "default": "16:30" } }
    ]
  },
  "impact": {
    "summary": "定例ミーティングを 16:30 に変更して全員に通知します",
    "reversible": true,
    "cost": { "amount": 0, "currency": "JPY" },
    "scope": "参加者 3 名"
  }
}
```

Field notes:

| Field | Req | Notes |
|---|---|---|
| `taskId` | hub fills | unique; re-POST of a *pending* taskId → `409 duplicate_task` |
| `nonce` | hub fills | one-shot token; consumed by the first accepted action (FR-3.1) |
| `protocolVersion` | opt | positive integer; absent = v0, read as `1` (I-606). Malformed → `400` |
| `confidence` | opt | 0.0–1.0; drives the indicator colors (≥0.9 green … <0.6 red) |
| `confidenceReasons` | opt | tags shown when confidence is low (“要確認” reasons, §3.2) |
| `severity` | opt | `info` / `warning` / `critical` header badge |
| `replyUrl` | opt | https URL; the hub POSTs the 7.2 reply here after a decision |
| `components` | req | adjacent list; render order = `TriageCard.children`, else array order |
| `actions.onSwipeDown` | opt | fourth swipe binding (I-111). Choose cards bind it to the second option; approve cards keep down = snooze client-side |
| `actions.inspectForm` | opt | bottom-sheet form components (§3.3) |
| `actions.rejectReasons` | opt | `[{id, label}]` reject reason chips (I-118). The chosen id arrives as `data.reason` on the reply; no choice = reject without a reason. Malformed entries are dropped, non-array is `400` |
| `context` | opt | structured 裏面 (back-of-card) context for the details panel — see below |
| `expiresAt` | opt | ISO 8601 deadline; the hub runs `onExpire` at it (I-203, see below) |
| `onExpire` | opt | `approve` \| `reject` \| `escalate` \| `drop` (default `drop`); requires `expiresAt` |
| `groupKey` | opt | non-empty string; cards sharing it are a bundle (I-201). Non-string/empty → `400` |
| `decisionKind` | opt | `approve` \| `choose` \| `fill` (default `approve`); unknown value → `400`. `choose` requires `choices` ≥ 2 **and** both `actions.onSwipeUp` / `actions.onSwipeDown` |
| `editable` | opt | `{componentId, kind: "number"\|"datetime", min?, max?, step?}` — inline value editing hint (I-114). `componentId` required; bad kinds/values → `400` |
| `requiredApprovals` | opt | integer ≥ 1, default `1` (I-502). The card commits only after this many distinct approvals; anything else → `400` |
| `choices` | opt | `[{id, label}]` options for `decisionKind: "choose"` (I-111). Each entry needs non-empty string `id` + `label`; otherwise `400` |
| `delegatedTo` | hub adds | colleague the card was delegated to (I-501); agents never send it |
| `priority` | hub adds | urgency score (higher = more urgent); never sent by agents — see below |
| `revised` | hub adds | `true` on a `createTaskCard` re-broadcast after an agent update (I-204) or a delegation (I-501) |

## Component catalog

Card surface: `TriageCard` (root shell), `Text` (`variant`: `caption` |
`body` | `title`; `source: "external"` renders the quote-block style
required by NFR-2.2), `DiffBox` (`title`, `before` red / `after` green,
`highlight`: `info` | `warning` | `critical`; optional `rows` — list of
`{label?, before?, after?}` multi-row changes rendered after the main
pair; optional `duration` — event length in minutes for the day-timeline
visualization of datetime diffs (default 60); optional `inline` —
unified-diff style string with `+`/`-`/space
line prefixes, clients color added green / removed red / context dim,
rendered as plain text never markup), `Chips`
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
`lock_screen` (Phase 3) | `web_ui` | `snooze_local` | `hold_confirm`
(I-103 hold-to-confirm ring on locked cards) | `snooze` (server-side
snooze) | `two_stage_swipe` (I-101) | `bulk` (I-201 bulk triage) |
`delegate` (I-501 delegation) | `auto_rule` (I-304/I-807 hub
auto-approval) | `pause` (I-403).

Hub semantics (FR-3.3): the first accepted action flips the task to
`committing` (see below) and consumes the nonce; concurrent duplicates get
`409 {"error":"already_processed"}` and clients show a “処理済み” toast.
A wrong nonce → `409 bad_nonce`. Unknown task → `404`. Accepted actions
are broadcast as `dismissTask` to all connected devices and forwarded to
`replyUrl` after the undo grace window closes.
`learnRule: true` on an approve/reject also stores a `"learned"` rule
(I-1003, see §自動承認ルール).

### 返信 `data` の素通し項目

`data` はハブが検証せず `replyUrl` へ素通しする。クライアントが送って
よい予約キー:

| Key | 送り元 | Notes |
|---|---|---|
| `choice` | 二択カード (I-111) | 選んだ `choices[].id`。`onSwipeUp.payload` / `onSwipeDown.payload` にマージして送る |
| `acceptedRows` | 行選択 (I-112) | 承認した DiffBox 行の id 配列。行に文字列 `id` がなければ index を文字列化したもの |
| `edited` | 値調整 (I-114) | `{componentId, value}` — インスペクト前にその場で変えた値 |
| `proposeAutomation` | 二段スワイプ (I-101) | `true` — 「承認＋自動化を提案」 |
| `muteSimilar` | 却下チップ | `true` — このエージェントの同種提案をミュート |

### サーバー側スヌーズ

`POST /api/v1/actions` は決定の代わりにスヌーズも受け付ける:

```json
{ "taskId": "task_98234", "nonce": "tok_sec_abc123", "action": "snooze", "until": "2026-10-05T09:00:00Z" }
```

`until` は必須の ISO 8601 で、最大 7 日先まで（それ以外は `400`）。
スヌーズは `pending` のカードにだけ効き（それ以外は `409`）、**nonce は
消費しない** — 再浮上するまで同じ nonce が有効。ハブは
`200 {ok, taskId, snoozedUntil}` を返し、
`dismissTask {taskId, by: "snooze", snoozedUntil}` を配信して全端末から
即座に隠す。スヌーズ中のタスクは `tasks` から外れ、`snapshot` /
`/state` の `snoozed` に現れる。

`snoozedUntil` になると DO alarm がカードを再浮上させる: スヌーズを
解除し、**nonce を作り直し**、`createTaskCard` を再配信する（同一
taskId は差し替え）。スヌーズ中は `expiresAt` の期限判定を行わず、
再浮上後に評価する。

### 委任 (I-501)

カードを同僚に回す。決定ではないので nonce は消費しない:

```json
{ "taskId": "task_98234", "nonce": "tok_sec_abc123", "action": "delegate", "data": { "to": "alice" } }
```

`data.to` は必須の非空文字列（なければ `400`）。ハブは
`task.delegatedTo` に `to` を記録し、`pending` のまま
`createTaskCard`（`revised: true`）と
`delegateTask {taskId, to}` を配信する。応答は
`200 {ok, taskId, delegatedTo}`。`bulk` の項目としても送れる
（`{taskId, nonce, action: "delegate", data: {to}}`）。

### 二人承認 (I-502)

`requiredApprovals: N`（N ≥ 1、既定 1）のカードは N 人の承認が揃うまで
確定しない。最初の N−1 件は `pending` のまま記録され、**nonce は作り直し**
（同じ端末の二重承認を防ぐ）、
`approvalProgress {taskId, count, required}` と差し替えた
`createTaskCard` が配信される。応答は
`200 {ok, taskId, approvalProgress: {count, required}}`。
N 件目はいつものコミット経路（`committing` → `commitAt` → `processed`）
を通る。記録は `approvals: [{source, at}]`。

スナップショットの `approvalProgress`（`{taskId: count}`）で途中経過が
見える。却下・スヌーズ・委任は人数に関係なく即座に効く。

### 一括承認（I-201）

`POST /api/v1/actions/bulk` は複数の決定を 1 リクエストで適用する:

```json
{ "actions": [
  { "taskId": "task_a", "nonce": "tok_a", "action": "approve", "source": "web_ui" },
  { "taskId": "task_b", "nonce": "tok_b", "action": "reject",  "source": "web_ui", "data": { "reason": "wrong_amount" } }
] }
```

各項目は `/api/v1/actions` の 1 件分とまったく同じ形に正規化され
（`action` は `actionName`、`source` の既定は `bulk`）、**独立に CAS**
される。1 件の失敗が他を巻き戻すことはない。`delegate` の項目
（`{…, action: "delegate", data: {to}}`）も受け付ける。応答は常に `200`:

```json
{ "results": [
  { "taskId": "task_a", "ok": true, "commitAt": 1760000000000 },
  { "taskId": "task_b", "error": "bad_nonce" }
] }
```

エンベロープが不正（非配列 / 空 / 項目に `taskId`・`nonce`・`action` の
いずれか欠落）なら `400`。

### Task lifecycle and undo grace (I-104)

```
pending ──action──▶ committing ──commitAt──▶ processed ──PROCESSED_TTL──▶ deleted
   ▲                  │
   └─── undo ─────────┘   (processed + committing reject further actions
                          and undos with 409)
```

An accepted `/api/v1/actions` reply flips the task to `committing` and
returns `commitAt` (wall ms). `dismissTask` broadcasts immediately — the
card leaves every device — but the reply is only forwarded to `replyUrl`
when the DO alarm fires at `commitAt`. The grace window defaults to
`UNDO_GRACE_MS` = 5000 ms (env `UNDO_GRACE_MS` overrides).

`POST /api/v1/actions/undo {taskId, nonce}` reuses the same one-shot
nonce that authorized the action. On success (`200 {ok, taskId, nonce}`)
the task returns to `pending`, the nonce is **rotated**, and the card is
re-broadcast as `createTaskCard`; clients must use the new nonce for any
further triage of that task. `409 too_late` once `processed` (or if the
task was never committing); `409 bad_nonce` / `404` as usual. A second
action inside the grace window still gets `409 already_processed`.

### Context: the back of the card (P1/P3)

```json
{
  "context": {
    "requester": { "name": "Bさん", "onBehalfOf": "プロジェクトリード" },
    "participants": [ { "name": "Aさん", "status": "busy 14:00" }, { "name": "自分", "status": "free" } ],
    "reasoning": "参加者3名中2名が14:00に重複予定があるため…",
    "source": { "label": "Gmail —「会議日程変更のお願い」", "url": "https://mail.example.com/…" }
  }
}
```

All fields optional; the card is valid without `context`. Clients render
it in the 詳細を見る expansion (common path first, context one level
deeper — P1: judgment only on the front). Malformed pieces are **dropped
by validation, never rejected** (advisory display data, same rule as
`impact`). `source.url` / `requester.avatarUrl` must be http(s) —
anything else is dropped, so a payload can never produce a
`javascript:` link. Status strings are free-form; clients color dots by
convention (`free` → green, `busy`/重複 → red, else neutral).

### Expiry: `expiresAt` / `onExpire` (I-203)

Agents may attach a deadline to a card:

```json
{ "expiresAt": "2026-10-04T18:00:00Z", "onExpire": "approve" }
```

| Field | Req | Notes |
|---|---|---|
| `expiresAt` | opt | ISO 8601 instant; malformed dates are `400` |
| `onExpire` | opt | `approve` \| `reject` \| `escalate` \| `drop`; requires `expiresAt`; defaults to the safe `drop` |

At the deadline the hub's unified DO alarm runs the default behavior and
records it as **automatic** (anti-goal: the agent must never be able to
forge a human decision):

- `approve` / `reject` — the corresponding swipe binding
  (`onSwipeRight` / `onSwipeLeft`) is executed immediately, **without**
  the undo grace window (nobody is present to trigger an undo). The
  reply reaches `replyUrl` with `source: "on_expire"` and the binding's
  own `actionName`/`payload`. A missing binding degrades to `drop`.
- `drop` — the task finishes unanswered; agents still learn via a
  `replyUrl` delivery of `{"actionName":"expire","source":"on_expire",
  "data":{"decision":"EXPIRED"}}`.
- `escalate` — the card keeps waiting but is re-broadcast as
  `createTaskCard` with `severity: "critical"` and a **rotated nonce**;
  the deadline is consumed. Clients must treat a `createTaskCard` for a
  taskId they already hold as a **replace in place** (the hub is the
  single source of truth, P9).

Every finished expiry (approve / reject / drop) is broadcast as
`dismissTask {taskId, by: "on_expire"}` — clients show a
「期限のため自動処理されました」 toast. Clients render a countdown strip
from `expiresAt` + `onExpire`; it is display-only — the hub decides.

### カードの更新と取り下げ（I-204 / I-205）

エージェントは待っている間に状況が変わったらカードを差し替え、不要に
なったら取り下げられる。

```
POST /api/v1/tasks/{id}/update     Authorization: Bearer $AGENT_TOKEN
body = 完全な置換カード（TaskCard と同じ形）

POST /api/v1/tasks/{id}/withdraw   Authorization: Bearer $AGENT_TOKEN
body なし
```

- **update** は `pending` のカードだけを対象に、フルカードを再検証して
  **nonce を作り直し**（`tok_…`）、`createTaskCard` を `revised: true` 付きで
  再配信する。古い nonce での承認は `409 bad_nonce`。応答は
  `200 {ok, taskId, nonce}`（新しい nonce）。スヌーズ中でも更新は再浮上
  させる（エージェントが明示的に変更したため）。`processed` / `committing`
  は `409 already_processed`。
- **withdraw** は `pending` のカードを `processed`（`processedBy:
  "withdrawn"`）にし、全端末へ `withdrawTask {taskId}` を配信して消す
  （`dismissTask {taskId, by: "withdraw"}` も併せて配信するので、
  dismissTask しか扱わないクライアントも同じように消せる。両者は taskId
  で冪等）。応答は `200 {ok, taskId}`。既に処理済みなら `409
  already_processed`。

どちらもカード ID はパスから取る。SDK の `GET …/result` では withdraw は
`action.name: "withdraw"` として見える。

### replyUrl への返送: 再試行と HMAC 署名（I-604 / I-801）

返信はまず `replyUrl` へ 1 回 POST する。失敗（ネットワーク例外 or 非 2xx）
したら DO alarm で**指数バックオフ再試行**する:

```
試行 1 → 失敗 → +1s → 試行 2 → 失敗 → +2s → 試行 3 → 失敗 → +4s
      → 試行 4 → 失敗 → +8s → 試行 5 → 失敗 → 諦め（上限 16s、最大 5 試行）
```

- 送信ヘッダ（`REPLY_SIGNING_SECRET`、未設定なら `AGENT_TOKEN` にフォール
  バック。どちらも無ければ署名なし）:
  - `X-AgentDesk-Signature: t=<unix秒>,v1=<HMAC-SHA256(secret, "<t>.<body>") の hex>`
  - `X-AgentDesk-Event: triage_reply | expire`（`expire` は自動 drop の返信）
- 成功したら試行状態を消す。5 回とも失敗したら `StoredTask.delivery:
  {attempts, lastError, failed: true}` を記録し、SSE `deliveryFailed
  {taskId, lastError}` を配信、`/state` の `delivery` 一覧にも出す。
- `GET /api/v1/tasks/{id}/result` の `delivery` にも `{attempts, lastError,
  failed?}` が入る。

モックエージェントの `listen` は受信時に署名を検証し、`🔐 signature
verified` / `🚨 signature MISMATCH` を表示する。

### 優先度スコアと並び順（I-123 / I-206）

ハブは enqueue / update 時に各カードの `priority`（数値、大きいほど緊急）を
計算し、`snapshot` / `/state` / `createTaskCard` に添える。`snapshot` の
`tasks` と `/state` は **priority 降順・createdAt 昇順**で返る。

```
priority = 重大度ベース（info 10 / notice 20 / warning 40 / critical 80）
         + 期限の近さ（残り ≤1h: +50, ≤6h: +30, ≤24h: +10）
         + (1 − confidence) × 10
         + 待ち時間ボーナス（10 分ごとに +1、上限 +20）
```

`confidence` 欠落は 0.5、`severity` 欠落は `info` として計算する。待ち時間は
カードの enqueue 時刻を基準にする（エージェント申告の `createdAt` ではない）。
優先度は表示用のヒューリスティックで、`status` や決定順を強制するものでは
ない（クライアントは並び順に使う）。

### まとめカードと一括承認（I-201）

同じ `groupKey` を持つカードはクライアントが 1 枚のまとめカードに束ね、
件数・代表例を出す。束の一括処理は `POST /api/v1/actions/bulk`
（上記参照）で行う。ハブ側は `groupKey` を保存・中継するだけで束ね方は
表示側の裁量（P3: 判断は前面だけ）。

### カード結果のロングポーリング（I-901）

SDK は `GET /api/v1/tasks/{id}/result?wait=<sec>` で結果を待てる
（`Authorization: Bearer $AGENT_TOKEN`）。

```json
{
  "taskId": "task_98234",
  "status": "processed",
  "protocolVersion": 1,
  "action": { "name": "approve", "data": { "decision": "ACCEPT" }, "source": "swipe_gesture", "at": "2026-10-04T09:52:11Z" },
  "delivery": { "attempts": 1 }
}
```

- `status` ∈ `pending` | `committing` | `processed`。終端は `processed`。
- `wait>0` は終端に達するか `wait` 秒（上限 60）経過までロングポーリングする。
  `wait=0` は即時スナップショット。未知の taskId は `404`。
- `action` は確定した決定（`committing` 中は受領済みの返信、`processed` 後は
  記録済みの `outcome`）。`withdraw` は `name: "withdraw"` として現れる。
- `delivery` は返送リトライの状態（I-604）。まだ送信前なら省略。

### 緊急停止（I-403）

運用者がフリート全体を止める。**勧告的**な停止で、新規 enqueue は受け付け
続ける — エージェントは停止を知って自発的に新しい行動を止める（SDK が
既定実装を持つ）。

```
POST /api/v1/pause    Authorization: Bearer $CLIENT_TOKEN
body = {} または { "until": "2026-10-05T09:00:00Z" }

POST /api/v1/resume   Authorization: Bearer $CLIENT_TOKEN
body なし
```

- **pause** は `pauseState {paused: true, until?}` を配信し、
  `200 {ok, paused: true, until?}` を返す。`until` は任意の ISO 8601
  （不正なら `400`）；過ぎたら停止は自動で解けた扱い（`state.paused` は
  false に戻る）。
- **resume** は停止を解除し、`pauseState {paused: false}` を配信する。
  応答は `200 {ok, paused: false}`。
- 停止中も `snapshot` / `/state` の `paused` が true になり、エージェントは
  SSE・`/state`・`result` 経由で停止を知る。エージェントは停止中、新しい
  行動（enqueue 済みカードの実行を含む）を開始すべきではない
  （`SHOULD NOT start`）。

### 自動承認ルールと権限リース（I-304 / I-807 / I-602）

同じパターンの承認が続いたら、クライアントは「今後は自動承認しますか?」
と提案できる（I-304）。ルールはハブが持ち、コードで管理する（I-807）。
リース（I-602）はルールの自己制限 — 「このエージェントに今日だけ $50
まで」の期限・上限・対象を指定し、範囲内のカードだけ自動承認する。
ガードレール（I-1002）で `action: "reject"` の自動拒否ルールと
`minConfidence` 下限も指定できる。

```
GET /api/v1/rules    Authorization: Bearer $CLIENT_TOKEN
→ 200 {rules: [...]}

PUT /api/v1/rules    Authorization: Bearer $CLIENT_TOKEN
body = { "rules": [ Rule, … ] }
→ 200 {ok: true, rules: [...]}（+ ruleChanged {rules} を配信）
```

```json
{
  "id": "cheap-calendar",
  "match": { "agent": "Calendar", "severity": ["info", "warning"], "maxCost": 50, "minConfidence": 0.7 },
  "lease": { "until": "2026-10-06T00:00:00Z", "maxCount": 20 },
  "enabled": true,
  "action": "approve",
  "source": "manual"
}
```

| Field | Notes |
|---|---|
| `id` | 必須の非空文字列。運用で一意にすること（一致判定は先勝ち） |
| `match.agent` | `agent.name` の部分一致 |
| `match.severity` | 許容 severity 配列（空/省略 = すべて） |
| `match.maxCost` | `impact.cost.amount` の上限。コストなしのカードは 0 として扱う |
| `match.groupKey` | `groupKey` の部分一致 |
| `match.minConfidence` | `confidence` の下限（0–1、`card.confidence >= value`）。confidence なしのカードは不適合 |
| `lease.until` | ISO 8601。これを過ぎたらルールは発火しない |
| `lease.maxCount` | 自動承認の上限回数。1 以上の整数 |
| `enabled` | 真偽値。省略時は true |
| `action` | `"approve"` / `"reject"`（省略時は `"approve"`）。自動拒否ルールは reject 側の binding を実行せず、そのまま `processed` にする |
| `source` | `"manual"` / `"learned"`（任意・表示用）。`"learned"` はスワイプ学習（I-1003）で作られた印で、一致判定には使わない |

- 不正なルール（`id` 欠落、`severity` が非配列、`maxCost` が非数値、
  `minConfidence` が 0–1 外、`action` が approve/reject 以外、`maxCount`
  が 1 未満、`until` が不正日付、`enabled` が非真偽値）は `400` ではじく —
  自動承認の条件を黙って広げないため、緩い検証はしない。
- **PUT はルール集合を丸ごと置換**する。新しいルールは保存以降に
  enqueue されるカードにだけ適用され、**待機中の backlog は掃き出さない**。
- マッチした新規カードは即座に自動決定される（grace 0）:
  `outcome {name: <action>, data: {byRule}, source: "auto_rule"}` を記録し、
  `dismissTask {taskId, by: "auto_rule"}` を配信、`replyUrl` へ通常通り返送
  する（再試行つき）。`createTaskCard` は配信しない（スタックに載らない）。
  enqueue 応答は `201 {ok, taskId, autoApproved: true, byRule}`（reject 時は
  `autoApproved: false, autoRejected: true` を併せて返す）。
- 発火ごとに `leaseUsed[ruleId]` を +1 し、`maxCount` に達したらそのルールは
  失効する。`until` 過ぎも失効。どちらも `ruleChanged` では通知しない
  （`GET /rules` で現在の集合を確認できる）。

#### ルールのドライラン（I-1002）

```
POST /api/v1/rules/simulate    Authorization: Bearer $CLIENT_TOKEN
body = {} または { "match": RuleMatch, "action": "approve" | "reject" }
→ 200 {sampleSize, autoApprove, autoReject, hitl}
```

- ハブは直近に enqueue された約 100 件のメタデータ（agent 名、severity、
  groupKey、cost、confidence、expiresAt）を保持し、保存済みルール（＋任意
  の候補 `match`/`action`）にかけたら何件が自動承認・自動拒否・人間行きに
  なるかを数える。候補なし = 現在の集合のドライラン。
- 先勝ち（保存済みが候補より優先）、リース残量は無視（「何にマッチするか」
  の問いなので）。状態は変えない。履歴は DO ストレージに永続化される。

#### スワイプからの学習（I-1003）

`POST /api/v1/actions` の通常 approve/reject に `learnRule: true` を添えると、
コミット確定時にハブが `"learned"` ルールを1件追加する:
`{action: 同じ決定, match: {agent: カードの agent 名, severity: [カードの
severity], groupKey（あれば）}, enabled: true, source: "learned"}`。
既存集合への追加（置換しない）、同一内容の重複は作らない。snooze /
delegate / 部分承認では無視される。応答・配信は通常通り。

### ペアリングと端末トークン（I-808 / I-809）

ハブ URL とトークンの手入力をやめ、PC の Web UI に出した QR
（`/pair?code=…` の URL）を読み込むだけにする。トークンは端末ごと。

```
POST /api/v1/pair          Authorization: Bearer $CLIENT_TOKEN
body = { "device": "pixel-9", "user": "alice" }（どちらも任意）
→ 200 {code: "XK7Q2M", expiresAt: "…", url: "https://hub/pair?code=XK7Q2M"}

POST /api/v1/pair/redeem   認証なし（code の所持が credential）
body = { "code": "XK7Q2M" }
→ 200 {token: "dev_<uuid>", user: "alice"}
```

- `code` は 6 文字（紛らわしい字を除く）、TTL 5 分、**使い捨て**。
  期限切れ・使用済み・未知の code は `404 invalid_code`。
- `pair` の `user` 省略時は、呼び出し元が端末トークンならその user、
  `$CLIENT_TOKEN` なら `"default"` になる。
- `token` は `dev_<uuid>`。ハブは SHA-256 ハッシュだけを保存し
  （`device:<sha256>` → `{user, createdAt}`）、平文は保持しない。
- 端末トークンで認証したリクエストは、その user の Durable Object
  （`user:<user>`）に振り分けられる。`$CLIENT_TOKEN` は共有の `global`
  DO。SSE の `?token=` でも同じ解決をする。

### Web Push（I-701）

Web UI を PWA 化する前の、ブラウザ通知のハブ側実装。VAPID 鍵が未設定なら
送信は黙ってスキップする（`VAPID_PUBLIC_KEY` / `VAPID_PRIVATE_KEY` /
`VAPID_SUBJECT`）。

```
POST   /api/v1/push/subscribe    Authorization: Bearer $CLIENT_TOKEN
body = { "endpoint": "https://…", "keys": { "p256dh": "…", "auth": "…" } }
→ 201 {ok: true}

DELETE /api/v1/push/subscribe    Authorization: Bearer $CLIENT_TOKEN
body = 同上（endpoint で特定）
→ 204（body なし）

GET    /api/v1/push/vapid        Authorization: Bearer $CLIENT_TOKEN
→ 200 {publicKey: "<base64url>"}
```

- 購読は認証スコープの DO に保存する（`$CLIENT_TOKEN` なら global、
  端末トークンならその user の DO）。
- 新規カードの `createTaskCard` 配信時にだけ、ハブが全購読へ
  ファイア・アンド・フォーゲットで送る（update の再配信では送らない）。
  ペイロードは `{title: "AgentDesk", body: summary, taskId}`、TTL 3600。
- 暗号化は RFC 8291 `aes128gcm`（ECDH P-256 + HKDF-SHA256 +
  AES-128-GCM、WebCrypto のみ）、認証は VAPID JWT（ES256、
  `aud` = endpoint の origin、`sub` = `VAPID_SUBJECT` 既定
  `mailto:admin@localhost`）。`Authorization: vapid t=<jwt>, k=<public>`。
- 送信先が `404` / `410` を返したら購読を削除する。その他の失敗は捨てる
  （再試行しない）。

### ネイティブプッシュ APNs / FCM（I-701 follow-up）

新規カード時に Web Push と並行して送る。登録はいつでも保存し、プロバイダ
秘密鍵が未設定の間は送信だけ黙ってスキップする（VAPID と同じ流儀）。
詳しい鍵の取り方は [`docs/push.md`](push.md)。

```
POST   /api/v1/push/native    Authorization: Bearer $CLIENT_TOKEN
body = { "platform": "apns" | "fcm", "token": "…" }
→ 201 {ok: true}

DELETE /api/v1/push/native    Authorization: Bearer $CLIENT_TOKEN
body = 同上（platform + token で特定）
→ 204（body なし）
```

- `apns` の token は 64 文字 hex（それ以外は `400`）、`fcm` は空白なし
  10–4096 文字（それ以外は `400`）。`platform` 不正も `400`。
- トークンは認証スコープの DO に `nativepush:<sha256>` で保存する（平文は
  保持しない）。Web Push 購読とは名前空間が別。
- APNs: ES256 プロバイダ JWT（`kid` = `APNS_KEY_ID`、`iss` =
  `APNS_TEAM_ID`）で `https://api.push.apple.com/3/device/<token>`（開発は
  `APNS_SANDBOX=1` で sandbox ホスト）へ `apns-push-type: alert`、
  `{aps: {alert: {title: "AgentDesk", body: summary}, sound: "default"},
  taskId}`。`400` / `410` で登録を削除。
- FCM v1: RS256 サービスアカウント JWT → OAuth 交換 →
  `POST …/v1/projects/<id>/messages:send {message: {token, notification:
  {title, body}, data: {taskId}}}`。`NOT_FOUND` / `UNREGISTERED` で削除。

### 添付ファイル（I-1001）

音声メモ・写真を action の `data` から参照するための小さな blob 置き場。
クライアントは action `data` に `{<componentId>: {attachmentId, kind,
contentType}}` を入れる（素通し — 追加検証なし）。

```
POST /api/v1/attachments    Authorization: Bearer $CLIENT_TOKEN
body = { "kind": "audio" | "image", "contentType": "audio/m4a", "dataBase64": "…" }
→ 201 {id: "att_…", url: "/api/v1/attachments/att_…"}

GET  /api/v1/attachments/{id}    Authorization: Bearer $CLIENT_TOKEN または $AGENT_TOKEN
→ 200 生バイト（Content-Type は登録時のもの）
```

- `kind` 不正・`contentType` 非 MIME・`dataBase64` 不正は `400`。デコード後
  2 MiB 超は `413 too_large`。
- ダウンロードはエージェントも取れる（action の `data` で id を受け取った
  後の取得用）。未知 id は `404`。添付は認証スコープの DO に保存する。
