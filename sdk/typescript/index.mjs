// AgentDesk agent SDK — TypeScript / JavaScript (ESM, zero dependencies).
//
// Node >= 18 (global `fetch`). An agent POSTs a task card to the hub, waits
// for the human decision via the agent long-poll result endpoint, and can
// update or withdraw a card while it is still pending. Agents that expose a
// `replyUrl` callback can verify the hub's HMAC signature (see
// `replyHandler()` / `verifySignature()`).
//
//   import { createClient } from "@agentdesk/sdk";
//   const desk = createClient({ hubUrl, agentToken });
//   const { actionName, data, source } = await desk.ask({
//     type: "createTaskCard",
//     agent: { name: "Deploy Bot" },
//     summary: "Deploy release/1.4.0 to production?",
//     components: [],
//     actions: { onSwipeRight: { actionName: "approve" } },
//   }, { timeout: 600_000 });
//
// Wire contract: docs/protocol.md, docs/sdk.md.

import crypto from "node:crypto";

/** Wire protocol version this SDK speaks (sent on every card). */
export const PROTOCOL_VERSION = 1;

/** Server-side cap for a single `?wait` long-poll, in seconds. */
export const MAX_WAIT_SECONDS = 60;

/** Result statuses that mean the task will not change again. */
export const TERMINAL_STATUSES = Object.freeze([
  "approved",
  "rejected",
  "withdrawn",
  "expired",
]);

const TERMINAL = new Set(TERMINAL_STATUSES);

/** Default `ask()` timeout: 5 minutes. */
export const DEFAULT_TIMEOUT_MS = 300_000;

/** Error thrown for non-2xx hub responses and malformed input. */
export class DeskError extends Error {
  constructor(message, { status, code, body } = {}) {
    super(message);
    this.name = "DeskError";
    this.status = status;
    this.code = code;
    this.body = body;
  }
}

/** Error thrown by `ask()` when the task never reaches a terminal status. */
export class DeskTimeoutError extends Error {
  constructor(taskId, timeoutMs) {
    super(`task ${taskId} did not reach a terminal state within ${timeoutMs}ms`);
    this.name = "DeskTimeoutError";
    this.taskId = taskId;
    this.timeoutMs = timeoutMs;
  }
}

/** Read a header case-insensitively from Headers / plain objects / node req.headers. */
function getHeader(headers, name) {
  if (!headers) return undefined;
  if (typeof headers.get === "function") {
    const v = headers.get(name);
    if (v != null) return Array.isArray(v) ? v[0] : v;
  }
  const lower = name.toLowerCase();
  for (const key of Object.keys(headers)) {
    if (key.toLowerCase() !== lower) continue;
    const value = headers[key];
    return Array.isArray(value) ? value[0] : value;
  }
  return undefined;
}

function bodyToString(body) {
  if (body == null) return "";
  if (typeof body === "string") return body;
  if (Buffer.isBuffer(body) || body instanceof Uint8Array) {
    return Buffer.from(body).toString("utf8");
  }
  return JSON.stringify(body);
}

/** Parse `t=<ts>,v1=<hex>` into `{ t, v1 }`. */
export function parseSignatureHeader(value) {
  const out = {};
  for (const part of String(value ?? "").split(",")) {
    const eq = part.indexOf("=");
    if (eq === -1) continue;
    out[part.slice(0, eq).trim()] = part.slice(eq + 1).trim();
  }
  return out;
}

function hmacHex(secret, ts, body) {
  return crypto
    .createHmac("sha256", String(secret))
    .update(`${ts}.${bodyToString(body)}`)
    .digest("hex");
}

/** Build the header value the hub sends: `t=<ts>,v1=<hex>`. `ts` in seconds. */
export function signBody(secret, body, { ts = Math.floor(Date.now() / 1000) } = {}) {
  return `t=${ts},v1=${hmacHex(secret, ts, body)}`;
}

function timingSafeEqualHex(a, b) {
  if (typeof a !== "string" || typeof b !== "string") return false;
  const ab = Buffer.from(a, "utf8");
  const bb = Buffer.from(b, "utf8");
  if (ab.length !== bb.length) return false;
  return crypto.timingSafeEqual(ab, bb);
}

/**
 * Verify an inbound hub callback signature.
 *
 * @param headers request headers (Headers, plain object or node IncomingHttpHeaders)
 * @param body    the *raw* request body exactly as received (string or Buffer)
 * @param secret  shared secret (`REPLY_SIGNING_SECRET`, falling back to `AGENT_TOKEN`)
 * @param opts.maxSkew  optional max clock skew in ms; when set, a stale `t` fails
 * @returns boolean
 */
export function verifySignature(headers, body, secret, { maxSkew, now = Date.now() } = {}) {
  if (!secret) return false;
  const header = String(getHeader(headers, "x-agentdesk-signature") ?? "");
  const { t, v1 } = parseSignatureHeader(header);
  if (!t || !v1) return false;
  if (maxSkew != null) {
    const tsMs = Number(t) * 1000;
    if (!Number.isFinite(tsMs) || Math.abs(now - tsMs) > maxSkew) return false;
  }
  return timingSafeEqualHex(hmacHex(secret, t, body), v1);
}

function trimBase(url) {
  return String(url ?? "").replace(/\/+$/, "");
}

async function request(base, token, path, { method = "GET", body } = {}) {
  const res = await fetch(new URL(path, base), {
    method,
    headers: {
      authorization: `Bearer ${token}`,
      accept: "application/json",
      ...(body !== undefined ? { "content-type": "application/json" } : {}),
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let json = null;
  if (text) {
    try {
      json = JSON.parse(text);
    } catch {
      json = null;
    }
  }
  if (!res.ok) {
    const code = json && (json.error ?? json.code);
    throw new DeskError(
      `${method} ${path} failed: ${res.status}${code ? ` ${code}` : ""}`,
      { status: res.status, code, body: json ?? text },
    );
  }
  return json;
}

/**
 * Create an AgentDesk agent client.
 *
 * @param {object} opts
 * @param {string} opts.hubUrl     hub origin, e.g. "https://desk.example.com"
 * @param {string} opts.agentToken bearer token (`AGENT_TOKEN`)
 * @returns {object} desk client
 */
export function createClient({ hubUrl, agentToken } = {}) {
  const base = trimBase(hubUrl ?? process.env.AGENTDESK_HUB_URL ?? "http://127.0.0.1:8787");
  const token = agentToken ?? process.env.AGENTDESK_AGENT_TOKEN ?? process.env.AGENT_TOKEN;
  if (!token) {
    throw new DeskError("createClient: agentToken is required (option or AGENT_TOKEN env)");
  }

  const scoped = (path, opts) => request(base, token, path, opts);

  /** Enqueue a card; resolves with the hub's echo (taskId, nonce, …). */
  const enqueue = (card) =>
    scoped("/api/v1/tasks", { method: "POST", body: { protocolVersion: PROTOCOL_VERSION, ...card } });

  /** Current decision state; `wait` seconds long-poll server-side (max 60). */
  const result = (taskId, wait = MAX_WAIT_SECONDS) =>
    scoped(
      `/api/v1/tasks/${encodeURIComponent(taskId)}/result?wait=${Math.max(0, Math.floor(wait))}`,
    );

  /**
   * Enqueue a card and block until the human decides.
   *
   * @param {object} card full task card
   * @param {object} [opts]
   * @param {number} [opts.timeout] overall budget in ms (default 5 min, `Infinity` to wait forever)
   * @returns {Promise<{taskId,status,actionName,data,source,action,delivery}>}
   */
  async function ask(card, { timeout = DEFAULT_TIMEOUT_MS } = {}) {
    const created = await enqueue(card);
    const taskId = created?.taskId ?? card?.taskId;
    if (!taskId) throw new DeskError("ask: hub response did not include a taskId");

    const deadline = timeout === Infinity ? Infinity : Date.now() + Math.max(0, timeout);
    for (;;) {
      const remaining = deadline - Date.now();
      const wait =
        remaining === Infinity
          ? MAX_WAIT_SECONDS
          : remaining <= 0
            ? 0
            : Math.max(1, Math.min(MAX_WAIT_SECONDS, Math.ceil(remaining / 1000)));

      const state = await result(taskId, wait);
      if (state && TERMINAL.has(state.status)) {
        return {
          taskId,
          status: state.status,
          actionName: state.action?.name ?? null,
          data: state.action?.data ?? null,
          source: state.action?.source ?? null,
          action: state.action ?? null,
          delivery: state.delivery ?? null,
        };
      }
      if (Date.now() >= deadline) throw new DeskTimeoutError(taskId, timeout);
    }
  }

  /** Replace a still-pending card (rotates the nonce, rebroadcasts with revised:true). */
  const update = (taskId, card) =>
    scoped(`/api/v1/tasks/${encodeURIComponent(taskId)}/update`, {
      method: "POST",
      body: { protocolVersion: PROTOCOL_VERSION, ...card },
    });

  /** Withdraw a still-pending card (broadcasts `withdrawTask`). */
  const withdraw = (taskId) =>
    scoped(`/api/v1/tasks/${encodeURIComponent(taskId)}/withdraw`, { method: "POST" });

  /**
   * Express-free helper for agents that expose `replyUrl`. Returns
   * `{ secret, verify, event, handle }`; pass the raw request body (string or
   * Buffer) so the HMAC is computed over the exact signed bytes.
   */
  function replyHandler({ secret, maxSkew } = {}) {
    const resolved =
      secret ??
      process.env.AGENTDESK_SECRET ??
      process.env.REPLY_SIGNING_SECRET ??
      token;
    return {
      secret: resolved,
      event: (headers) => getHeader(headers, "x-agentdesk-event") ?? null,
      verify: (headers, body) => verifySignature(headers, body, resolved, { maxSkew }),
      /**
       * Verify + parse a callback. Throws DeskError on a bad signature or
       * non-JSON body, otherwise returns `{ event, reply }`.
       */
      handle(headers, body) {
        if (!verifySignature(headers, body, resolved, { maxSkew })) {
          throw new DeskError("invalid X-AgentDesk-Signature", {
            status: 401,
            code: "bad_signature",
          });
        }
        let reply;
        try {
          reply = JSON.parse(bodyToString(body));
        } catch {
          throw new DeskError("callback body is not valid JSON", {
            status: 400,
            code: "bad_body",
          });
        }
        return { event: getHeader(headers, "x-agentdesk-event") ?? "triage_reply", reply };
      },
    };
  }

  return { hubUrl: base, enqueue, result, ask, update, withdraw, replyHandler };
}

export default createClient;
