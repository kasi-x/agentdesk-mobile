import {
  ActionReply,
  decideAction,
  decideUndo,
  expiryDue,
  ExpiryDecision,
  StoredTask,
  TaskCardPayload,
  UNDO_GRACE_MS,
  UndoRequest,
} from "./protocol";
import { encodeSSE, json, sseHeaders, sleep } from "./http";
import type { Env } from "./env";

const HEARTBEAT_MS = 15_000;
/** Processed tasks only serve 409 answers for late duplicates. */
const PROCESSED_TTL_MS = 60 * 60 * 1000;

function parseGraceMs(value: string | undefined): number {
  const parsed = value === undefined ? NaN : Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : UNDO_GRACE_MS;
}

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
    if (existing && existing.status !== "processed") {
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
    // A deadline on the new card may be earlier than anything pending.
    await this.rescheduleAlarm();
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

    // Undo grace (I-104): the card is dismissed on every device now, but
    // the reply only reaches replyUrl once the commit alarm fires.
    const commitAt = Date.now() + this.graceMs;
    const updated: StoredTask = {
      ...stored,
      status: "committing",
      commitAt,
      pendingReply: reply,
    };
    await this.state.storage.put(key, updated);

    await this.broadcast("dismissTask", {
      taskId: reply.taskId,
      by: reply.source,
    });
    await this.rescheduleAlarm();
    return json({
      ok: true,
      taskId: reply.taskId,
      actionName: reply.actionName,
      commitAt,
    });
  }

  private async undo(request: Request): Promise<Response> {
    const req = (await request.json()) as UndoRequest;
    const key = `task:${req.taskId}`;

    const stored = await this.state.storage.get<StoredTask>(key);
    const decision = decideUndo(stored, req);
    if (decision.kind === "not_found") {
      return json({ error: "task_not_found", taskId: req.taskId }, 404);
    }
    if (decision.kind === "bad_nonce") {
      return json({ error: "bad_nonce", taskId: req.taskId }, 409);
    }
    if (decision.kind === "conflict") {
      return json({ error: decision.reason, taskId: req.taskId }, 409);
    }
    if (!stored) {
      return json({ error: "task_not_found", taskId: req.taskId }, 404);
    }

    // Rotate the nonce so the re-broadcast card gets a fresh one-shot
    // token — the old nonce must not triage the task a second time.
    const task: TaskCardPayload = {
      ...stored.task,
      nonce: `tok_${crypto.randomUUID()}`,
    };
    const updated: StoredTask = {
      ...stored,
      task,
      status: "pending",
      nonce: task.nonce,
      commitAt: undefined,
      pendingReply: undefined,
    };
    await this.state.storage.put(key, updated);

    await this.broadcast("createTaskCard", task);
    await this.rescheduleAlarm();
    return json({ ok: true, taskId: req.taskId, nonce: task.nonce });
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

  private get graceMs(): number {
    return parseGraceMs(this.env.UNDO_GRACE_MS);
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
   * One alarm serves three jobs (I-104, I-203): commit deadlines for
   * `committing` tasks, expiry deadlines for pending cards with
   * `expiresAt`, and TTL cleanup for `processed` ones. Call after every
   * status change; it recomputes the next deadline from scratch so
   * early-finishing work never strands a later alarm.
   */
  private async rescheduleAlarm(): Promise<void> {
    const now = Date.now();
    let next: number | null = null;
    const all = await this.state.storage.list<StoredTask>({ prefix: "task:" });
    for (const stored of all.values()) {
      const at =
        stored.status === "committing"
          ? (stored.commitAt ?? now)
          : stored.status === "processed"
            ? (stored.processedAt ?? now) + PROCESSED_TTL_MS
            : stored.status === "pending" &&
                stored.task.expiresAt !== undefined &&
                stored.escalatedAt === undefined
              ? Date.parse(stored.task.expiresAt) || null
              : null;
      if (at !== null && Number.isFinite(at) && (next === null || at < next)) {
        next = at;
      }
    }
    const current = await this.state.storage.getAlarm();
    if (next === null) {
      if (current !== null) await this.state.storage.deleteAlarm();
      return;
    }
    if (current === null || next < current) {
      await this.state.storage.setAlarm(next);
    }
  }

  async alarm(): Promise<void> {
    const now = Date.now();
    const ttlCutoff = now - PROCESSED_TTL_MS;
    const all = await this.state.storage.list<StoredTask>({ prefix: "task:" });
    const doomed: string[] = [];
    const delivered: Array<{ key: string; reply: ActionReply; url: string }> =
      [];
    for (const [key, stored] of all) {
      if (stored.status === "committing" && (stored.commitAt ?? 0) <= now) {
        const updated: StoredTask = {
          ...stored,
          status: "processed",
          processedAt: stored.commitAt ?? now,
          processedBy: stored.pendingReply?.source,
          commitAt: undefined,
          pendingReply: undefined,
        };
        await this.state.storage.put(key, updated);
        const reply = stored.pendingReply;
        if (reply && stored.task.replyUrl) {
          delivered.push({ key, reply, url: stored.task.replyUrl });
        }
      } else if (stored.status === "pending") {
        const decision = expiryDue(stored, now);
        if (decision) await this.runExpiry(key, stored, decision, now);
      } else if (stored.status === "processed") {
        if ((stored.processedAt ?? 0) < ttlCutoff) doomed.push(key);
      }
    }
    if (doomed.length > 0) await this.state.storage.delete(doomed);
    for (const { reply, url } of delivered) {
      this.state.waitUntil(this.deliverToAgent(url, reply));
    }
    await this.rescheduleAlarm();
  }

  /**
   * Run a card's default behavior at its deadline (I-203). approve /
   * reject execute the declared swipe binding immediately — nobody is
   * around to undo, so there is no committing grace window. drop
   * finishes the task unanswered (the agent still learns via replyUrl).
   * escalate keeps the card waiting, bumps severity to critical and
   * re-broadcasts with a rotated nonce (clients replace in place).
   */
  private async runExpiry(
    key: string,
    stored: StoredTask,
    decision: ExpiryDecision,
    now: number,
  ): Promise<void> {
    if (decision.action === "escalate") {
      const task: TaskCardPayload = {
        ...stored.task,
        severity: "critical",
        nonce: `tok_${crypto.randomUUID()}`,
        expiresAt: undefined,
        onExpire: undefined,
      };
      const updated: StoredTask = {
        ...stored,
        task,
        nonce: task.nonce,
        escalatedAt: now,
      };
      await this.state.storage.put(key, updated);
      await this.broadcast("createTaskCard", task);
      return;
    }

    const reply: ActionReply =
      decision.action === "drop"
        ? {
            taskId: stored.task.taskId,
            nonce: stored.nonce,
            actionName: "expire",
            timestamp: new Date(now).toISOString(),
            source: "on_expire",
            data: { decision: "EXPIRED" },
          }
        : {
            taskId: stored.task.taskId,
            nonce: stored.nonce,
            actionName: decision.binding!.actionName,
            timestamp: new Date(now).toISOString(),
            source: "on_expire",
            ...(decision.binding!.payload
              ? { data: decision.binding!.payload }
              : {}),
          };
    const updated: StoredTask = {
      ...stored,
      status: "processed",
      processedAt: now,
      processedBy: "on_expire",
    };
    await this.state.storage.put(key, updated);
    await this.broadcast("dismissTask", {
      taskId: stored.task.taskId,
      by: "on_expire",
    });
    if (stored.task.replyUrl) {
      this.state.waitUntil(this.deliverToAgent(stored.task.replyUrl, reply));
    }
  }
}
