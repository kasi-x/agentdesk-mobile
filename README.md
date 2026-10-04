# AgentDesk Mobile

モバイルファーストな Human-in-the-Loop トリアージUI —
「チャットを捨て、片手親指のスワイプだけで無数の自律型エージェントを監督・承認する」。

未処理タスクだけが積まれるカードスタックを親指1本で捌きます:
**右スワイプ=Approve / 左=Reject / タップ=Inspect(動的フォーム) / 下=Snooze**。
カードは要約Diff+信頼度スコアで1秒把握、操作は0msの楽観的UI、
二重承認はサーバー側nonceで厳格に排他します。

| Layer | Tech | Path |
|---|---|---|
| Agents | LangGraph / Dify / Claude Code / n8n / custom → `POST /api/v1/tasks` | (yours) |
| Hub | Cloudflare Workers + Durable Objects (SSE fan-out, nonce CAS lock) | [backend/](backend/) |
| Mobile | Flutter (flutter_card_swiper, SSE, offline queue) | [mobile/](mobile/) |
| Mock agent | dependency-free Node script for local E2E | [tools/](tools/) |

Docs: [requirements.ja.md](docs/requirements.ja.md) (原案) ·
[protocol.md](docs/protocol.md) (wire spec) ·
[architecture.md](docs/architecture.md).

## Quickstart (local E2E, 3 terminals)

```bash
# 1) Hub
cd backend && cp .dev.vars.example .dev.vars && npm install && npm run dev
#    → http://127.0.0.1:8787

# 2) Mock agent (prints triage replies delivered back to the "agent")
node tools/mock-agent.mjs listen

# 3) Send 3 sample cards, then swipe them in the app / via curl
node tools/mock-agent.mjs send
curl -s -X POST http://127.0.0.1:8787/api/v1/actions \
  -H 'Authorization: Bearer dev-client-token' -H 'Content-Type: application/json' \
  -d '{"taskId":"<taskId from step 3>","nonce":"<nonce>","actionName":"approve","source":"web_ui","data":{"decision":"ACCEPT"}}'
# replaying the same body → 409 already_processed
```

Mobile app: install Flutter ≥3.5, then `cd mobile &&
flutter create --platforms=ios,android --org dev.agentdesk . && flutter
pub get && flutter run` and point Settings at the hub
(dev defaults `http://127.0.0.1:8787` / `dev-client-token`).

## Status

Phase 1 MVP implemented (card stack, webhook→DO→SSE pipeline, optimistic
UI + offline queue, nonce/optimistic-lock, agent callback delivery).
Phase 2 done: genui (A2UI) inspect forms, richer Diff (`rows` + `inline`),
Web triage UI served from the Worker (`/`), same-origin POST fix.
Phase 3: Live Activities / Dynamic Island, push. See AGENTS.md checklist.
