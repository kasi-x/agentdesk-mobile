// Wire protocol shared by the hub and all clients. Spec: docs/protocol.md.
// Keep this file pure (no Workers/DOM globals beyond crypto.randomUUID)
// so it stays unit-testable with plain vitest.

export interface AgentInfo {
  name: string;
  avatarUrl?: string;
}

export interface CardComponent {
  id: string;
  component: string;
  properties?: Record<string, unknown>;
  children?: string[];
}

export interface ActionBinding {
  actionName: string;
  /** Action-specific verb shown while swiping (I-130); clients fall
   *  back to APPROVE / REJECT when absent. */
  label?: string;
  payload?: Record<string, unknown>;
}

/** What accepting this card does (I-202). All fields optional so agents
 *  can declare as much as they know. */
export interface CardImpact {
  /** One line shown as 「承認すると {summary}」 near the card top. */
  summary?: string;
  /** false renders a 「取り消し不可」 badge; absent = unknown. */
  reversible?: boolean;
  cost?: { amount: number; currency: string };
  scope?: string;
}

/// Agent-supplied candidate for "why was this rejected" (I-118).
export interface RejectReason {
  id: string;
  label: string;
}

export interface TaskCardActions {
  onSwipeRight?: ActionBinding;
  onSwipeLeft?: ActionBinding;
  onSwipeUp?: ActionBinding;
  inspectForm?: CardComponent[];
  rejectReasons?: RejectReason[];
}


export interface TaskCardPayload {
  type: "createTaskCard";
  taskId: string;
  nonce: string;
  agent: AgentInfo;
  confidence?: number;
  confidenceReasons?: string[];
  severity?: "info" | "warning" | "critical";
  summary: string;
  surfaceId?: string;
  createdAt: string;
  replyUrl?: string;
  components: CardComponent[];
  actions: TaskCardActions;
  impact?: CardImpact;
}

export interface ActionReply {
  taskId: string;
  nonce: string;
  actionName: string;
  timestamp: string;
  source: string;
  data?: Record<string, unknown>;
}

/** `committing` = decision accepted but still inside the undo grace window
 *  (I-104): not delivered to the agent yet, revertible to `pending`. */
export type TaskStatus = "pending" | "committing" | "processed";

/** Default undo grace window; the hub may override via `UNDO_GRACE_MS`. */
export const UNDO_GRACE_MS = 5_000;

export interface UndoRequest {
  taskId: string;
  nonce: string;
}

export interface StoredTask {
  task: TaskCardPayload;
  status: TaskStatus;
  nonce: string;
  createdAt: number;
  /** `committing` only: wall time the grace window closes and the
   *  pending reply is committed. */
  commitAt?: number;
  /** `committing` only: the reply to forward to `replyUrl` on commit. */
  pendingReply?: ActionReply;
  processedAt?: number;
  processedBy?: string;
}

export type ActionDecision =
  | { kind: "apply" }
  | { kind: "conflict"; reason: "already_processed" }
  | { kind: "not_found" }
  | { kind: "bad_nonce" };

export type UndoDecision =
  | { kind: "undo" }
  | { kind: "conflict"; reason: "too_late" }
  | { kind: "not_found" }
  | { kind: "bad_nonce" };

/**
 * Pure compare-and-swap decision for a triage reply (FR-3.1/FR-3.3).
 * The TaskHub applies this under DO input gates: read → decide → write
 * with nothing else awaited in between. A `committing` task still
 * answers `already_processed` — its decision is taken, only the
 * agent delivery is deferred.
 */
export function decideAction(
  stored: StoredTask | undefined,
  reply: ActionReply,
): ActionDecision {
  if (!stored) return { kind: "not_found" };
  if (stored.nonce !== reply.nonce) return { kind: "bad_nonce" };
  if (stored.status !== "pending") {
    return { kind: "conflict", reason: "already_processed" };
  }
  return { kind: "apply" };
}

/**
 * Revert a `committing` decision back to `pending` (I-104). The same
 * one-shot nonce that authorized the action authorizes its undo; the
 * hub then rotates the nonce before re-broadcasting the card. Past the
 * grace window (or already processed) undo answers `too_late` — callers
 * cannot distinguish "expired" from "never committing", which is fine:
 * both mean the reply may already be at the agent.
 */
export function decideUndo(
  stored: StoredTask | undefined,
  request: UndoRequest,
): UndoDecision {
  if (!stored) return { kind: "not_found" };
  if (stored.nonce !== request.nonce) return { kind: "bad_nonce" };
  if (stored.status !== "committing") {
    return { kind: "conflict", reason: "too_late" };
  }
  return { kind: "undo" };
}

/** Validates an undo request (same shape the client used for its action). */
export function validateUndoRequest(
  body: unknown,
): ValidationResult<UndoRequest> {
  if (!isRecord(body)) return fail("payload must be a JSON object");
  const { taskId, nonce } = body;
  if (typeof taskId !== "string" || taskId.length === 0) {
    return fail("taskId (string) is required");
  }
  if (typeof nonce !== "string" || nonce.length === 0) {
    return fail("nonce (string) is required");
  }
  return { ok: true, value: { taskId, nonce } };
}

export type ValidationResult<T> =
  | { ok: true; value: T }
  | { ok: false; error: string };

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function fail<T>(error: string): ValidationResult<T> {
  return { ok: false, error };
}

/**
 * Validates + normalizes an agent-enqueued task card. Unknown component
 * types pass through untouched — clients render them as fallback cards
 * (FR-1.3). Missing taskId/nonce/createdAt are filled in by the hub.
 */
export function validateTaskCard(
  body: unknown,
): ValidationResult<TaskCardPayload> {
  if (!isRecord(body)) return fail("payload must be a JSON object");

  const agent = body.agent;
  if (
    !isRecord(agent) ||
    typeof agent.name !== "string" ||
    agent.name.length === 0
  ) {
    return fail("agent.name (non-empty string) is required");
  }

  const summary = body.summary;
  if (typeof summary !== "string" || summary.length === 0) {
    return fail("summary (non-empty string) is required");
  }

  const components = body.components ?? [];
  if (!Array.isArray(components)) return fail("components must be an array");
  for (const c of components) {
    if (
      !isRecord(c) ||
      typeof c.id !== "string" ||
      typeof c.component !== "string"
    ) {
      return fail("every component needs string `id` and `component` fields");
    }
  }

  if (
    body.confidence !== undefined &&
    (typeof body.confidence !== "number" ||
      body.confidence < 0 ||
      body.confidence > 1)
  ) {
    return fail("confidence must be a number between 0 and 1");
  }

  const actions: TaskCardActions = {};
  const rawActions = body.actions;
  if (rawActions !== undefined) {
    if (!isRecord(rawActions)) return fail("actions must be an object");
    for (const key of ["onSwipeRight", "onSwipeLeft", "onSwipeUp"] as const) {
      const binding = rawActions[key];
      if (binding === undefined) continue;
      if (!isRecord(binding) || typeof binding.actionName !== "string") {
        return fail(`actions.${key}.actionName (string) is required when present`);
      }
      actions[key] = {
        actionName: binding.actionName,
        ...(typeof binding.label === "string" && binding.label.length > 0
          ? { label: binding.label }
          : {}),
        ...(isRecord(binding.payload) ? { payload: binding.payload } : {}),
      };
    }
    const inspectForm = rawActions.inspectForm;
    if (inspectForm !== undefined) {
      if (!Array.isArray(inspectForm)) {
        return fail("actions.inspectForm must be an array");
      }
      for (const c of inspectForm) {
        if (
          !isRecord(c) ||
          typeof c.id !== "string" ||
          typeof c.component !== "string"
        ) {
          return fail(
            "every inspectForm component needs string `id` and `component` fields",
          );
        }
      }
      actions.inspectForm = inspectForm as CardComponent[];
    }
    // I-118: optional reject reason chips. Entries must carry string
    // `id` and `label`; malformed entries are dropped, never rejected.
    const rejectReasons = rawActions.rejectReasons;
    if (rejectReasons !== undefined) {
      if (!Array.isArray(rejectReasons)) {
        return fail("actions.rejectReasons must be an array");
      }
      const kept = rejectReasons.filter(
        (r): r is RejectReason =>
          isRecord(r) && typeof r.id === "string" && typeof r.label === "string",
      );
      if (kept.length > 0) {
        actions.rejectReasons = kept.map((r) => ({
          id: r.id,
          label: r.label,
        }));
      }
    }
  }

  // I-202: optional structured impact block. Unknown/mistyped fields are
  // dropped rather than rejected — impact is advisory display data.
  let impact: CardImpact | undefined;
  if (isRecord(body.impact)) {
    const raw = body.impact;
    impact = {
      ...(typeof raw.summary === "string" && raw.summary.length > 0
        ? { summary: raw.summary }
        : {}),
      ...(typeof raw.reversible === "boolean"
        ? { reversible: raw.reversible }
        : {}),
      ...(isRecord(raw.cost) &&
      typeof raw.cost.amount === "number" &&
      typeof raw.cost.currency === "string"
        ? { cost: { amount: raw.cost.amount, currency: raw.cost.currency } }
        : {}),
      ...(typeof raw.scope === "string" && raw.scope.length > 0
        ? { scope: raw.scope }
        : {}),
    };
  }

  const replyUrl = body.replyUrl;
  if (replyUrl !== undefined) {
    if (typeof replyUrl !== "string" || !/^https?:\/\//.test(replyUrl)) {
      return fail("replyUrl must be an http(s) URL");
    }
  }

  const value: TaskCardPayload = {
    type: "createTaskCard",
    taskId:
      typeof body.taskId === "string" && body.taskId.length > 0
        ? body.taskId
        : `task_${crypto.randomUUID()}`,
    nonce:
      typeof body.nonce === "string" && body.nonce.length > 0
        ? body.nonce
        : `tok_${crypto.randomUUID()}`,
    agent: {
      name: agent.name,
      ...(typeof agent.avatarUrl === "string"
        ? { avatarUrl: agent.avatarUrl }
        : {}),
    },
    ...(typeof body.confidence === "number" ? { confidence: body.confidence } : {}),
    ...(Array.isArray(body.confidenceReasons)
      ? {
          confidenceReasons: body.confidenceReasons.filter(
            (r): r is string => typeof r === "string",
          ),
        }
      : {}),
    ...(body.severity === "warning" ||
    body.severity === "critical" ||
    body.severity === "info"
      ? { severity: body.severity }
      : {}),
    summary,
    ...(typeof body.surfaceId === "string" ? { surfaceId: body.surfaceId } : {}),
    createdAt:
      typeof body.createdAt === "string"
        ? body.createdAt
        : new Date().toISOString(),
    ...(replyUrl !== undefined ? { replyUrl: replyUrl as string } : {}),
    components: components as CardComponent[],
    actions,
    ...(impact !== undefined ? { impact } : {}),
  };
  return { ok: true, value };
}

/** Validates a client triage reply (7.2 payload). Timestamp is filled by the hub. */
export function validateActionReply(
  body: unknown,
): ValidationResult<ActionReply> {
  if (!isRecord(body)) return fail("payload must be a JSON object");
  const { taskId, nonce, actionName } = body;
  if (typeof taskId !== "string" || taskId.length === 0) {
    return fail("taskId (string) is required");
  }
  if (typeof nonce !== "string" || nonce.length === 0) {
    return fail("nonce (string) is required");
  }
  if (typeof actionName !== "string" || actionName.length === 0) {
    return fail("actionName (string) is required");
  }
  return {
    ok: true,
    value: {
      taskId,
      nonce,
      actionName,
      timestamp:
        typeof body.timestamp === "string"
          ? body.timestamp
          : new Date().toISOString(),
      source: typeof body.source === "string" ? body.source : "unknown",
      ...(isRecord(body.data) ? { data: body.data } : {}),
    },
  };
}
