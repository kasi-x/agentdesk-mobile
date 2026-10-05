# agentdesk-mcp

Zero-dependency [MCP](https://modelcontextprotocol.io) stdio server that lets an
MCP host (Claude Desktop, Cursor, …) ask a human to triage an agent request in
the AgentDesk mobile/web UI, and block until the decision comes back.

It speaks newline-delimited JSON-RPC 2.0 on stdin/stdout and reuses the
TypeScript SDK (`../../sdk/typescript/index.mjs`). No `npm install` needed —
Node >= 18 only.

## Tools

| Tool | Arguments | Returns |
|---|---|---|
| `agentdesk_ask` | `summary` (req), `severity?` (`info`/`warning`/`critical`), `components?` (A2UI array), `replyUrl?`, `timeoutMs?` | `{taskId,status,actionName,data,source,…}` after a human decides |
| `agentdesk_result` | `taskId` (req) | current `{taskId,status,action?,delivery?}` without waiting |

`agentdesk_ask` POSTs to `POST /api/v1/tasks`, then long-polls
`GET /api/v1/tasks/{id}/result?wait=60` until the task is terminal. On timeout it
returns an `isError` result; the card keeps waiting in the hub, so
`agentdesk_result` still retrieves the decision later.

## Configuration

| Env | Default | Purpose |
|---|---|---|
| `HUB_URL` | `http://127.0.0.1:8787` | hub origin |
| `AGENT_TOKEN` | — (required to call tools) | agent bearer token |
| `AGENTDESK_AGENT_NAME` | `AgentDesk MCP` | agent name on the card |
| `AGENTDESK_MCP_TIMEOUT_MS` | `300000` | default `ask` budget |

### Claude Desktop

```json
{
  "mcpServers": {
    "agentdesk": {
      "command": "node",
      "args": ["/absolute/path/to/agentdesk-mobile/tools/mcp-server/server.mjs"],
      "env": {
        "HUB_URL": "https://desk.example.com",
        "AGENT_TOKEN": "paste-agent-token-here"
      }
    }
  }
}
```

### Manual smoke test

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | node tools/mcp-server/server.mjs
```

Handshake responses (`initialize`, `tools/list`) need no `AGENT_TOKEN`; only
`tools/call` reaches the hub.
