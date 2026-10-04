import {
  ActionReply,
  decideAction,
  StoredTask,
  TaskCardPayload,
} from "./protocol";
import { encodeSSE, json, sseHeaders, sleep } from "./http";
import type { Env } from "./env";

const HEARTBEAT_MS = 15_000;
/** Processed tasks only serve 409 answers for late duplicates. */
const PROCESSED_TTL_MS = 60 * 60 * 1000;

/**
 * Single Durable Object (instance name "global") owning all task state
 * and SSE sessions. Input gates make the read→decide→write cycles in
 * here race-free — see docs/architecture.md before "optimizing" them.
 */
export class TaskHub {
  private readonly sessions = new Map<
    string,
    WritableStreamDefaultWriter<Uint8Array>
  >();
  private heartbeatRunning = false;

  constructor(
    private readonly state: DurableObjectState,
    private readonly env: Env,
  ) {}

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    switch (url.pathname) {
      case "/connect":
        return this.connect();
      case "/enqueue":
        return this.enqueue(request);
      case "/action":
        return this.action(request);
      case "/state":
        return json({
          tasks: (await this.pending()).map((t) => t.task),
        });
      default:
        return json({ error: "not_found" }, 404);
    }
  }

  /** SSE: snapshot first (reconnect resync), then live events. */
  private async connect(): Promise<Response> {
    const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>();
    const writer = writable.getWriter();
    const snapshot = await this.pending();
    await writer.write(
      encodeSSE("snapshot", { tasks: snapshot.map((t) => t.task) }),
    );
    this.sessions.set(crypto.randomUUID(), writer);
    void this.pumpHeartbeat();
    return new Response(readable, { headers: sseHeaders() });
  }

  private async enqueue(request: Request): Promise<Response> {
    const task = (await request.json()) as TaskCardPayload;
    const key = `task:${task.taskId}`;
    const existing = await this.state.storage.get<StoredTask>(key);
    if (existing && existing.status === "pending") {
      return json({ error: "duplicate_task", taskId: task.taskId }, 409);
    }
    const stored: StoredTask = {
      task,
      status: "pending",
      nonce: task.nonce,
      createdAt: Date.now(),
    };
    await this.state.storage.put(key, stored);
    await this.broadcast("createTaskCard", task);
    return json({ ok: true, taskId: task.taskId }, 201);
  }

  private async action(request: Request): Promise<Response> {
    const reply = (await request.json()) as ActionReply;
    const key = `task:${reply.taskId}`;

    // Input-gated critical section: nothing but storage I/O between the
    // read and the write (docs/architecture.md).
    const stored = await this.state.storage.get<StoredTask>(key);
    const decision = decideAction(stored, reply);
    if (decision.kind === "not_found") {
      return json({ error: "task_not_found", taskId: reply.taskId }, 404);
    }
    if (decision.kind === "bad_nonce") {
      return json({ error: "bad_nonce", taskId: reply.taskId }, 409);
    }
    if (decision.kind === "conflict") {
      return json({ error: decision.reason, taskId: reply.taskId }, 409);
    }
    if (!stored) {
      return json({ error: "task_not_found", taskId: reply.taskId }, 404);
    }

    const updated: StoredTask = {
      ...stored,
      status: "processed",
      processedAt: Date.now(),
      processedBy: reply.source,
    };
    await this.state.storage.put(key, updated);

    await this.broadcast("dismissTask", {
      taskId: reply.taskId,
      by: reply.source,
    });
    await this.scheduleSweep();
    if (updated.task.replyUrl) {
      this.state.waitUntil(this.deliverToAgent(updated.task.replyUrl, reply));
    }
    return json({ ok: true, taskId: reply.taskId, actionName: reply.actionName });
  }

  private async deliverToAgent(
    replyUrl: string,
    reply: ActionReply,
  ): Promise<void> {
    try {
      const res = await fetch(replyUrl, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(reply),
        signal: AbortSignal.timeout(10_000),
      });
      if (!res.ok) {
        console.error(`agent callback ${replyUrl} responded ${res.status}`);
      }
    } catch (err) {
      console.error(`agent callback ${replyUrl} failed:`, err);
    }
  }

  private async pending(): Promise<StoredTask[]> {
    const all = await this.state.storage.list<StoredTask>({ prefix: "task:" });
    return [...all.values()]
      .filter((t) => t.status === "pending")
      .sort((a, b) => a.createdAt - b.createdAt);
  }

  private async broadcast(event: string, data: unknown): Promise<void> {
    const frame = encodeSSE(event, data);
    await Promise.allSettled(
      [...this.sessions.entries()].map(async ([id, writer]) => {
        try {
          await writer.write(frame);
        } catch {
          this.sessions.delete(id);
          try {
            await writer.close();
          } catch {
            /* already gone */
          }
        }
      }),
    );
  }

  private async pumpHeartbeat(): Promise<void> {
    if (this.heartbeatRunning) return;
    this.heartbeatRunning = true;
    this.state.waitUntil(
      (async () => {
        const ping = new TextEncoder().encode(": ping\n\n");
        while (this.sessions.size > 0) {
          await sleep(HEARTBEAT_MS);
          await Promise.allSettled(
            [...this.sessions.entries()].map(async ([id, writer]) => {
              try {
                await writer.write(ping);
              } catch {
                this.sessions.delete(id);
              }
            }),
          );
        }
        this.heartbeatRunning = false;
      })(),
    );
  }

  private async scheduleSweep(): Promise<void> {
    if ((await this.state.storage.getAlarm()) !== null) return;
    await this.state.storage.setAlarm(Date.now() + PROCESSED_TTL_MS);
  }

  async alarm(): Promise<void> {
    const cutoff = Date.now() - PROCESSED_TTL_MS;
    const all = await this.state.storage.list<StoredTask>({ prefix: "task:" });
    const doomed: string[] = [];
    let processedLeft = false;
    for (const [key, stored] of all) {
      if (stored.status !== "processed") continue;
      if ((stored.processedAt ?? 0) < cutoff) doomed.push(key);
      else processedLeft = true;
    }
    if (doomed.length > 0) await this.state.storage.delete(doomed);
    if (processedLeft) {
      await this.state.storage.setAlarm(Date.now() + PROCESSED_TTL_MS);
    }
  }
}
