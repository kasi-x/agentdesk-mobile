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
`priority`, `revised`) do not bump the version; clients must tolerate
unknown ones.

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
| GET | `/api/v1/state` | Bearer `$CLIENT_TOKEN` | client | snapshot of pending tasks (cold-start priming, NFR-1.2) |
| POST | `/api/v1/actions` | Bearer `$CLIENT_TOKEN` | client | deliver a triage decision or a snooze (7.2 payload) |
| POST | `/api/v1/actions/bulk` | Bearer `$CLIENT_TOKEN` | client | deliver many triage decisions, each CASed independently (I-201) |
| POST | `/api/v1/actions/undo` | Bearer `$CLIENT_TOKEN` | client | revert a decision still inside the undo grace window (I-104) |
| GET | `/healthz` | none | ops | liveness |

Errors: `401` bad/missing token · `400` invalid payload (message says why)
· `404` `task_not_found` · `409` `already_processed` / `bad_nonce` /
`duplicate_task` / `too_late`. CORS: `ALLOWED_ORIGINS` env
(comma-separated, `*` for dev).

## SSE events (`GET /api/v1/stream`)

```
event: snapshot        data: {"protocolVersion":1,"tasks":[TaskCard,...],"snoozed":[...],"delivery":[...]}
event: createTaskCard  data: TaskCard   (a taskId the client already holds means: replace in place — I-203 escalate / I-204 update)
event: dismissTask     data: {"taskId":"…","by":"swipe_gesture"}   (FR-3.2: remove from every device)
event: withdrawTask    data: {"taskId":"…"}                        (I-205: the agent cancelled the card)
event: deliveryFailed  data: {"taskId":"…","lastError":"HTTP 500"} (I-604: replyUrl retries exhausted)
: ping                                                  (heartbeat comment every 15s)
```

`snapshot` (also `GET /api/v1/state`) is the reconnect resync envelope:

| Field | Notes |
|---|---|
| `protocolVersion` | wire version of the hub (currently `1`) |
| `tasks` | pending, **non-snoozed** cards, ordered priority desc / createdAt asc (I-206) |
| `snoozed` | `[{taskId, until}]` — hidden by a server-side snooze until `until` |
| `delivery` | `[{taskId, lastError?, attempts}]` — terminal replyUrl failures (I-604) |

`dismissTask.by` is the action `source` (`swipe_gesture`, `web_ui`,
`on_expire`, …) or the hub-side values `snooze` / `withdraw`; a snooze
dismissal also carries `snoozedUntil` (ISO 8601).

Reconnect policy (client): exponential backoff 1s→30s; on reconnect the
fresh `snapshot` reconciles the stack, so no Last-Event-ID replay is
needed in v1.

## TaskCard (hub ⇐ agent, hub ⇒ clients)

Agents POST this to `/api/v1/tasks`. `taskId`, `nonce`, `createdAt` are
filled in by the hub when absent; `priority` and `revised` are added by
the hub (agents never send them).

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
| `actions.inspectForm` | opt | bottom-sheet form components (§3.3) |
| `actions.rejectReasons` | opt | `[{id, label}]` reject reason chips (I-118). The chosen id arrives as `data.reason` on the reply; no choice = reject without a reason. Malformed entries are dropped, non-array is `400` |
| `context` | opt | structured 裏面 (back-of-card) context for the details panel — see below |
| `expiresAt` | opt | ISO 8601 deadline; the hub runs `onExpire` at it (I-203, see below) |
| `onExpire` | opt | `approve` \| `reject` \| `escalate` \| `drop` (default `drop`); requires `expiresAt` |
| `groupKey` | opt | non-empty string; cards sharing it are a bundle (I-201). Non-string/empty → `400` |
| `decisionKind` | opt | `approve` \| `choose` \| `fill` (default `approve`); unknown value → `400` |
| `editable` | opt | `{componentId, kind: "number"\|"datetime", min?, max?, step?}` — inline value editing hint (I-114). `componentId` required; bad kinds/values → `400` |
| `priority` | hub adds | urgency score (higher = more urgent); never sent by agents — see below |
| `revised` | hub adds | `true` on a `createTaskCard` re-broadcast after an agent update (I-204) |

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
snooze) | `two_stage_swipe` (I-101) | `bulk` (I-201 bulk triage).

Hub semantics (FR-3.3): the first accepted action flips the task to
`committing` (see below) and consumes the nonce; concurrent duplicates get
`409 {"error":"already_processed"}` and clients show a “処理済み” toast.
A wrong nonce → `409 bad_nonce`. Unknown task → `404`. Accepted actions
are broadcast as `dismissTask` to all connected devices and forwarded to
`replyUrl` after the undo grace window closes.

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
される。1 件の失敗が他を巻き戻すことはない。応答は常に `200`:

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

