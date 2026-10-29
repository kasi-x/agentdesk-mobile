"""AgentDesk interrupt helper for LangGraph (stdlib only).

Usable inside a LangGraph node as an "interrupt"-style human approval.
Builds a valid TaskCardPayload, POSTs to hub, polls GET /result?wait=60.

Optionally reuses patterns from sdk/python/agentdesk.py.
"""
from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request
from typing import Any, Dict, Optional


def ask_human(card_or_summary: Any, hub_url: Optional[str] = None, agent_token: Optional[str] = None, timeout: int = 600, **kwargs) -> Dict[str, Any]:
    """
    Ask a human via AgentDesk hub.
    
    card_or_summary: either a full TaskCard dict or a string summary
    """
    hub_url = hub_url or os.environ.get("HUB_URL") or os.environ.get("AGENTDESK_HUB") or "http://127.0.0.1:8787"
    agent_token = agent_token or os.environ.get("AGENT_TOKEN") or os.environ.get("AGENTDESK_TOKEN") or ""
    
    if isinstance(card_or_summary, str):
        card = {
            "type": "createTaskCard",
            "agent": {"name": kwargs.get("agent_name", "LangGraph Agent")},
            "summary": card_or_summary,
            "components": [
                {"id": "root_card", "component": "TriageCard", "children": ["reason"]},
                {"id": "reason", "component": "Text", "properties": {"text": card_or_summary, "variant": "body"}}
            ],
            "actions": {
                "onSwipeRight": {"actionName": "approve", "label": "Approve", "payload": {"decision": "APPROVE"}},
                "onSwipeLeft": {"actionName": "reject", "label": "Reject", "payload": {"decision": "REJECT"}}
            }
        }
    elif isinstance(card_or_summary, dict):
        card = dict(card_or_summary)
        if card.get("type") != "createTaskCard":
            card["type"] = "createTaskCard"
    else:
        raise TypeError("card_or_summary must be str or dict")
    
    # Ensure required fields
    if "agent" not in card:
        card["agent"] = {"name": kwargs.get("agent_name", "LangGraph Agent")}
    if "components" not in card:
        card["components"] = []
    if "actions" not in card:
        card["actions"] = {"onSwipeRight": {"actionName": "approve"}, "onSwipeLeft": {"actionName": "reject"}}
    
    # POST task
    req = urllib.request.Request(
        f"{hub_url}/api/v1/tasks",
        data=json.dumps(card).encode("utf-8"),
        headers={"Authorization": f"Bearer {agent_token}", "Content-Type": "application/json"},
        method="POST"
    )
    try:
        with urllib.request.urlopen(req) as resp:
            created = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"Failed to create task: {e.code} {e.read().decode('utf-8')}")
    
    task_id = created["taskId"]
    # Poll for result
    deadline = time.time() + timeout
    while time.time() < deadline:
        wait = min(60, int(deadline - time.time()))
        if wait < 0:
            break
        req2 = urllib.request.Request(
            f"{hub_url}/api/v1/tasks/{task_id}/result?wait={wait}",
            headers={"Authorization": f"Bearer {agent_token}"},
            method="GET"
        )
        try:
            with urllib.request.urlopen(req2) as resp:
                result = json.loads(resp.read().decode("utf-8"))
        except Exception:
            time.sleep(1)
            continue
        status = result.get("status")
        if status in ("approved", "rejected", "withdrawn", "expired"):
            return result
        time.sleep(1)
    raise TimeoutError(f"Timed out waiting for decision on {task_id}")
```
