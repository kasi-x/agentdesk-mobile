# AgentDesk Claude Code Hook

Minimal stdlib-only hook that posts risky tool use/notifications/stops to AgentDesk for human approval.

## Setup

Add to `.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|Write|Edit|MultiEdit",
        "hooks": [
          {
            "type": "command",
            "command": "node /abs/path/tools/claude-code-hook/agentdesk-hook.mjs"
          }
        ]
      }
    ],
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "node /abs/path/tools/claude-code-hook/agentdesk-hook.mjs"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "node /abs/path/tools/claude-code-hook/agentdesk-hook.mjs"
          }
        ]
      }
    ]
  }
}
```

## Environment variables

- `AGENTDESK_HUB` or `HUB_URL` (default: `http://127.0.0.1:8787`)
- `AGENTDESK_TOKEN` or `AGENT_TOKEN` (required to post tasks)

The hook reads Claude Code hook JSON from stdin, posts a card to `POST /api/v1/tasks`, then polls `GET /api/v1/tasks/{id}/result?wait=60`. It prints hook-decision JSON to stdout (e.g. `{"decision":"approve"}` or `{"decision":"reject"}`).
