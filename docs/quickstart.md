# AgentDesk クイックスタート — 最初の実タスクまで5分

このガイドでは、AgentDeskハブをデプロイし、エージェント/フックを接続して、最初の実タスクを承認・処理再開するまでを説明します。

## 1) Hubをデプロイ (1分)

### ローカル開発
```bash
cd backend
cp .dev.vars.example .dev.vars
npm install
npm run dev  # http://127.0.0.1:8787
```

### Cloudflare Workersへデプロイ
```bash
cd backend
npx wrangler login
npx wrangler deploy
# シークレット設定
npx wrangler secret put AGENT_TOKEN
npx wrangler secret put CLIENT_TOKEN
```

[![Deploy to Cloudflare Workers](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/kasi-x/agentdesk-mobile)

> `wrangler.jsonc` には `TASK_HUB` Durable Object と `ASSETS` (web/) が定義されています。

## 2) シークレット/接続設定 (1分)

エージェント側に環境変数を設定します:

```bash
export HUB_URL="https://your-worker.example.com"  # または http://127.0.0.1:8787
export AGENT_TOKEN="your-agent-token"
export CLIENT_TOKEN="your-client-token"  # クライアント用
```

## 3) フック/エージェントを接続 (2分)

### Claude Code フック
[tools/claude-code-hook/](../tools/claude-code-hook/) を参照。`.claude/settings.json` に `PreToolUse`/`Notification`/`Stop` フックを設定し、環境変数を渡します。

### LangGraph
[sdk/langgraph/](../sdk/langgraph/) の `agentdesk_interrupt.ask_human()` をノード内で呼び出します。

### n8n
[tools/n8n/](../tools/n8n/) のワークフローテンプレートをインポートし、環境変数 `HUB_URL`/`AGENT_TOKEN` を設定します。

### MCP (Claude Desktop等)
[tools/mcp-server/](../tools/mcp-server/) を設定。`agentdesk_ask` でブロッキング承認が可能です。

### 直接API/SDK
- TypeScript: [sdk/typescript/](../sdk/typescript/) `createClient().ask(card, {timeout})`
- Python: [sdk/python/](../sdk/python/) `Desk(HUB_URL, AGENT_TOKEN).ask(card)`

## 4) 最初の実タスクを送信して承認 (1分)

テンプレートカードを使って実タスクを送信できます（[docs/templates/](templates/)）:

```bash
# テンプレートを送信（例：カレンダー変更）
curl -s -X POST "$HUB_URL/api/v1/tasks" \
  -H "Authorization: Bearer $AGENT_TOKEN" \
  -H "Content-Type: application/json" \
  -d @docs/templates/calendar-change.json
```

返された `taskId`/`nonce` を確認し、クライアント（モバイル/Web）でカードを承認します。エージェントは `GET /api/v1/tasks/{id}/result?wait=60` で結果を受け取り、処理を再開します。

## QRペアリング（オプション）

クライアントが初回接続する場合は、`POST /api/v1/pair` でペアリングコードを発行し、モバイルアプリでスキャン/入力してデバイストークンを取得します（詳細は [docs/protocol.md](protocol.md) 参照）。

## Tips
- ローカルE2Eは [README.md](../README.md) の「Quickstart (local E2E, 3 terminals)」も参照してください
- テンプレートカードは `validateTaskCard` スキーマに準拠しています（[backend/src/protocol.ts](../backend/src/protocol.ts)）
- 長ポーリングは1リクエスト最大60秒です（詳細: [docs/sdk.md](sdk.md)）
