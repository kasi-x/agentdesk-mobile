import {
  validateActionReply,
  validateBulkRequest,
  validatePairRequest,
  validateRedeemRequest,
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

/** DO stub for the caller's scope: `"global"` for the shared CLIENT_TOKEN,
 *  `"user:<u>"` for a device token bound to user `u` (I-809). */
function hubStub(env: Env, scope: string): DurableObjectStub {
  return env.TASK_HUB.get(env.TASK_HUB.idFromName(scope));
}

/** Resolve a client credential to its DO scope, or null when unknown.
 *  `CLIENT_TOKEN` → `"global"`; any issued `dev_…` device token →
 *  `"user:<user>"` via the global DO's token registry (I-808/I-809).
 *  `?token=` is only honored on GET (EventSource cannot set headers). */
async function clientScope(
  request: Request,
  env: Env,
  allowQuery = false,
): Promise<string | null> {
  let token = bearer(request);
  if (!token && allowQuery && request.method === "GET") {
    token = new URL(request.url).searchParams.get("token");
  }
  if (!token || token.length === 0) return null;
  if (env.CLIENT_TOKEN && token === env.CLIENT_TOKEN) return "global";
  if (token.startsWith("dev_")) {
    try {
      const res = await hubStub(env, "global").fetch(
        "https://task-hub/auth",
        {
          method: "POST",
          body: JSON.stringify({ token }),
          headers: { "content-type": "application/json" },
        },
      );
      if (res.ok) {
        const body = (await res.json()) as { user?: unknown };
        if (typeof body.user === "string" && body.user.length > 0) {
          return `user:${body.user}`;
        }
      }
    } catch {
      return null;
    }
  }
  return null;
}

/** Forward a request to one DO internal path and return the rebuilt
 *  subresponse. GET never carries a body (fetch forbids it). */
async function forwardJson(
  request: Request,
  env: Env,
  scope: string,
  path: string,
  method = "POST",
): Promise<Response> {
  const init: RequestInit = {
    method,
    headers: { "content-type": "application/json" },
  };
  if (method !== "GET" && method !== "HEAD") {
    init.body = await request.text();
  }
  const doRes = await hubStub(env, scope).fetch(`https://task-hub${path}`, init);
  if (doRes.status === 204) return new Response(null, { status: 204 });
  return rebuilt(doRes);
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
        const scope = await clientScope(request, env);
        if (scope === null) return unauthorized(request, env);
        const parsed = validateActionReply(await request.json());
        if (!parsed.ok) {
          return cors(
            json({ error: "invalid_payload", detail: parsed.error }, 400),
            request,
            env,
          );
        }
        const doRes = await hubStub(env, scope).fetch(
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
        const scope = await clientScope(request, env);
        if (scope === null) return unauthorized(request, env);
        const parsed = validateUndoRequest(await request.json());
        if (!parsed.ok) {
          return cors(
            json({ error: "invalid_payload", detail: parsed.error }, 400),
            request,
            env,
          );
        }
        const doRes = await hubStub(env, scope).fetch(
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
        const scope = await clientScope(request, env);
        if (scope === null) return unauthorized(request, env);
        const parsed = validateBulkRequest(await request.json());
        if (!parsed.ok) {
          return cors(
            json({ error: "invalid_payload", detail: parsed.error }, 400),
            request,
            env,
          );
        }
        const doRes = await hubStub(env, scope).fetch(
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
        const scope = await clientScope(request, env, true);
        if (scope === null) return unauthorized(request, env);
        const res = await hubStub(env, scope).fetch(
          "https://task-hub/connect",
        );
        return cors(res, request, env);
      }

      if (url.pathname === "/api/v1/state" && request.method === "GET") {
        const scope = await clientScope(request, env, true);
        if (scope === null) return unauthorized(request, env);
        const res = await hubStub(env, scope).fetch(
          "https://task-hub/state",
        );
        return cors(res, request, env);
      }

      // Operator pause / resume (I-403): broadcast to the caller's scope.
      if (url.pathname === "/api/v1/pause" && request.method === "POST") {
        const scope = await clientScope(request, env);
        if (scope === null) return unauthorized(request, env);
        return cors(await forwardJson(request, env, scope, "/pause"), request, env);
      }
      if (url.pathname === "/api/v1/resume" && request.method === "POST") {
        const scope = await clientScope(request, env);
        if (scope === null) return unauthorized(request, env);
        return cors(await forwardJson(request, env, scope, "/resume"), request, env);
      }

      // Auto-approval rules (I-304/I-602/I-807).
      if (url.pathname === "/api/v1/rules" &&
        (request.method === "GET" || request.method === "PUT")) {
        const scope = await clientScope(request, env);
        if (scope === null) return unauthorized(request, env);
        return cors(
          await forwardJson(request, env, scope, "/rules", request.method),
          request,
          env,
        );
      }

      // QR-less pairing step 1 (I-808). Codes live in the global DO so
      // any client can redeem them; the code binds the target user, and
      // the code's user defaults to the pairing caller's own user.
      if (url.pathname === "/api/v1/pair" && request.method === "POST") {
        const scope = await clientScope(request, env);
        if (scope === null) return unauthorized(request, env);
        const incoming = await request.text();
        let body: unknown = {};
        try {
          body = incoming ? JSON.parse(incoming) : {};
        } catch {
          return cors(json({ error: "invalid_payload", detail: "payload must be JSON" }, 400), request, env);
        }
        const parsed = validatePairRequest(body);
        if (!parsed.ok) {
          return cors(json({ error: "invalid_payload", detail: parsed.error }, 400), request, env);
        }
        const value = parsed.value;
        if (value.user === undefined && scope.startsWith("user:")) {
          value.user = scope.slice("user:".length);
        }
        const doRes = await hubStub(env, "global").fetch(
          "https://task-hub/pair",
          {
            method: "POST",
            body: JSON.stringify(value),
            headers: { "content-type": "application/json" },
          },
        );
        const payload = (await doRes.json()) as Record<string, unknown>;
        if (doRes.ok && typeof payload.code === "string") {
          payload.url = `${new URL(request.url).origin}/pair?code=${payload.code}`;
        }
        const res = new Response(JSON.stringify(payload), {
          status: doRes.status,
          headers: { "content-type": "application/json" },
        });
        return cors(res, request, env);
      }

      // Pairing step 2 (I-808): possession of the code is the credential,
      // so this endpoint deliberately takes no auth.
      if (url.pathname === "/api/v1/pair/redeem" && request.method === "POST") {
        const parsed = validateRedeemRequest(await request.json());
        if (!parsed.ok) {
          return cors(json({ error: "invalid_payload", detail: parsed.error }, 400), request, env);
        }
        const doRes = await hubStub(env, "global").fetch(
          "https://task-hub/pair/redeem",
          {
            method: "POST",
            body: JSON.stringify(parsed.value),
            headers: { "content-type": "application/json" },
          },
        );
        return cors(rebuilt(doRes), request, env);
      }

      // Web Push subscriptions (I-701).
      if (url.pathname === "/api/v1/push/subscribe" &&
        (request.method === "POST" || request.method === "DELETE")) {
        const scope = await clientScope(request, env);
        if (scope === null) return unauthorized(request, env);
        const path = request.method === "POST" ? "/push/subscribe" : "/push/unsubscribe";
        return cors(
          await forwardJson(request, env, scope, path, request.method),
          request,
          env,
        );
      }
      if (url.pathname === "/api/v1/push/vapid" && request.method === "GET") {
        const scope = await clientScope(request, env, true);
        if (scope === null) return unauthorized(request, env);
        return cors(
          json({ publicKey: env.VAPID_PUBLIC_KEY ?? null }),
          request,
          env,
        );
      }

      // Native push registration (I-701 follow-up): same bearer auth as
      // the webpush subscribe endpoint; stored per scope-DO.
      if (url.pathname === "/api/v1/push/native" && request.method === "POST") {
        const scope = await clientScope(request, env);
        if (scope === null) return unauthorized(request, env);
        return cors(
          await forwardJson(request, env, scope, "/push/native/register"),
          request,
          env,
        );
      }
      if (url.pathname === "/api/v1/push/native" && request.method === "DELETE") {
        const scope = await clientScope(request, env);
        if (scope === null) return unauthorized(request, env);
        const doRes = await hubStub(env, scope).fetch(
          "https://task-hub/push/native/unregister",
          {
            method: "POST",
            body: await request.text(),
            headers: { "content-type": "application/json" },
          },
        );
        if (doRes.status === 204) return cors(new Response(null, { status: 204 }), request, env);
        return cors(rebuilt(doRes), request, env);
      }

      // Guardrail dry-run (I-1002): client bearer auth, per-scope rules.
      if (url.pathname === "/api/v1/rules/simulate" && request.method === "POST") {
        const scope = await clientScope(request, env);
        if (scope === null) return unauthorized(request, env);
        return cors(
          await forwardJson(request, env, scope, "/rules/simulate"),
          request,
          env,
        );
      }

      // Attachments (I-1001): upload needs the client token; download
      // accepts the client token OR the agent token (the agent fetches
      // the bytes after receiving the id inside action `data`).
      if (url.pathname === "/api/v1/attachments" && request.method === "POST") {
        const scope = await clientScope(request, env);
        if (scope === null) return unauthorized(request, env);
        return cors(
          await forwardJson(request, env, scope, "/attachments/put"),
          request,
          env,
        );
      }
      {
        const attachmentRoute = url.pathname.match(/^\/api\/v1\/attachments\/([^/]+)$/);
        if (attachmentRoute && request.method === "GET") {
          const id = attachmentRoute[1];
          const scope = await clientScope(request, env, true);
          const agentOk = authorized(request, env.AGENT_TOKEN);
          if (scope === null && !agentOk) return unauthorized(request, env);
          const target = scope ?? "global";
          const doRes = await hubStub(env, target).fetch(
            `https://task-hub/attachments/get?id=${encodeURIComponent(id)}`,
          );
          // Binary bytes: pass through with a fresh header set so the
          // immutable-subresponse problem (see rebuilt()) cannot recur.
          const passthrough = new Response(doRes.body, {
            status: doRes.status,
            headers: {
              "content-type": doRes.headers.get("content-type") ?? "application/octet-stream",
              ...(doRes.headers.get("content-length") !== null
                ? { "content-length": doRes.headers.get("content-length") as string }
                : {}),
              ...(doRes.headers.get("cache-control") !== null
                ? { "cache-control": doRes.headers.get("cache-control") as string }
                : {}),
            },
          });
          return cors(passthrough, request, env);
        }
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
    response.headers.set(
      "Access-Control-Allow-Methods",
      "GET, POST, PUT, DELETE, OPTIONS",
    );
    response.headers.set(
      "Access-Control-Allow-Headers",
      "Authorization, Content-Type",
    );
    response.headers.set("Vary", "Origin");
  }
  return response;
}
