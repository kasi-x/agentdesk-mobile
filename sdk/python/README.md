# agentdesk — Python SDK

Standard-library-only AgentDesk agent client (`urllib`, `hmac`, `json`).
Python 3.8+.

Drop `agentdesk.py` next to your agent, or add `sdk/python/` to your path:

```bash
pip install ./sdk/python   # once a pyproject.toml is added; until then copy the module
```

## Ask a human (blocking)

```python
import os
from agentdesk import Desk

desk = Desk(os.environ["HUB_URL"], os.environ["AGENT_TOKEN"])

decision = desk.ask(
    {
        "type": "createTaskCard",
        "agent": {"name": "Deploy Bot"},
        "severity": "warning",
        "summary": "Deploy release/1.4.0 to production?",
        "replyUrl": "https://my-agent.example.com/callback",
        "components": [
            {"id": "diff", "component": "DiffBox",
             "properties": {"title": "Version", "before": "1.3.9", "after": "1.4.0"}},
        ],
        "actions": {
            "onSwipeRight": {"actionName": "approve", "label": "Deploy",
                             "payload": {"decision": "ACCEPT"}},
            "onSwipeLeft": {"actionName": "reject", "label": "Hold",
                            "payload": {"decision": "DECLINE"}},
        },
    },
    timeout=600,  # seconds; default 300
)

print(decision["actionName"], decision["data"], decision["source"])
# {'taskId', 'status', 'actionName', 'data', 'source', 'action', 'delivery'}
```

`ask()` POSTs the card to `POST /api/v1/tasks`, then long-polls
`GET /api/v1/tasks/{taskId}/result?wait=60` until the task reaches a terminal
status (`approved`, `rejected`, `withdrawn`, `expired`). On expiry it raises
`DeskTimeoutError`; the task keeps waiting in the hub, so a later `result()`
call still gets the decision.

## Update / withdraw a pending card

```python
desk.update("task_98234", {**full_replacement_card})  # rotates nonce, revised: true
desk.withdraw("task_98234")                           # broadcasts withdrawTask
```

## Verify `replyUrl` callbacks

The hub POSTs the decision to your `replyUrl`, signed with
`X-AgentDesk-Signature: t=<ts>,v1=<hex-hmac-sha256 of "ts.body">` and
`X-AgentDesk-Event: triage_reply|expire`. The secret is
`REPLY_SIGNING_SECRET`, falling back to `AGENT_TOKEN`.

```python
from http.server import BaseHTTPRequestHandler, HTTPServer
from agentdesk import verify_signature

SECRET = os.environ.get("AGENTDESK_SECRET") or os.environ["AGENT_TOKEN"]

class Callback(BaseHTTPRequestHandler):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if not verify_signature(self.headers, raw, SECRET, max_skew=300):
            self.send_response(401); self.end_headers(); return
        reply = json.loads(raw)
        print(reply["actionName"], reply["data"])
        self.send_response(200); self.end_headers()

HTTPServer(("127.0.0.1", 8799), Callback).serve_forever()
```

Pass the **raw** body (`bytes`), not a re-serialized dict — the HMAC is over the
exact bytes the hub signed. `max_skew` is optional and in seconds.
`sign_body(secret, body)` builds a header value for tests/replays.
