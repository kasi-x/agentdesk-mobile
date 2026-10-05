import {
  validateActionReply,
  validateBulkRequest,
  validateTaskCard,
  validateUndoRequest,
} from "./protocol";
import { json } from "./http";
import type { Env } from "./env";

export { TaskHub } from "./task-hub";

/** Rebuild a DO JSON subresponse so cors() header mutation never touches
 *  an immutable subresponse (same-origin browser POSTs surface this as a
 *  500). */
function rebuilt(doRes: Response): Response {
  return new Response(doRes.body, {
    status: doRes.status,
    headers: { "content-type": "application/json" },
  });
}

export default {
  async fetch(request, env): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "OPTIONS") {
      return cors(new Response(null, { status: 204 }), request, env);
    }

    try {
      if (url.pathname === "/healthz") {
        return cors(
          json({ ok: true, now: new Date().toISOString() }),
          request,
          env,
        );
      }

      if (url.pathname === "/api/v1/tasks" && request.method === "POST") {
        if (!authorized(request, env.AGENT_TOKEN)) return unauthorized(request, env);
        const parsed = validateTaskCard(await request.json());
        if (!parsed.ok) {
          return cors(
            json({ error: "invalid_payload", detail: parsed.error }, 400),
            request,
            env,
          );
        }
        const res = await env.TASK_HUB.getByName("global").fetch(
          "https://task-hub/enqueue",
          {
            method: "POST",
            body: JSON.stringify(parsed.value),
            headers: { "content-type": "application/json" },
          },
        );
        return cors(res, request, env);
      }

      if (url.pathname === "/api/v1/actions" && request.method === "POST") {
        if (!authorized(request, env.CLIENT_TOKEN)) return unauthorized(request, env);
        const parsed = validateActionReply(await request.json());
        if (!parsed.ok) {
          return cors(
            json({ error: "invalid_payload", detail: parsed.error }, 400),
            request,
            env,
          );
        }
        const doRes = await env.TASK_HUB.getByName("global").fetch(
          "https://task-hub/action",
          {
            method: "POST",
            body: JSON.stringify(parsed.value),
            headers: { "content-type": "application/json" },
          },
        );
        // Rebuild so cors() header mutation never touches an immutable
        // subresponse (same-origin browser POSTs surface this as a 500).
        return cors(rebuilt(doRes), request, env);
      }

      if (url.pathname === "/api/v1/actions/undo" && request.method === "POST") {
        if (!authorized(request, env.CLIENT_TOKEN)) return unauthorized(request, env);
        const parsed = validateUndoRequest(await request.json());
        if (!parsed.ok) {
          return cors(
            json({ error: "invalid_payload", detail: parsed.error }, 400),
            request,
            env,
          );
        }
        const doRes = await env.TASK_HUB.getByName("global").fetch(
          "https://task-hub/undo",
          {
            method: "POST",
            body: JSON.stringify(parsed.value),
            headers: { "content-type": "application/json" },
          },
        );
        const res = rebuilt(doRes);
        return cors(res, request, env);
      }

      if (url.pathname === "/api/v1/actions/bulk" && request.method === "POST") {
        if (!authorized(request, env.CLIENT_TOKEN)) return unauthorized(request, env);
        const parsed = validateBulkRequest(await request.json());
        if (!parsed.ok) {
          return cors(
            json({ error: "invalid_payload", detail: parsed.error }, 400),
            request,
            env,
          );
        }
        const doRes = await env.TASK_HUB.getByName("global").fetch(
          "https://task-hub/bulk",
          {
            method: "POST",
            body: JSON.stringify(parsed.value),
            headers: { "content-type": "application/json" },
          },
        );
        return cors(rebuilt(doRes), request, env);
      }

      // Agent-side task management (I-204/I-205) + SDK long-poll (I-901).
      const taskRoute = url.pathname.match(
        /^\/api\/v1\/tasks\/([^/]+)\/(update|withdraw|result)$/,
      );
      if (taskRoute && !authorized(request, env.AGENT_TOKEN)) {
        return unauthorized(request, env);
      }
      if (taskRoute && taskRoute[2] === "result" && request.method === "GET") {
        const taskId = decodeURIComponent(taskRoute[1]);
        const wait = url.searchParams.get("wait") ?? "0";
        const doRes = await env.TASK_HUB.getByName("global").fetch(
          `https://task-hub/result?taskId=${encodeURIComponent(taskId)}&wait=${encodeURIComponent(wait)}`,
        );
        return cors(rebuilt(doRes), request, env);
      }
      if (taskRoute && taskRoute[2] === "update" && request.method === "POST") {
        const taskId = decodeURIComponent(taskRoute[1]);
        const parsed = validateTaskCard(await request.json());
        if (!parsed.ok) {
          return cors(
            json({ error: "invalid_payload", detail: parsed.error }, 400),
            request,
            env,
          );
        }
        parsed.value.taskId = taskId;
        const doRes = await env.TASK_HUB.getByName("global").fetch(
          "https://task-hub/update",
          {
            method: "POST",
            body: JSON.stringify(parsed.value),
            headers: { "content-type": "application/json" },
          },
        );
        return cors(rebuilt(doRes), request, env);
      }
      if (taskRoute && taskRoute[2] === "withdraw" && request.method === "POST") {
        const taskId = decodeURIComponent(taskRoute[1]);
        const doRes = await env.TASK_HUB.getByName("global").fetch(
          "https://task-hub/withdraw",
          {
            method: "POST",
            body: JSON.stringify({ taskId }),
            headers: { "content-type": "application/json" },
          },
        );
        return cors(rebuilt(doRes), request, env);
      }

      if (url.pathname === "/api/v1/stream" && request.method === "GET") {
        if (!clientAuthorized(request, env)) return unauthorized(request, env);
        const res = await env.TASK_HUB.getByName("global").fetch(
          "https://task-hub/connect",
        );
        return cors(res, request, env);
      }

      if (url.pathname === "/api/v1/state" && request.method === "GET") {
        if (!clientAuthorized(request, env)) return unauthorized(request, env);
        const res = await env.TASK_HUB.getByName("global").fetch(
          "https://task-hub/state",
        );
        return cors(res, request, env);
      }

      // Static assets (web UI) — no auth; the token is entered client-side.
      if (request.method === "GET") {
        const res = await env.ASSETS.fetch(request);
        return cors(res, request, env);
      }

      return cors(json({ error: "not_found" }, 404), request, env);
    } catch (err) {
      console.error("unhandled error:", err);
      return cors(json({ error: "internal_error" }, 500), request, env);
    }
  },
} satisfies ExportedHandler<Env>;

function bearer(request: Request): string | null {
  const header = request.headers.get("Authorization");
  return header?.startsWith("Bearer ") ? header.slice(7).trim() : null;
}

function authorized(request: Request, token: string | undefined): boolean {
  return !!token && token.length > 0 && bearer(request) === token;
}

/** The stream also accepts ?token= (EventSource cannot set headers). */
function clientAuthorized(request: Request, env: Env): boolean {
  return authorized(request, env.CLIENT_TOKEN) ||
    (!!env.CLIENT_TOKEN &&
      new URL(request.url).searchParams.get("token") === env.CLIENT_TOKEN);
}

function unauthorized(request: Request, env: Env): Response {
  const configured = !!(env.AGENT_TOKEN && env.CLIENT_TOKEN);
  return cors(
    json({
      error: "unauthorized",
      ...(configured
        ? {}
        : { hint: "copy backend/.dev.vars.example to backend/.dev.vars" }),
    }, 401),
    request,
    env,
  );
}

function cors(response: Response, request: Request, env: Env): Response {
  const origin = request.headers.get("Origin");
  if (!origin) return response;
  const allowed = (env.ALLOWED_ORIGINS ?? "*")
    .split(",")
    .map((s) => s.trim());
  if (allowed.includes("*") || allowed.includes(origin)) {
    response.headers.set("Access-Control-Allow-Origin", origin);
    response.headers.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    response.headers.set(
      "Access-Control-Allow-Headers",
      "Authorization, Content-Type",
    );
    response.headers.set("Vary", "Origin");
  }
  return response;
}
