#!/usr/bin/env node
// Claude Code hook for AgentDesk (stdlib-only)
// Reads hook JSON from stdin, maps events to desk.ask or POST /api/v1/tasks then poll /result
import { readFileSync } from "node:fs";

const HUB_URL = process.env.AGENTDESK_HUB || process.env.HUB_URL || "http://127.0.0.1:8787";
const AGENT_TOKEN = process.env.AGENTDESK_TOKEN || process.env.AGENT_TOKEN || "";

async function postTask(card) {
  const res = await fetch(`${HUB_URL}/api/v1/tasks`, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${AGENT_TOKEN}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify(card)
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`POST /api/v1/tasks failed: ${res.status} ${text}`);
  }
  return res.json();
}

async function getResult(taskId, wait = 60) {
  const res = await fetch(`${HUB_URL}/api/v1/tasks/${taskId}/result?wait=${wait}`, {
    method: "GET",
    headers: {
      "Authorization": `Bearer ${AGENT_TOKEN}`
    }
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`GET /result failed: ${res.status} ${text}`);
  }
  return res.json();
}

function buildCardFromHook(hook) {
  const event = hook.hook_event_name || hook.event || "unknown";
  const summary = `Claude Code ${event}: ${hook.tool_name || hook.message || "action"}`;
  return {
    type: "createTaskCard",
    agent: { name: "Claude Code Hook" },
    summary,
    components: [
      {
        id: "root_card",
        component: "TriageCard",
        children: ["reason"]
      },
      {
        id: "reason",
        component: "Text",
        properties: {
          text: JSON.stringify(hook).slice(0, 2000),
          variant: "caption"
        }
      }
    ],
    actions: {
      onSwipeRight: { actionName: "approve", label: "Allow", payload: { decision: "ALLOW" } },
      onSwipeLeft: { actionName: "reject", label: "Deny", payload: { decision: "DENY" } }
    }
  };
}

async function main() {
  try {
    const input = readFileSync(0, "utf8");
    const hook = JSON.parse(input || "{}");
    const event = hook.hook_event_name || hook.event;
    
    // For risky tools or notifications/stop, ask for approval
    if (event === "PreToolUse" || event === "Notification" || event === "Stop") {
      if (!AGENT_TOKEN) {
        // If no token, just pass through
        const decision = { decision: "approve" };
        process.stdout.write(JSON.stringify(decision));
        return;
      }
      const card = buildCardFromHook(hook);
      const created = await postTask(card);
      // Poll for result up to 60s
      const result = await getResult(created.taskId, 60);
      if (result.status === "approved") {
        process.stdout.write(JSON.stringify({ decision: "approve" }));
      } else if (result.status === "rejected") {
        process.stdout.write(JSON.stringify({ decision: "reject" }));
      } else {
        // Default allow if we can't decide quickly, but better to deny on uncertainty
        process.stdout.write(JSON.stringify({ decision: "approve" }));
      }
      return;
    }
    
    // Default pass
    process.stdout.write(JSON.stringify({ decision: "approve" }));
  } catch (e) {
    // On error, pass through to avoid blocking
    process.stdout.write(JSON.stringify({ decision: "approve" }));
  }
}

main();
