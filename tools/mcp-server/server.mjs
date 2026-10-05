#!/usr/bin/env node
// Minimal, dependency-free MCP (Model Context Protocol) stdio server for
// AgentDesk. Implements just enough of the protocol for an MCP host
// (Claude Desktop, Cursor, …) to list and call two tools:
//
//   agentdesk_ask({summary, severity?, components?, replyUrl?, timeoutMs?})
//     -> POST the card to the hub, block until a human decides.
//   agentdesk_result({taskId})
//     -> read the current decision state without waiting.
//
// Transport: newline-delimited JSON-RPC 2.0 over stdin/stdout (MCP stdio).
// Everything human-facing goes to stderr so stdout stays a clean message
// stream. No npm dependencies; reuses the TypeScript SDK at ../../sdk/typescript.
//
// Env: HUB_URL (default http://127.0.0.1:8787), AGENT_TOKEN (required to call
// tools), AGENTDESK_AGENT_NAME, AGENTDESK_MCP_TIMEOUT_MS (default 300000).

import readline from "node:readline";
import { createClient } from "../../sdk/typescript/index.mjs";

const SERVER_NAME = "agentdesk-mcp";
const SERVER_VERSION = "0.1.0";
const FALLBACK_PROTOCOL_VERSION = "2024-11-05";
const DEFAULT_TIMEOUT_MS = Number(process.env.AGENTDESK_MCP_TIMEOUT_MS ?? 300_000);

const log = (...args) => process.stderr.write(`[agentdesk-mcp] ${args.join(" ")}\n`);

/** Bad tool arguments -> JSON-RPC -32602 (not a tool runtime failure). */
class ToolInputError extends Error {}

let cached = null;
function client() {
  if (cached) return cached;
  const hubUrl = process.env.HUB_URL ?? process.env.AGENTDESK_HUB_URL;
  const agentToken = process.env.AGENT_TOKEN ?? process.env.AGENTDESK_AGENT_TOKEN;
  if (!agentToken) {
    throw new Error("AGENT_TOKEN is not set in the MCP server environment");
  }
  cached = createClient({ hubUrl, agentToken });
  return cached;
}

const TOOLS = [
  {
    name: "agentdesk_ask",
    description:
      "Send a task card to AgentDesk and block until a human decides (approve/reject). " +
      "Returns the decision as JSON: {taskId,status,actionName,data,source}.",
    inputSchema: {
      type: "object",
      properties: {
        summary: {
          type: "string",
          description: "One-line question shown on the card (Japanese or English).",
        },
        severity: {
          type: "string",
          enum: ["info", "warning", "critical"],
          description: "Header badge colour. Defaults to info.",
        },
        components: {
          type: "array",
          items: { type: "object" },
          description:
            "Optional A2UI component list (DiffBox, Text, Chips, …), rendered as pure data.",
        },
        replyUrl: {
          type: "string",
          description: "Optional https callback URL the hub POSTs the signed decision to.",
        },
        timeoutMs: {
          type: "number",
          description: "Overall wait budget in milliseconds (default 300000).",
        },
      },
      required: ["summary"],
      additionalProperties: false,
    },
  },
  {
    name: "agentdesk_result",
    description:
      "Check the current decision state of an AgentDesk task without waiting. " +
      "Returns {taskId,status,action?,delivery?}.",
    inputSchema: {
      type: "object",
      properties: {
        taskId: { type: "string", description: "Task id returned by agentdesk_ask." },
      },
      required: ["taskId"],
      additionalProperties: false,
    },
  },
];

function textResult(value) {
  const text = typeof value === "string" ? value : JSON.stringify(value, null, 2);
  return { content: [{ type: "text", text }], isError: false };
}

async function callTool(name, args) {
  if (name === "agentdesk_ask") {
    const a = args ?? {};
    if (typeof a.summary !== "string" || !a.summary.trim()) {
      throw new ToolInputError("summary is required");
    }
    const card = {
      type: "createTaskCard",
      agent: { name: process.env.AGENTDESK_AGENT_NAME ?? "AgentDesk MCP" },
      summary: a.summary,
      components: Array.isArray(a.components) ? a.components : [],
    };
    if (a.severity) card.severity = a.severity;
    if (a.replyUrl) card.replyUrl = a.replyUrl;

    const requested = Number(a.timeoutMs);
    const timeout = Number.isFinite(requested) && requested > 0 ? requested : DEFAULT_TIMEOUT_MS;
    const decision = await client().ask(card, { timeout });
    return textResult(decision);
  }

  if (name === "agentdesk_result") {
    const a = args ?? {};
    if (typeof a.taskId !== "string" || !a.taskId.trim()) {
      throw new ToolInputError("taskId is required");
    }
    const state = await client().result(a.taskId, 0);
    return textResult(state ?? {});
  }

  throw new ToolInputError(`unknown tool: ${name}`);
}

// -- JSON-RPC plumbing ------------------------------------------------------

const send = (msg) => process.stdout.write(`${JSON.stringify(msg)}\n`);
const reply = (id, result) => send({ jsonrpc: "2.0", id, result });
const replyError = (id, code, message) =>
  send({ jsonrpc: "2.0", id, error: { code, message } });

async function handle(message) {
  const { id, method, params } = message ?? {};
  const isNotification = id === undefined || id === null;

  if (method === "initialize") {
    reply(id, {
      protocolVersion:
        typeof params?.protocolVersion === "string"
          ? params.protocolVersion
          : FALLBACK_PROTOCOL_VERSION,
      capabilities: { tools: {} },
      serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
      instructions:
        "Ask a human to triage an agent request from their phone. " +
        "Use agentdesk_ask to block on a decision, agentdesk_result to poll.",
    });
    return;
  }

  if (typeof method === "string" && method.startsWith("notifications/")) return; // no response

  if (method === "ping") {
    reply(id, {});
    return;
  }

  if (method === "tools/list") {
    reply(id, { tools: TOOLS });
    return;
  }

  if (method === "tools/call") {
    try {
      const result = await callTool(params?.name, params?.arguments ?? {});
      reply(id, result);
    } catch (err) {
      if (err instanceof ToolInputError) {
        replyError(id, -32602, err.message);
      } else {
        const msg = err?.message ?? String(err);
        log("tool error:", msg);
        reply(id, { content: [{ type: "text", text: `error: ${msg}` }], isError: true });
      }
    }
    return;
  }

  if (isNotification) return; // unknown notification: silently ignore

  replyError(id, -32601, `method not found: ${method}`);
}

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on("line", (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;
  let message;
  try {
    message = JSON.parse(trimmed);
  } catch {
    log("dropping non-JSON input line");
    return;
  }
  handle(message).catch((err) => log("handler error:", err?.message ?? err));
});
rl.on("close", () => process.exit(0));

log(`listening on stdio (hub=${process.env.HUB_URL ?? "http://127.0.0.1:8787"})`);
