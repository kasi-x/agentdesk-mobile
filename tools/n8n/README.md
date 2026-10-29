# AgentDesk n8n Workflow Template

Declarative workflow using built-in HTTP Request nodes to post tasks to AgentDesk and poll for results.

## Setup

1. Import `agentdesk-node.json` into n8n
2. Set environment variables in n8n:
   - `HUB_URL` (e.g., `https://your-hub.example.com` or `http://127.0.0.1:8787`)
   - `AGENT_TOKEN` (your agent bearer token)
3. Adjust the "Create Task" HTTP Request node body to build your TaskCard (summary/details from previous nodes)
4. The "Get Result" node polls `GET /api/v1/tasks/{taskId}/result?wait=60` with the created taskId

The workflow uses only built-in HTTP Request nodes (no custom code dependencies). See [docs/sdk.md](../../docs/sdk.md) and [docs/protocol.md](../../docs/protocol.md) for the wire contract.
