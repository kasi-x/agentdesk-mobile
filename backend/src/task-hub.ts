import {
  ActionReply,
  decideAction,
  decideUndo,
  StoredTask,
  TaskCardPayload,
} from "./protocol";
import { encodeSSE, json, sseHeaders, sleep } from "./http";
import type { Env } from "./env";

const HEARTBEAT_MS = 15_000;
/** Processed tasks only serve 409 answers for late duplicates. */
const PROCESSED_TTL_MS = 60 * 60 * 1000;
/** Undo grace window: triage replies wait this long before reaching the agent (I-104). */
export const UNDO_GRACE_MS = 5_000;

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
      case "/undo":
        return this.undo(request);
      case "/state":
        return json({
          tasks: (await this.pending()).map((t) => t.task),
        });
      default:
        return json({ error: "not_found" }, 404);
    }
  }

  /** SSE: snapshot first (reconnect resync), then live events. */
  private connect(): Response {
    const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>();
    const writer = writable.getWriter();
    const id = crypto.randomUUID();
    this.sessions.set(id, writer);
    // Write only after the Response is returned — awaiting a
    // TransformStream write before the runtime starts reading the body
    // deadlocks (the first snapshot would never flush).
    this.state.waitUntil(
      (async () => {
        try {
          const snapshot = await this.pending();
          await writer.write(
            encodeSSE("snapshot", { tasks: snapshot.map((t) => t.task) }),
          );
        } catch {
          this.sessions.delete(id);
        }
        void this.pumpHeartbeat();
      })(),
    );
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

    const now = Date.now();
    const updated: StoredTask = {
      ...stored,
      status: "committing",
      commitAt: now + UNDO_GRACE_MS,
      processedBy: reply.source,
    };
    await this.state.storage.put(key, updated);
    // Keep the original reply for the delayed agent delivery.
    await this.state.storage.put(`reply:${reply.taskId}`, reply);

    await this.broadcast("dismissTask", {
      taskId: reply.taskId,
      by: reply.source,
    });
    await this.scheduleNextAlarm();
    return json({
      ok: true,
      taskId: reply.taskId,
      actionName: reply.actionName,
      undoableUntil: updated.commitAt,
    });
  }

  /**
   * `POST /undo`: return a committing task to pending with a fresh nonce
   * and re-broadcast it as a new card (I-104). Input-gated like action().
   */
  private async undo(request: Request): Promise<Response> {
    const body = (await request.json()) as { taskId?: unknown };
    if (typeof body.taskId !== "string" || body.taskId.length === 0) {
      return json({ error: "invalid_payload", detail: "taskId (string) is required" }, 400);
    }
    const key = `task:${body.taskId}`;
    const stored = await this.state.storage.get<StoredTask>(key);
    const decision = decideUndo(stored);
    if (decision.kind === "not_found") {
      return json({ error: "task_not_found", taskId: body.taskId }, 404);
    }
    if (decision.kind === "too_late") {
      return json({ error: "too_late", taskId: body.taskId }, 409);
    }
    if (!stored) {
      return json({ error: "task_not_found", taskId: body.taskId }, 404);
    }
    const card: TaskCardPayload = {
      ...stored.task,
      taskId: stored.task.taskId,
      nonce: crypto.randomUUID(),
      createdAt: stored.task.createdAt,
    };
    const revived: StoredTask = {
      task: card,
      status: "pending",
      nonce: card.nonce,
      createdAt: stored.createdAt,
    };
    await this.state.storage.put(key, revived);
    await this.state.storage.delete(`reply:${body.taskId}`);
    await this.broadcast("createTaskCard", card);
    await this.scheduleNextAlarm();
    return json({ ok: true, taskId: body.taskId });
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

  /**
   * Single alarm computation (I-104): the next deadline is the earliest of
   * every committing task's commitAt and every processed task's sweep time.
   * Always recomputed after action/undo so the alarm never lags.
   */
  private async scheduleNextAlarm(): Promise<void> {
    const now = Date.now();
    const all = await this.state.storage.list<StoredTask>({ prefix: "task:" });
    let next: number | null = null;
    for (const stored of all.values()) {
      if (stored.status === "committing" && stored.commitAt !== undefined) {
        next = next === null ? stored.commitAt : Math.min(next, stored.commitAt);
      } else if (stored.status === "processed" && stored.processedAt !== undefined) {
        const sweepAt = stored.processedAt + PROCESSED_TTL_MS;
        if (sweepAt > now) {
          next = next === null ? sweepAt : Math.min(next, sweepAt);
        }
      }
    }
    if (next === null) {
      await this.state.storage.deleteAlarm();
    } else {
      await this.state.storage.setAlarm(Math.max(next, now));
    }
  }

  async alarm(): Promise<void> {
    const now = Date.now();
    const all = await this.state.storage.list<StoredTask>({ prefix: "task:" });
    // 1) Committing tasks past their grace window → processed + agent delivery.
    for (const [key, stored] of all) {
      if (stored.status !== "committing") continue;
      if ((stored.commitAt ?? Number.POSITIVE_INFINITY) > now) continue;
      const reply = await this.state.storage.get<ActionReply>(`reply:${stored.task.taskId}`);
      const finalized: StoredTask = {
        ...stored,
        status: "processed",
        commitAt: undefined,
        processedAt: now,
      };
      await this.state.storage.put(key, finalized);
      await this.state.storage.delete(`reply:${stored.task.taskId}`);
      if (stored.task.replyUrl && reply) {
        this.state.waitUntil(this.deliverToAgent(stored.task.replyUrl, reply));
      }
    }
    // 2) Sweep processed tasks older than the TTL.
    const cutoff = now - PROCESSED_TTL_MS;
    const doomed: string[] = [];
    for (const [key, stored] of all) {
      const current = await this.state.storage.get<StoredTask>(key);
      if (!current || current.status !== "processed") continue;
      if ((current.processedAt ?? 0) < cutoff) doomed.push(key);
    }
    if (doomed.length > 0) {
      await this.state.storage.delete(doomed);
      for (const key of doomed) {
        await this.state.storage.delete(`reply:${key.slice("task:".length)}`);
      }
    }
    await this.scheduleNextAlarm();
  }
}
