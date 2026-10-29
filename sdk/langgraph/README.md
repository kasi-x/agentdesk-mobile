# AgentDesk LangGraph Adapter

Stdlib-only helper for human-in-the-loop approvals in LangGraph. Builds a valid TaskCardPayload, POSTs to the hub, and polls `GET /api/v1/tasks/{id}/result?wait=60` (like `sdk/python` patterns).

## Usage (10-line example)

```python
from langgraph.graph import StateGraph, END
from agentdesk_interrupt import ask_human

def approval_node(state):
    decision = ask_human("Deploy to production?", agent_name="Deploy Bot")
    if decision["status"] == "approved":
        return {"approved": True}
    return {"approved": False}

graph = StateGraph(dict)
graph.add_node("approve", approval_node)
graph.set_entry_point("approve")
graph.add_edge("approve", END)
app = graph.compile()
app.invoke({})
```

## Environment

- `HUB_URL` or `AGENTDESK_HUB` (default: `http://127.0.0.1:8787`)
- `AGENT_TOKEN` or `AGENTDESK_TOKEN`

See [docs/sdk.md](../../docs/sdk.md) and [docs/protocol.md](../../docs/protocol.md) for details.
