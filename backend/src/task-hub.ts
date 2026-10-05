import {
  ActionReply,
  Approval,
  computePriority,
  decideAction,
  decideUndo,
  DeviceRecord,
  expiryDue,
  ExpiryDecision,
  PAIR_TTL_MS,
  PairCode,
  PROTOCOL_VERSION,
  Rule,
  ruleMatches,
  SnapshotPayload,
  StoredTask,
  TaskCardPayload,
  UNDO_GRACE_MS,
  UndoRequest,
  validatePairRequest,
  validateRedeemRequest,
  validateRules,
} from "./protocol";
import { encodeSSE, json, sseHeaders, sleep } from "./http";
import type { PushSubscription } from "./webpush";
import { sendWebPush } from "./webpush";
import type { Env } from "./env";

const HEARTBEAT_MS = 15_000;
/** Processed tasks only serve 409 answers for late duplicates. */
const PROCESSED_TTL_MS = 60 * 60 * 1000;
/** replyUrl delivery retry budget and exponential backoff (I-604). */
const MAX_DELIVERY_ATTEMPTS = 5;
const DELIVERY_BACKOFF_CAP_MS = 16_000;
/** Long-poll cap for `GET /api/v1/tasks/{id}/result` (I-901). */
const MAX_RESULT_WAIT_SEC = 60;

/** HMAC-SHA256 over `ts.body`, hex — the `v1` half of the signature header (I-801). */
async function hmacHex(secret: string, payload: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(payload));
  return [...new Uint8Array(mac)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/** SHA-256 hex digest — device tokens are stored hashed (I-808). */
async function sha256Hex(payload: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(payload),
  );
  return [...new Uint8Array(digest)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/** Fleet pause state (I-403): present = paused; `until` optional. */
interface PauseState {
  until?: string;
}

const KEY_PAUSE = "hub:pause";
const KEY_RULES = "hub:rules";
const KEY_LEASE = "hub:leaseUsed";
const PREFIX_PAIR = "pair:";
const PREFIX_DEVICE = "device:";
const PREFIX_PUSH = "push:";

type TriageOutcome =
  | {
      ok: true;
      commitAt?: number;
      snoozedUntil?: number;
      delegatedTo?: string;
      approvalProgress?: { count: number; required: number };
    }
  | { ok: false; error: string };

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
      case "/bulk":
        return this.bulk(request);
      case "/undo":
        return this.undo(request);
      case "/update":
        return this.update(request);
      case "/withdraw":
        return this.withdraw(request);
      case "/result":
        return this.result(url);
      case "/state":
        return json(await this.snapshot());
      case "/pause":
        return this.pause(request);
      case "/resume":
        return this.resume();
      case "/rules":
        return this.rules(request);
      case "/pair":
        return this.pair(request);
      case "/pair/redeem":
        return this.redeem(request);
      case "/auth":
        return this.auth(request);
      case "/push/subscribe":
        return this.pushSubscribe(request);
      case "/push/unsubscribe":
        return this.pushUnsubscribe(request);
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
          await writer.write(encodeSSE("snapshot", await this.snapshot()));
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
    const now = Date.now();
    const stored: StoredTask = {
      task,
      status: "pending",
      nonce: task.nonce,
      createdAt: now,
    };

    // I-304/I-807: an enabled, unexhausted rule auto-approves matching NEW
    // cards. Only cards enqueued after the rule is stored are evaluated —
    // the pending backlog is never swept. An auto-approved card never
    // reaches the stack, so no createTaskCard is broadcast for it.
    const rule = await this.matchingRule(stored.task, now);
    if (rule) {
      await this.state.storage.put(key, stored);
      await this.bumpLeaseUsed(rule.id);
      await this.autoApprove(key, stored, rule);
      await this.rescheduleAlarm();
      return json(
        { ok: true, taskId: task.taskId, autoApproved: true, byRule: rule.id },
        201,
      );
    }

    await this.state.storage.put(key, stored);
    await this.broadcast("createTaskCard", this.present(stored, now));
    // Web Push (I-701): new cards only — never on update/rebroadcast.
    this.state.waitUntil(this.notifySubscribers(stored.task));
    // A deadline on the new card may be earlier than anything pending.
    await this.rescheduleAlarm();
    return json({ ok: true, taskId: task.taskId }, 201);
  }

  /** First enabled rule whose `match` accepts this card and whose lease
   *  still has budget (I-304/I-602/I-807). */
  private async matchingRule(
    task: TaskCardPayload,
    now: number,
  ): Promise<Rule | undefined> {
    const rules = await this.getRules();
    if (rules.length === 0) return undefined;
    const used = await this.getLeaseUsed();
    return rules.find(
      (rule) =>
        ruleMatches(rule, task, now) &&
        (rule.lease?.maxCount === undefined ||
          (used[rule.id] ?? 0) < rule.lease.maxCount),
    );
  }

  private async bumpLeaseUsed(ruleId: string): Promise<void> {
    const used = await this.getLeaseUsed();
    used[ruleId] = (used[ruleId] ?? 0) + 1;
    await this.state.storage.put(KEY_LEASE, used);
  }

  /** Auto-approval goes through the normal commit record + delivery
   *  (grace 0): recorded as an outcome with `source: "auto_rule"` and
   *  forwarded to `replyUrl` when set. */
  private async autoApprove(
    key: string,
    stored: StoredTask,
    rule: Rule,
  ): Promise<void> {
    const now = Date.now();
    const reply: ActionReply = {
      taskId: stored.task.taskId,
      nonce: stored.nonce,
      actionName: "approve",
      timestamp: new Date(now).toISOString(),
      source: "auto_rule",
      data: { byRule: rule.id },
    };
    const updated: StoredTask = {
      ...stored,
      status: "processed",
      processedAt: now,
      processedBy: "auto_rule",
      outcome: {
        name: "approve",
        data: { byRule: rule.id },
        source: "auto_rule",
        at: reply.timestamp,
      },
    };
    await this.state.storage.put(key, updated);
    await this.broadcast("dismissTask", {
      taskId: stored.task.taskId,
      by: "auto_rule",
    });
    if (stored.task.replyUrl) {
      this.state.waitUntil(this.attemptDelivery(key, stored.task.replyUrl, reply));
    }
  }

  /** Best-effort fan-out to every subscribed browser (I-701). Dead
   *  subscriptions (404/410) are pruned on the spot. */
  private async notifySubscribers(task: TaskCardPayload): Promise<void> {
    try {
      const subs = await this.state.storage.list<PushSubscription>({
        prefix: PREFIX_PUSH,
      });
      if (subs.size === 0) return;
      const payload = {
        title: "AgentDesk",
        body: task.summary,
        taskId: task.taskId,
      };
      for (const [subKey, sub] of subs) {
        try {
          const result = await sendWebPush(this.env, sub, payload);
          if (result === "gone") await this.state.storage.delete(subKey);
        } catch (err) {
          console.error(`web push to ${sub.endpoint} failed:`, err);
        }
      }
    } catch (err) {
      console.error("web push fan-out failed:", err);
    }
  }

  /** Single accepted triage, shared by `/action` and `/bulk`. Returns a
   *  per-item outcome; callers own the HTTP status mapping and the
   *  (single) alarm reschedule. */
  private async applyTriage(reply: ActionReply): Promise<TriageOutcome> {
    const key = `task:${reply.taskId}`;

    // Input-gated critical section: nothing but storage I/O between the
    // read and the write (docs/architecture.md).
    const stored = await this.state.storage.get<StoredTask>(key);
    const decision = decideAction(stored, reply);
    if (decision.kind === "not_found") return { ok: false, error: "task_not_found" };
    if (decision.kind === "bad_nonce") return { ok: false, error: "bad_nonce" };
    if (decision.kind === "conflict") return { ok: false, error: decision.reason };
    if (!stored) return { ok: false, error: "task_not_found" };

    if (decision.kind === "snooze") {
      const until = Date.parse(reply.until ?? "");
      if (!Number.isFinite(until)) return { ok: false, error: "invalid_until" };
      await this.state.storage.put(key, { ...stored, snoozedUntil: until });
      await this.broadcast("dismissTask", {
        taskId: reply.taskId,
        by: "snooze",
        snoozedUntil: new Date(until).toISOString(),
      });
      return { ok: true, snoozedUntil: until };
    }

    // Delegation (I-501): the card stays pending under a new owner
    // (`task.delegatedTo`) and keeps its nonce — it still needs a real
    // decision. Both the revised card and a `delegateTask` event go out.
    if (decision.kind === "delegate") {
      const to = reply.data === undefined ? undefined : reply.data.to;
      if (typeof to !== "string" || to.length === 0) {
        return { ok: false, error: "invalid_to" };
      }
      const delegated: StoredTask = {
        ...stored,
        task: { ...stored.task, delegatedTo: to },
      };
      await this.state.storage.put(key, delegated);
      await this.broadcast("createTaskCard", {
        ...this.present(delegated, Date.now()),
        revised: true,
      });
      await this.broadcast("delegateTask", { taskId: reply.taskId, to });
      return { ok: true, delegatedTo: to };
    }

    // Multi-party approval (I-502): the Nth approval is not in yet, so
    // the card stays pending. Record this one, rotate the nonce so the
    // same device cannot approve twice, and broadcast progress.
    if (decision.kind === "approve_partial") {
      const approval: Approval = {
        source: reply.source,
        at: reply.timestamp,
      };
      const approvals = [...(stored.approvals ?? []), approval];
      const required = stored.task.requiredApprovals ?? 1;
      const nonce = `tok_${crypto.randomUUID()}`;
      const updated: StoredTask = {
        ...stored,
        task: { ...stored.task, nonce },
        nonce,
        approvals,
      };
      await this.state.storage.put(key, updated);
      await this.broadcast("createTaskCard", this.present(updated, Date.now()));
      await this.broadcast("approvalProgress", {
        taskId: reply.taskId,
        count: approvals.length,
        required,
      });
      return {
        ok: true,
        approvalProgress: { count: approvals.length, required },
      };
    }

    // Undo grace (I-104): the card is dismissed on every device now, but
    // the reply only reaches replyUrl once the commit alarm fires.
    const commitAt = Date.now() + this.graceMs;
    // A final (Nth) multi-party approval lands on the normal commit
    // path; record it so the approvals trail stays complete.
    const finalApproval =
      reply.actionName === "approve" && (stored.task.requiredApprovals ?? 1) > 1
        ? [{ source: reply.source, at: reply.timestamp }]
        : [];
    const updated: StoredTask = {
      ...stored,
      status: "committing",
      commitAt,
      pendingReply: reply,
      ...(finalApproval.length > 0
        ? { approvals: [...(stored.approvals ?? []), ...finalApproval] }
        : {}),
    };
    await this.state.storage.put(key, updated);
    await this.broadcast("dismissTask", {
      taskId: reply.taskId,
      by: reply.source,
    });
    return { ok: true, commitAt };
  }

  private async action(request: Request): Promise<Response> {
    const reply = (await request.json()) as ActionReply;
    const outcome = await this.applyTriage(reply);
    if (!outcome.ok) {
      const status =
        outcome.error === "task_not_found"
          ? 404
          : outcome.error === "invalid_until" || outcome.error === "invalid_to"
            ? 400
            : 409;
      return json({ error: outcome.error, taskId: reply.taskId }, status);
    }
    await this.rescheduleAlarm();
    return json({
      ok: true,
      taskId: reply.taskId,
      ...(outcome.commitAt !== undefined ? { commitAt: outcome.commitAt } : {}),
      ...(outcome.snoozedUntil !== undefined
        ? { snoozedUntil: new Date(outcome.snoozedUntil).toISOString() }
        : {}),
      ...(outcome.delegatedTo !== undefined
        ? { delegatedTo: outcome.delegatedTo }
        : {}),
      ...(outcome.approvalProgress !== undefined
        ? { approvalProgress: outcome.approvalProgress }
        : {}),
    });
  }

  /** Bulk triage (I-201): each item CASes independently. */
  private async bulk(request: Request): Promise<Response> {
    const { actions } = (await request.json()) as {
      actions: Array<{
        taskId: string;
        nonce: string;
        actionName: string;
        source: string;
        action?: "delegate";
        data?: Record<string, unknown>;
      }>;
    };
    const results: Array<Record<string, unknown>> = [];
    for (const item of actions) {
      const outcome = await this.applyTriage({
        taskId: item.taskId,
        nonce: item.nonce,
        actionName: item.actionName,
        timestamp: new Date().toISOString(),
        source: item.source,
        ...(item.action === "delegate" ? { action: "delegate" as const } : {}),
        ...(item.data ? { data: item.data } : {}),
      });
      results.push(
        outcome.ok
          ? {
              taskId: item.taskId,
              ok: true,
              ...(outcome.commitAt !== undefined ? { commitAt: outcome.commitAt } : {}),
              ...(outcome.delegatedTo !== undefined
                ? { delegatedTo: outcome.delegatedTo }
                : {}),
              ...(outcome.approvalProgress !== undefined
                ? { approvalProgress: outcome.approvalProgress }
                : {}),
            }
          : { taskId: item.taskId, error: outcome.error },
      );
    }
    await this.rescheduleAlarm();
    return json({ results });
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

    await this.broadcast("createTaskCard", this.present(updated, Date.now()));
    await this.rescheduleAlarm();
    return json({ ok: true, taskId: req.taskId, nonce: task.nonce });
  }

  /**
   * Agent-side card update (I-204): a full replacement card, a rotated
   * nonce and a `revised: true` re-broadcast. Only a still-pending card
   * can be updated; an update re-surfaces a snoozed card.
   */
  private async update(request: Request): Promise<Response> {
    const task = (await request.json()) as TaskCardPayload;
    const key = `task:${task.taskId}`;
    const stored = await this.state.storage.get<StoredTask>(key);
    if (!stored) {
      return json({ error: "task_not_found", taskId: task.taskId }, 404);
    }
    if (stored.status !== "pending") {
      return json({ error: "already_processed", taskId: task.taskId }, 409);
    }

    const nonce = `tok_${crypto.randomUUID()}`;
    const next: TaskCardPayload = {
      ...task,
      taskId: task.taskId,
      nonce,
      protocolVersion: task.protocolVersion ?? PROTOCOL_VERSION,
    };
    const updated: StoredTask = {
      ...stored,
      task: next,
      nonce,
      snoozedUntil: undefined,
      // The replacement carries a fresh payload, so a previous
      // escalate-deadline consumption no longer applies.
      escalatedAt: undefined,
    };
    await this.state.storage.put(key, updated);

    await this.broadcast("createTaskCard", {
      ...this.present(updated, Date.now()),
      revised: true,
    });
    await this.rescheduleAlarm();
    return json({ ok: true, taskId: task.taskId, nonce });
  }

  /**
   * Agent-side withdraw (I-205): the decision is no longer needed, so
   * the card leaves every device and finishes as `processed`.
   */
  private async withdraw(request: Request): Promise<Response> {
    const { taskId } = (await request.json()) as { taskId: string };
    const key = `task:${taskId}`;
    const stored = await this.state.storage.get<StoredTask>(key);
    if (!stored) return json({ error: "task_not_found", taskId }, 404);
    if (stored.status !== "pending") {
      return json({ error: "already_processed", taskId }, 409);
    }

    const now = Date.now();
    const updated: StoredTask = {
      ...stored,
      status: "processed",
      processedAt: now,
      processedBy: "withdrawn",
      outcome: {
        name: "withdraw",
        source: "withdrawn",
        at: new Date(now).toISOString(),
      },
    };
    await this.state.storage.put(key, updated);
    // `withdrawTask` is the canonical event; `dismissTask` with
    // by:"withdraw" lets clients that only handle dismissTask remove the
    // card too (both are idempotent by taskId).
    await this.broadcast("withdrawTask", { taskId });
    await this.broadcast("dismissTask", { taskId, by: "withdraw" });
    await this.rescheduleAlarm();
    return json({ ok: true, taskId });
  }

  /**
   * Agent SDK long-poll (I-901): resolves as soon as the task reaches a
   * terminal state, or after `wait` seconds (max 60), whichever first.
   */
  private async result(url: URL): Promise<Response> {
    const taskId = url.searchParams.get("taskId") ?? "";
    const requested = Number(url.searchParams.get("wait") ?? "0");
    const waitSec = Number.isFinite(requested)
      ? Math.min(MAX_RESULT_WAIT_SEC, Math.max(0, requested))
      : 0;
    const key = `task:${taskId}`;
    const deadline = Date.now() + waitSec * 1000;

    for (;;) {
      const stored = await this.state.storage.get<StoredTask>(key);
      if (!stored) return json({ error: "task_not_found", taskId }, 404);
      const now = Date.now();
      if (stored.status === "processed" || now >= deadline) {
        return json(this.resultBody(taskId, stored));
      }
      await sleep(Math.max(50, Math.min(500, deadline - now)));
    }
  }

  private resultBody(taskId: string, stored: StoredTask): Record<string, unknown> {
    const action = stored.outcome ??
      (stored.pendingReply
        ? {
            name: stored.pendingReply.actionName,
            ...(stored.pendingReply.data ? { data: stored.pendingReply.data } : {}),
            source: stored.pendingReply.source,
            at: stored.pendingReply.timestamp,
          }
        : undefined);
    return {
      taskId,
      status: stored.status,
      protocolVersion: PROTOCOL_VERSION,
      ...(action ? { action } : {}),
      ...(stored.delivery
        ? {
            delivery: {
              attempts: stored.delivery.attempts,
              ...(stored.delivery.lastError !== undefined
                ? { lastError: stored.delivery.lastError }
                : {}),
              ...(stored.delivery.failed ? { failed: true } : {}),
            },
          }
        : {}),
    };
  }

  /** Card as broadcast: the stored payload plus the current (age-aware)
   *  `priority` score. */
  private present(stored: StoredTask, now: number): TaskCardPayload {
    return {
      ...stored.task,
      priority: computePriority(stored.task, stored.createdAt, now),
    };
  }

  /** Snapshot envelope (SSE `snapshot` + `GET /state`). */
  private async snapshot(): Promise<SnapshotPayload> {
    const now = Date.now();
    const all = await this.state.storage.list<StoredTask>({ prefix: "task:" });
    const tasks = this.orderedPending([...all.values()], now);
    const snoozed: SnapshotPayload["snoozed"] = [];
    const delivery: SnapshotPayload["delivery"] = [];
    const approvalProgress: SnapshotPayload["approvalProgress"] = {};
    for (const stored of all.values()) {
      if (
        stored.status === "pending" &&
        stored.snoozedUntil !== undefined &&
        stored.snoozedUntil > now
      ) {
        snoozed.push({
          taskId: stored.task.taskId,
          until: new Date(stored.snoozedUntil).toISOString(),
        });
      }
      if (stored.delivery?.failed) {
        delivery.push({
          taskId: stored.task.taskId,
          ...(stored.delivery.lastError !== undefined
            ? { lastError: stored.delivery.lastError }
            : {}),
          attempts: stored.delivery.attempts,
        });
      }
      if (
        stored.status === "pending" &&
        stored.approvals !== undefined &&
        stored.approvals.length > 0
      ) {
        approvalProgress[stored.task.taskId] = stored.approvals.length;
      }
    }
    return {
      protocolVersion: PROTOCOL_VERSION,
      tasks: tasks.map((t) => this.present(t, now)),
      snoozed,
      delivery,
      paused: await this.isPaused(now),
      rules: await this.getRules(),
      approvalProgress,
    };
  }

  /** Pending, non-snoozed tasks ordered priority desc, createdAt asc (I-206). */
  private orderedPending(all: StoredTask[], now: number): StoredTask[] {
    return all
      .filter(
        (t) =>
          t.status === "pending" &&
          !(t.snoozedUntil !== undefined && t.snoozedUntil > now),
      )
      .sort((a, b) => {
        const diff =
          computePriority(b.task, b.createdAt, now) -
          computePriority(a.task, a.createdAt, now);
        return diff !== 0 ? diff : a.createdAt - b.createdAt;
      });
  }

  private async getRules(): Promise<Rule[]> {
    return (await this.state.storage.get<Rule[]>(KEY_RULES)) ?? [];
  }

  private async getLeaseUsed(): Promise<Record<string, number>> {
    return (await this.state.storage.get<Record<string, number>>(KEY_LEASE)) ?? {};
  }

  /** Fleet pause flag (I-403). `until` in the past counts as resumed. */
  private async isPaused(now: number): Promise<boolean> {
    const pause = await this.state.storage.get<PauseState>(KEY_PAUSE);
    if (!pause) return false;
    if (pause.until === undefined) return true;
    const at = Date.parse(pause.until);
    return Number.isFinite(at) && at > now;
  }

  /**
   * Operator pause (I-403): advisory only. New enqueues are still
   * accepted; the pause travels to agents via `pauseState` (SSE), the
   * snapshot `paused` flag and the long-poll result — SDKs are expected
   * to stop starting new work while paused (docs/protocol.md).
   */
  private async pause(request: Request): Promise<Response> {
    let body: unknown = {};
    try {
      body = await request.json();
    } catch {
      body = {};
    }
    let until: string | undefined;
    if (
      typeof body === "object" &&
      body !== null &&
      (body as Record<string, unknown>).until !== undefined
    ) {
      const raw = (body as Record<string, unknown>).until;
      if (typeof raw !== "string" || !Number.isFinite(Date.parse(raw))) {
        return json({ error: "invalid_until" }, 400);
      }
      until = raw;
    }
    await this.state.storage.put<PauseState>(
      KEY_PAUSE,
      until !== undefined ? { until } : {},
    );
    const event = {
      paused: true,
      ...(until !== undefined ? { until } : {}),
    };
    await this.broadcast("pauseState", event);
    return json({ ok: true, ...event });
  }

  /** Operator resume (I-403). */
  private async resume(): Promise<Response> {
    await this.state.storage.delete(KEY_PAUSE);
    await this.broadcast("pauseState", { paused: false });
    return json({ ok: true, paused: false });
  }

  /** Auto-approval rule store (I-304/I-602/I-807). PUT replaces the whole
   *  rule set; the new rules apply to cards enqueued from this moment —
   *  the pending backlog is never swept. */
  private async rules(request: Request): Promise<Response> {
    if (request.method === "GET") {
      return json({ rules: await this.getRules() });
    }
    if (request.method === "PUT") {
      const parsed = validateRules(await request.json());
      if (!parsed.ok) {
        return json({ error: "invalid_payload", detail: parsed.error }, 400);
      }
      await this.state.storage.put(KEY_RULES, parsed.value);
      await this.broadcast("ruleChanged", { rules: parsed.value });
      return json({ ok: true, rules: parsed.value });
    }
    return json({ error: "method_not_allowed" }, 405);
  }

  /**
   * QR-less pairing step 1 (I-808): mint a one-time 6-char code (5 min
   * TTL). The redeeming client proves possession of the code, so the
   * Worker adds the pairing URL — the DO only sees `task-hub` URLs.
   */
  private async pair(request: Request): Promise<Response> {
    let body: unknown = {};
    try {
      body = await request.json();
    } catch {
      body = {};
    }
    const parsed = validatePairRequest(body);
    if (!parsed.ok) {
      return json({ error: "invalid_payload", detail: parsed.error }, 400);
    }
    const code = this.newPairCode();
    const record: PairCode = {
      user: parsed.value.user ?? "default",
      ...(parsed.value.device !== undefined
        ? { device: parsed.value.device }
        : {}),
      expiresAt: Date.now() + PAIR_TTL_MS,
    };
    await this.state.storage.put<PairCode>(PREFIX_PAIR + code, record);
    return json({
      code,
      expiresAt: new Date(record.expiresAt).toISOString(),
    });
  }

  /** One-time 6-char pairing code (no ambiguous glyphs). */
  private newPairCode(): string {
    const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    return [...crypto.getRandomValues(new Uint8Array(6))]
      .map((b) => alphabet[b % alphabet.length])
      .join("");
  }

  /**
   * Pairing step 2 (I-808): unauthenticated — possession of the code IS
   * the credential. Redeems once into a `dev_…` device token bound to
   * the code's user; the token is stored hashed.
   */
  private async redeem(request: Request): Promise<Response> {
    const parsed = validateRedeemRequest(await request.json());
    if (!parsed.ok) {
      return json({ error: "invalid_payload", detail: parsed.error }, 400);
    }
    const key = PREFIX_PAIR + parsed.value.code.toUpperCase();
    const record = await this.state.storage.get<PairCode>(key);
    if (!record || record.expiresAt <= Date.now()) {
      return json({ error: "invalid_code" }, 404);
    }
    await this.state.storage.delete(key);
    const token = `dev_${crypto.randomUUID()}`;
    const record2: DeviceRecord = {
      user: record.user,
      createdAt: new Date().toISOString(),
    };
    await this.state.storage.put<DeviceRecord>(
      PREFIX_DEVICE + (await sha256Hex(token)),
      record2,
    );
    return json({ token, user: record.user });
  }

  /** Device-token lookup for the router (I-808/I-809). */
  private async auth(request: Request): Promise<Response> {
    const body = (await request.json()) as { token?: unknown };
    const token = body.token;
    if (typeof token !== "string" || token.length === 0) {
      return json({ error: "invalid_token" }, 400);
    }
    const record = await this.state.storage.get<DeviceRecord>(
      PREFIX_DEVICE + (await sha256Hex(token)),
    );
    if (!record) return json({ error: "invalid_token" }, 404);
    return json({ user: record.user });
  }

  /** Register a browser push subscription (I-701). */
  private async pushSubscribe(request: Request): Promise<Response> {
    const body = (await request.json()) as Partial<PushSubscription>;
    if (
      typeof body?.endpoint !== "string" ||
      !/^https:\/\//.test(body.endpoint) ||
      typeof body.keys?.p256dh !== "string" ||
      typeof body.keys?.auth !== "string"
    ) {
      return json(
        {
          error: "invalid_payload",
          detail: "endpoint (https URL) and keys.p256dh / keys.auth are required",
        },
        400,
      );
    }
    await this.state.storage.put<PushSubscription>(
      PREFIX_PUSH + (await sha256Hex(body.endpoint)),
      {
        endpoint: body.endpoint,
        keys: { p256dh: body.keys.p256dh, auth: body.keys.auth },
      },
    );
    return json({ ok: true }, 201);
  }

  /** Remove a browser push subscription (I-701). */
  private async pushUnsubscribe(request: Request): Promise<Response> {
    const body = (await request.json()) as { endpoint?: unknown };
    if (typeof body?.endpoint !== "string") {
      return json(
        { error: "invalid_payload", detail: "endpoint is required" },
        400,
      );
    }
    await this.state.storage.delete(PREFIX_PUSH + (await sha256Hex(body.endpoint)));
    return new Response(null, { status: 204 });
  }

  /** POST the reply to `replyUrl` with an HMAC signature (I-604/I-801).
   *  Failures schedule the next backoff attempt; the fifth gives up and
   *  is surfaced via `deliveryFailed` + `/state`. */
  private async attemptDelivery(
    key: string,
    url: string,
    reply: ActionReply,
  ): Promise<void> {
    const stored = await this.state.storage.get<StoredTask>(key);
    if (!stored || stored.delivery?.failed) return;

    const attempts = (stored.delivery?.attempts ?? 0) + 1;
    const body = JSON.stringify(reply);
    let lastError: string | undefined;
    let ok = false;
    try {
      const secret = this.env.REPLY_SIGNING_SECRET ?? this.env.AGENT_TOKEN;
      const headers: Record<string, string> = {
        "content-type": "application/json",
      };
      if (secret) {
        const ts = Math.floor(Date.now() / 1000);
        headers["X-AgentDesk-Signature"] =
          `t=${ts},v1=${await hmacHex(secret, `${ts}.${body}`)}`;
        headers["X-AgentDesk-Event"] =
          reply.actionName === "expire" ? "expire" : "triage_reply";
      }
      const res = await fetch(url, {
        method: "POST",
        headers,
        body,
        signal: AbortSignal.timeout(10_000),
      });
      if (res.ok) ok = true;
      else lastError = `HTTP ${res.status}`;
    } catch (err) {
      lastError = err instanceof Error ? err.message : String(err);
    }

    const now = Date.now();
    if (ok) {
      const done: StoredTask = { ...stored };
      delete done.delivery;
      await this.state.storage.put(key, done);
    } else if (attempts >= MAX_DELIVERY_ATTEMPTS) {
      const failed: StoredTask = {
        ...stored,
        delivery: { attempts, url, reply, lastError, failed: true },
      };
      await this.state.storage.put(key, failed);
      await this.broadcast("deliveryFailed", {
        taskId: stored.task.taskId,
        lastError,
      });
    } else {
      const retry: StoredTask = {
        ...stored,
        delivery: {
          attempts,
          url,
          reply,
          lastError,
          // 1s → 2s → 4s → 8s, capped at 16s.
          nextRetryAt: now + Math.min(DELIVERY_BACKOFF_CAP_MS, 1000 * 2 ** (attempts - 1)),
        },
      };
      await this.state.storage.put(key, retry);
    }
    await this.rescheduleAlarm();
  }

  private get graceMs(): number {
    const parsed = Number.parseInt(this.env.UNDO_GRACE_MS ?? "", 10);
    return Number.isFinite(parsed) && parsed >= 0 ? parsed : UNDO_GRACE_MS;
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
   * One alarm serves four jobs (I-104, I-203, snooze, I-604): commit
   * deadlines for `committing` tasks, resize deadlines for snoozed cards,
   * expiry deadlines for pending cards with `expiresAt`, reply-retry
   * backoff, and TTL cleanup for `processed` ones. Call after every
   * status change; it recomputes the next deadline from scratch so
   * early-finishing work never strands a later alarm.
   */
  private async rescheduleAlarm(): Promise<void> {
    const now = Date.now();
    let next: number | null = null;
    const all = await this.state.storage.list<StoredTask>({ prefix: "task:" });
    const candidates: number[] = [];
    for (const stored of all.values()) {
      if (stored.status === "committing") {
        candidates.push(stored.commitAt ?? now);
      } else if (stored.status === "processed") {
        candidates.push((stored.processedAt ?? now) + PROCESSED_TTL_MS);
      } else if (stored.status === "pending") {
        const resumeAt =
          stored.snoozedUntil !== undefined
            ? stored.snoozedUntil
            : stored.task.expiresAt !== undefined && stored.escalatedAt === undefined
              ? Date.parse(stored.task.expiresAt)
              : NaN;
        if (Number.isFinite(resumeAt)) candidates.push(resumeAt);
      }
      const retryAt = stored.delivery?.nextRetryAt;
      if (!stored.delivery?.failed && retryAt !== undefined) {
        candidates.push(retryAt);
      }
    }
    for (const at of candidates) {
      if (Number.isFinite(at) && (next === null || at < next)) next = at;
    }
    const current = await this.state.storage.getAlarm();

    if (next === null) {
      if (current !== null) await this.state.storage.deleteAlarm();
      return;
    }
    // Self-heal a stale alarm: after a runtime restart the stored alarm
    // can sit in the past while its timer is gone — a future `next`
    // would otherwise never schedule (next < current is false forever).
    if (current === null || next < current || current <= now) {
      await this.state.storage.setAlarm(next);
    }
  }

  async alarm(): Promise<void> {
    const now = Date.now();
    const ttlCutoff = now - PROCESSED_TTL_MS;
    const all = await this.state.storage.list<StoredTask>({ prefix: "task:" });
    const doomed: string[] = [];
    const deliveries: Array<{ key: string; reply: ActionReply; url: string }> = [];
    for (const [key, stored] of all) {
      if (stored.status === "committing" && (stored.commitAt ?? 0) <= now) {
        const reply = stored.pendingReply;
        const updated: StoredTask = {
          ...stored,
          status: "processed",
          processedAt: stored.commitAt ?? now,
          processedBy: reply?.source,
          commitAt: undefined,
          pendingReply: undefined,
          ...(reply
            ? {
                outcome: {
                  name: reply.actionName,
                  ...(reply.data ? { data: reply.data } : {}),
                  source: reply.source,
                  at: reply.timestamp,
                },
              }
            : {}),
        };
        await this.state.storage.put(key, updated);
        if (reply && stored.task.replyUrl) {
          deliveries.push({ key, reply, url: stored.task.replyUrl });
        }
      } else if (stored.status === "pending") {
        if (stored.snoozedUntil !== undefined) {
          // Snoozed cards are exempt from expiry until they resurface.
          if (stored.snoozedUntil <= now) {
            const task: TaskCardPayload = {
              ...stored.task,
              nonce: `tok_${crypto.randomUUID()}`,
            };
            const updated: StoredTask = {
              ...stored,
              task,
              nonce: task.nonce,
              snoozedUntil: undefined,
            };
            await this.state.storage.put(key, updated);
            await this.broadcast("createTaskCard", this.present(updated, now));
          }
        } else {
          const decision = expiryDue(stored, now);
          if (decision) await this.runExpiry(key, stored, decision, now);
        }
      } else if (stored.status === "processed") {
        const delivery = stored.delivery;
        if (
          delivery &&
          !delivery.failed &&
          delivery.nextRetryAt !== undefined &&
          delivery.nextRetryAt <= now &&
          delivery.url &&
          delivery.reply
        ) {
          deliveries.push({ key, reply: delivery.reply, url: delivery.url });
        } else if (
          (stored.processedAt ?? 0) < ttlCutoff &&
          !(delivery && !delivery.failed)
        ) {
          doomed.push(key);
        }
      }
    }
    if (doomed.length > 0) await this.state.storage.delete(doomed);
    for (const { key, reply, url } of deliveries) {
      this.state.waitUntil(this.attemptDelivery(key, url, reply));
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
      await this.broadcast("createTaskCard", this.present(updated, now));
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
      outcome: {
        name: reply.actionName,
        ...(reply.data ? { data: reply.data } : {}),
        source: reply.source,
        at: reply.timestamp,
      },
    };
    await this.state.storage.put(key, updated);
    await this.broadcast("dismissTask", {
      taskId: stored.task.taskId,
      by: "on_expire",
    });
    if (stored.task.replyUrl) {
      this.state.waitUntil(
        this.attemptDelivery(key, stored.task.replyUrl, reply),
      );
    }
  }
}
