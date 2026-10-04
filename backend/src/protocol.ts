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
  /** Swipe-overlay verb shown while dragging (I-130), e.g. "返金する $120". */
  label?: string;
  payload?: Record<string, unknown>;
}

export interface ImpactCost {
  amount: number;
  currency: string;
}

/** What approving does + whether it can be taken back (I-202, P3/P5). */
export interface TaskImpact {
  summary?: string;
  reversible?: boolean;
  cost?: ImpactCost;
  scope?: string;
}

export interface TaskCardActions {
  onSwipeRight?: ActionBinding;
  onSwipeLeft?: ActionBinding;
  onSwipeUp?: ActionBinding;
  inspectForm?: CardComponent[];
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
  /** "承認すると…" + reversible badge (I-202). Optional, old cards omit it. */
  impact?: TaskImpact;
  surfaceId?: string;
  createdAt: string;
  replyUrl?: string;
  components: CardComponent[];
  actions: TaskCardActions;
}

export interface ActionReply {
  taskId: string;
  nonce: string;
  actionName: string;
  timestamp: string;
  source: string;
  data?: Record<string, unknown>;
}

export type TaskStatus = "pending" | "committing" | "processed";

export interface StoredTask {
  task: TaskCardPayload;
  status: TaskStatus;
  nonce: string;
  createdAt: number;
  /** Set when status flips to committing (I-104): agent reply + sweep wait. */
  commitAt?: number;
  processedAt?: number;
  processedBy?: string;
}

export type ActionDecision =
  | { kind: "apply" }
  | { kind: "conflict"; reason: "already_processed" }
  | { kind: "not_found" }
  | { kind: "bad_nonce" };

export type UndoDecision =
  | { kind: "undone" }
  | { kind: "not_found" }
  | { kind: "too_late" };

/**
 * Pure compare-and-swap decision for a triage reply (FR-3.1/FR-3.3).
 * The TaskHub applies this under DO input gates: read → decide → write
 * with nothing else awaited in between.
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
 * Pure decision for `POST /api/v1/actions/undo` (I-104). Only a task
 * still inside its Undo grace window (`committing`) can return to
 * `pending`; anything else is `too_late` (processed) or `not_found`.
 * Nonce is intentionally NOT checked: the client holds the consuming
 * nonce and the undo must work even if the card was re-issued.
 */
export function decideUndo(
  stored: StoredTask | undefined,
): UndoDecision {
  if (!stored) return { kind: "not_found" };
  if (stored.status !== "committing") return { kind: "too_late" };
  return { kind: "undone" };
}

export interface UndoRequest {
  taskId: string;
}

/** Validates `POST /api/v1/actions/undo` (I-104): only taskId is required. */
export function validateUndoRequest(
  body: unknown,
): ValidationResult<UndoRequest> {
  if (!isRecord(body)) return fail("payload must be a JSON object");
  if (typeof body.taskId !== "string" || body.taskId.length === 0) {
    return fail("taskId (string) is required");
  }
  return { ok: true, value: { taskId: body.taskId } };
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
    ...(isRecord(body.impact) ? { impact: body.impact as TaskImpact } : {}),
    components: components as CardComponent[],
    actions,
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
