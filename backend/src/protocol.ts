// Wire protocol shared by the hub and all clients. Spec: docs/protocol.md.
// Keep this file pure (no Workers/DOM globals beyond crypto.randomUUID)
// so it stays unit-testable with plain vitest.

/**
 * Current wire version (I-606). Cards that carry no `protocolVersion`
 * are v0 and treated as `1` — the field is additive, so v0 producers
 * keep working unchanged.
 */
export const PROTOCOL_VERSION = 1;

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

/** Structured "back of the card" context (P1/P3): who asked, who is
 *  affected, why, and where it came from. Rendered in the expandable
 *  details panel — never required for a valid card. */
export interface TaskContext {
  requester?: { name: string; onBehalfOf?: string; avatarUrl?: string };
  participants?: { name: string; status?: string }[];
  reasoning?: string;
  source?: { label: string; url?: string };
}

/// Agent-supplied candidate for "why was this rejected" (I-118).
export interface RejectReason {
  id: string;
  label: string;
}

/** What the hub does when a card's deadline passes (I-203). */
export type OnExpireAction = "approve" | "reject" | "escalate" | "drop";

export const ON_EXPIRE_ACTIONS: readonly OnExpireAction[] = [
  "approve",
  "reject",
  "escalate",
  "drop",
];

export interface TaskCardActions {
  onSwipeRight?: ActionBinding;
  onSwipeLeft?: ActionBinding;
  onSwipeUp?: ActionBinding;
  inspectForm?: CardComponent[];
  rejectReasons?: RejectReason[];
}

/** What kind of decision the card asks for; `approve` when absent. */
export type DecisionKind = "approve" | "choose" | "fill";

export const DECISION_KINDS: readonly DecisionKind[] = [
  "approve",
  "choose",
  "fill",
];

/** Inline value editing hint: the named component may be adjusted in
 *  place (number stepper / datetime picker) before approving. */
export interface EditableHint {
  componentId: string;
  kind: "number" | "datetime";
  min?: number;
  max?: number;
  step?: number;
}


export interface TaskCardPayload {
  type: "createTaskCard";
  taskId: string;
  nonce: string;
  /** Wire version of this card (I-606); absent = v0, treated as 1. */
  protocolVersion?: number;
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
  /** Advisory display context for the details panel (裏面). Malformed
   *  pieces are dropped by validation, never rejected. */
  context?: TaskContext;
  /** ISO 8601 instant after which the hub executes the default
   *  behavior (I-203). Required for `onExpire`. */
  expiresAt?: string;
  /** Default behavior at expiry; defaults to the safe "drop". */
  onExpire?: OnExpireAction;
  /** Cards sharing a key are a bundle (I-201); the client may render
   *  them as one summary card and triage them together. */
  groupKey?: string;
  /** approve | choose | fill (default approve). */
  decisionKind?: DecisionKind;
  /** Inline value editing hint (I-114). */
  editable?: EditableHint;
  /** Hub-computed urgency score (I-206); higher = more urgent. Never
   *  sent by agents — attached by the hub on broadcast/snapshot. */
  priority?: number;
  /** Hub marker on `createTaskCard` re-broadcasts after an agent update
   *  (I-204): clients may show a 「更新されました」 hint. */
  revised?: boolean;
}

export interface ActionReply {
  taskId: string;
  nonce: string;
  actionName: string;
  timestamp: string;
  source: string;
  data?: Record<string, unknown>;
  /** `"snooze"` asks the hub to hide the card until `until` instead of
   *  processing it (server-side snooze). */
  action?: "snooze";
  /** ISO 8601 instant the snoozed card resurfaces; required with
   *  `action: "snooze"`, at most 7 days out. */
  until?: string;
}

/** Longest accepted snooze duration. */
export const MAX_SNOOZE_MS = 7 * 24 * 60 * 60 * 1000;

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
  /** Set once `onExpire: "escalate"` has fired so the deadline is not
   *  evaluated twice; the card keeps waiting (severity already bumped). */
  escalatedAt?: number;
  /** Server-side snooze: wall time the hidden card resurfaces. While set
   *  and in the future the task stays `pending` but is absent from the
   *  stack / snapshot `tasks` (it appears under `snoozed` instead). */
  snoozedUntil?: number;
  /** replyUrl delivery bookkeeping (I-604): retries + terminal failure. */
  delivery?: DeliveryState;
  /** Terminal decision recorded for `GET /result` (I-901): what was
   *  decided, by which source, and when. */
  outcome?: Outcome;
}

/** replyUrl delivery state (I-604/I-801). `url`/`reply` are retained so
 *  retries after the task reaches `processed` can re-send the exact body. */
export interface DeliveryState {
  attempts: number;
  url?: string;
  reply?: ActionReply;
  lastError?: string;
  /** Wall time of the next retry attempt (absent once delivered/given up). */
  nextRetryAt?: number;
  /** true = the retry budget is spent; surfaced via `deliveryFailed`. */
  failed?: boolean;
}

/** The decision a task finished with, exposed to the agent SDK (I-901). */
export interface Outcome {
  name: string;
  data?: Record<string, unknown>;
  source: string;
  at: string;
}

/** Snapshot envelope (`snapshot` SSE + `GET /api/v1/state`). */
export interface SnapshotPayload {
  protocolVersion: number;
  /** Pending, non-snoozed tasks — priority desc, createdAt asc. */
  tasks: TaskCardPayload[];
  snoozed: { taskId: string; until: string }[];
  /** Terminal replyUrl failures (I-604) awaiting operator attention. */
  delivery: { taskId: string; lastError?: string; attempts: number }[];
}

export type ActionDecision =
  | { kind: "apply" }
  | { kind: "snooze" }
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
  // Snooze (server-side snooze, known deviation): only ever applies to a
  // still-pending card; it keeps the nonce (rotation happens when the
  // alarm resurfaces the card).
  if (reply.action === "snooze") return { kind: "snooze" };
  return { kind: "apply" };
}

/** Severity base scores used by {@link computePriority} (I-206). */
const SEVERITY_BASE: Record<string, number> = {
  info: 10,
  notice: 20,
  warning: 40,
  critical: 80,
};

/**
 * Hub-side urgency score (I-123/I-206), higher = more urgent:
 *
 *   severity base (info 10 / notice 20 / warning 40 / critical 80)
 *   + deadline proximity (≤1h +50, ≤6h +30, ≤24h +10)
 *   + (1 − confidence) × 10
 *   + waiting time (+1 per 10 min, capped at +20)
 *
 * Pure so the hub can reuse it for ordering and for the `priority`
 * field it attaches to broadcasts/snapshots.
 */
export function computePriority(
  task: TaskCardPayload,
  enqueuedAt: number,
  now: number,
): number {
  let score = SEVERITY_BASE[task.severity ?? "info"] ?? 10;

  if (task.expiresAt) {
    const at = Date.parse(task.expiresAt);
    if (Number.isFinite(at)) {
      const remaining = at - now;
      if (remaining <= 60 * 60 * 1000) score += 50;
      else if (remaining <= 6 * 60 * 60 * 1000) score += 30;
      else if (remaining <= 24 * 60 * 60 * 1000) score += 10;
    }
  }

  const confidence = Math.min(1, Math.max(0, task.confidence ?? 0.5));
  score += (1 - confidence) * 10;

  const ageMs = Math.max(0, now - enqueuedAt);
  score += Math.min(20, Math.floor(ageMs / (10 * 60 * 1000)));

  return Math.round(score * 100) / 100;
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

export interface ExpiryDecision {
  action: OnExpireAction;
  /** The swipe binding to auto-execute for approve/reject. */
  binding?: ActionBinding;
}

/**
 * Pure expiry evaluation (I-203). Returns the default behavior to run
 * when a *pending* card's `expiresAt` has passed, or null while it is
 * still waiting (or the deadline was already consumed — escalated tasks
 * keep waiting, everything else is no longer pending). approve/reject
 * without the matching swipe binding degrade to the safe "drop".
 */
export function expiryDue(
  stored: StoredTask,
  now: number,
): ExpiryDecision | null {
  if (stored.status !== "pending" || stored.escalatedAt !== undefined) {
    return null;
  }
  const raw = stored.task.expiresAt;
  if (!raw) return null;
  const at = Date.parse(raw);
  if (!Number.isFinite(at) || at > now) return null;
  const action = stored.task.onExpire ?? "drop";
  if (action === "approve" || action === "reject") {
    const binding =
      action === "approve"
        ? stored.task.actions.onSwipeRight
        : stored.task.actions.onSwipeLeft;
    if (!binding) return { action: "drop" };
    return { action, binding };
  }
  return { action };
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

  // Advisory display context (裏面, P1/P3): who / why / who's affected /
  // where from. Malformed pieces are dropped rather than rejected.
  let context: TaskContext | undefined;
  if (isRecord(body.context)) {
    const raw = body.context;
    const requester = isRecord(raw.requester) &&
      typeof raw.requester.name === "string" && raw.requester.name.length > 0
      ? {
          name: raw.requester.name,
          ...(typeof raw.requester.onBehalfOf === "string" && raw.requester.onBehalfOf.length > 0
            ? { onBehalfOf: raw.requester.onBehalfOf }
            : {}),
          ...(typeof raw.requester.avatarUrl === "string" &&
          /^https?:\/\//.test(raw.requester.avatarUrl)
            ? { avatarUrl: raw.requester.avatarUrl }
            : {}),
        }
      : undefined;
    const participants = Array.isArray(raw.participants)
      ? raw.participants.filter(
          (p): p is { name: string; status?: string } =>
            isRecord(p) &&
            typeof p.name === "string" && p.name.length > 0 &&
            (p.status === undefined || typeof p.status === "string"),
        )
      : [];
    const reasoning =
      typeof raw.reasoning === "string" && raw.reasoning.length > 0
        ? raw.reasoning
        : undefined;
    const source =
      isRecord(raw.source) &&
      typeof raw.source.label === "string" && raw.source.label.length > 0
        ? {
            label: raw.source.label,
            ...(typeof raw.source.url === "string" &&
            /^https?:\/\//.test(raw.source.url)
              ? { url: raw.source.url }
              : {}),
          }
        : undefined;
    if (requester || participants.length > 0 || reasoning || source) {
      context = {
        ...(requester ? { requester } : {}),
        ...(participants.length > 0 ? { participants } : {}),
        ...(reasoning !== undefined ? { reasoning } : {}),
        ...(source ? { source } : {}),
      };
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

  // I-606: wire version. Absent = v0 producer, treated as 1; anything
  // else must be a positive integer.
  let protocolVersion = PROTOCOL_VERSION;
  if (body.protocolVersion !== undefined) {
    if (
      typeof body.protocolVersion !== "number" ||
      !Number.isInteger(body.protocolVersion) ||
      body.protocolVersion < 1
    ) {
      return fail("protocolVersion must be a positive integer");
    }
    protocolVersion = body.protocolVersion;
  }

  // I-201: grouping key. Behavior-bearing (bulk triage), so malformed
  // values are rejected rather than silently dropped.
  let groupKey: string | undefined;
  if (body.groupKey !== undefined) {
    if (typeof body.groupKey !== "string" || body.groupKey.length === 0) {
      return fail("groupKey must be a non-empty string");
    }
    groupKey = body.groupKey;
  }

  // Decision shape (default approve) and the inline-editing hint.
  let decisionKind: DecisionKind | undefined;
  if (body.decisionKind !== undefined) {
    if (
      typeof body.decisionKind !== "string" ||
      !DECISION_KINDS.includes(body.decisionKind as DecisionKind)
    ) {
      return fail("decisionKind must be approve | choose | fill");
    }
    decisionKind = body.decisionKind as DecisionKind;
  }
  let editable: EditableHint | undefined;
  if (body.editable !== undefined) {
    const raw = body.editable;
    if (!isRecord(raw)) return fail("editable must be an object");
    const componentId = raw.componentId;
    const kind = raw.kind;
    if (typeof componentId !== "string" || componentId.length === 0) {
      return fail("editable.componentId (non-empty string) is required");
    }
    if (kind !== "number" && kind !== "datetime") {
      return fail("editable.kind must be number | datetime");
    }
    const min = raw.min;
    const max = raw.max;
    const step = raw.step;
    for (const [field, value] of [["min", min], ["max", max], ["step", step]] as const) {
      if (value !== undefined && typeof value !== "number") {
        return fail(`editable.${field} must be a number`);
      }
    }
    editable = {
      componentId,
      kind,
      ...(typeof min === "number" ? { min } : {}),
      ...(typeof max === "number" ? { max } : {}),
      ...(typeof step === "number" ? { step } : {}),
    };
  }

  const replyUrl = body.replyUrl;
  if (replyUrl !== undefined) {
    if (typeof replyUrl !== "string" || !/^https?:\/\//.test(replyUrl)) {
      return fail("replyUrl must be an http(s) URL");
    }
  }

  // I-203: expiry policy. Behavior-bearing fields validate strictly
  // (a malformed deadline must not silently become "never expires").
  const expiresAt = body.expiresAt;
  if (expiresAt !== undefined) {
    if (typeof expiresAt !== "string" || !Number.isFinite(Date.parse(expiresAt))) {
      return fail("expiresAt must be an ISO 8601 date string");
    }
  }
  const onExpire = body.onExpire;
  if (onExpire !== undefined) {
    if (
      typeof onExpire !== "string" ||
      !ON_EXPIRE_ACTIONS.includes(onExpire as OnExpireAction)
    ) {
      return fail(
        "onExpire must be one of approve | reject | escalate | drop",
      );
    }
    if (expiresAt === undefined) {
      return fail("onExpire requires expiresAt");
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
    protocolVersion,
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
    ...(context !== undefined ? { context } : {}),
    ...(expiresAt !== undefined ? { expiresAt: expiresAt as string } : {}),
    ...(onExpire !== undefined ? { onExpire: onExpire as OnExpireAction } : {}),
    ...(groupKey !== undefined ? { groupKey } : {}),
    ...(decisionKind !== undefined ? { decisionKind } : {}),
    ...(editable !== undefined ? { editable } : {}),
  };
  return { ok: true, value };
}

/**
 * Validates a client triage reply (7.2 payload). Timestamp is filled by
 * the hub. Two shapes share this endpoint:
 *
 * - a normal action: `{taskId, nonce, actionName, source?, data?}`
 * - a server-side snooze: `{taskId, nonce, action: "snooze", until}` —
 *   `until` must be an ISO 8601 instant at most {@link MAX_SNOOZE_MS}
 *   (7 days) in the future.
 */
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

  if (body.action !== undefined && body.action !== "snooze") {
    return fail('action must be "snooze" when present');
  }
  if (body.action === "snooze") {
    const until = body.until;
    if (typeof until !== "string" || !Number.isFinite(Date.parse(until))) {
      return fail("snooze requires an ISO 8601 until");
    }
    if (Date.parse(until) > Date.now() + MAX_SNOOZE_MS) {
      return fail("snooze until must be at most 7 days out");
    }
    return {
      ok: true,
      value: {
        taskId,
        nonce,
        actionName: typeof actionName === "string" && actionName.length > 0
          ? actionName
          : "snooze",
        timestamp:
          typeof body.timestamp === "string"
            ? body.timestamp
            : new Date().toISOString(),
        source: typeof body.source === "string" ? body.source : "snooze",
        action: "snooze",
        until,
        ...(isRecord(body.data) ? { data: body.data } : {}),
      },
    };
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

/** One item of a bulk triage request (I-201 `POST /api/v1/actions/bulk`). */
export interface BulkActionItem {
  taskId: string;
  nonce: string;
  actionName: string;
  source: string;
  data?: Record<string, unknown>;
}

/**
 * Validates a bulk triage envelope `{actions:[…]}`. Each item is
 * normalized like a single action; the hub then CASes them
 * independently — one failure never rolls back the others.
 */
export function validateBulkRequest(
  body: unknown,
): ValidationResult<{ actions: BulkActionItem[] }> {
  if (!isRecord(body)) return fail("payload must be a JSON object");
  const raw = body.actions;
  if (!Array.isArray(raw)) return fail("actions must be an array");
  if (raw.length === 0) return fail("actions must not be empty");
  const actions: BulkActionItem[] = [];
  for (const item of raw) {
    if (!isRecord(item)) return fail("every action must be an object");
    const taskId = item.taskId;
    const nonce = item.nonce;
    const action = item.action;
    const source = item.source;
    if (typeof taskId !== "string" || taskId.length === 0) {
      return fail("every action needs a string taskId");
    }
    if (typeof nonce !== "string" || nonce.length === 0) {
      return fail("every action needs a string nonce");
    }
    if (typeof action !== "string" || action.length === 0) {
      return fail("every action needs a string action");
    }
    actions.push({
      taskId,
      nonce,
      actionName: action,
      source: typeof source === "string" ? source : "bulk",
      ...(isRecord(item.data) ? { data: item.data } : {}),
    });
  }
  return { ok: true, value: { actions } };
}
