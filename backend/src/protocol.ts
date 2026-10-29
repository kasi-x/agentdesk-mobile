// Wire protocol shared by the hub and all clients. Spec: docs/protocol.md.
// Keep this file pure (no Workers/DOM globals beyond crypto.randomUUID)
// so it stays unit-testable with plain vitest.

/**
 * Current wire version (I-606). Cards that carry no `protocolVersion`
 * are v0 and treated as `1` — the field is additive, so v0 producers
 * keep working unchanged.
 */
export const PROTOCOL_VERSION = 1;

export interface RegisteredAgent {
  id: string;
  name: string;
  avatarUrl?: string;
  scopes?: string[];
  createdAt: string;
}

export interface AgentInfo {
  name: string;
  avatarUrl?: string;
  /** Hub-set when the enqueuing agent authenticated via a registered agent
   *  token (I-804). Dropped if sent by agents. */
  verified?: boolean;
  /** Hub-set scopes attached to the registered agent (I-804). */
  scopes?: string[];
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
  /** Fourth swipe direction, used by `decisionKind: "choose"` cards
   *  (I-111): up/down pick between `choices`. Approve cards keep
   *  down = snooze client-side. */
  onSwipeDown?: ActionBinding;
  inspectForm?: CardComponent[];
  rejectReasons?: RejectReason[];
}

/** One option of a `decisionKind: "choose"` card (I-111). */
export interface Choice {
  id: string;
  label: string;
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

/** What a rule matches against a NEW pending card (I-304/I-807). All
 *  constraints are ANDed; an omitted constraint matches anything. */
export interface RuleMatch {
  /** Substring of `agent.name`. */
  agent?: string;
  /** Allowed `severity` values (empty/absent = any). */
  severity?: string[];
  /** Maximum `impact.cost.amount`; a card without a cost counts as 0. */
  maxCost?: number;
  /** Substring of `groupKey`. */
  groupKey?: string;
  /** Minimum `confidence` (0–1, inclusive): `card.confidence >= value`.
   *  A card without a `confidence` never satisfies this constraint. */
  minConfidence?: number;
}

/** A rule's self-limiting budget (I-602). The rule stops auto-approving
 *  once `until` passes or `maxCount` approvals have been spent. */
export interface RuleLease {
  /** ISO 8601 instant after which the rule is disabled. */
  until?: string;
  /** Maximum number of auto-approvals while `until` has not passed. */
  maxCount?: number;
}

/** An auto-approval/-rejection rule (I-304/I-807/I-1002): matching NEW
 *  pending cards are decided by the hub with `source: "auto_rule"`,
 *  counting against the lease. Stored in the hub and managed via
 *  `GET/PUT /api/v1/rules`. `action` defaults to `"approve"` for
 *  rules written before the guardrail extension. */
export interface Rule {
  id: string;
  match: RuleMatch;
  lease?: RuleLease;
  enabled: boolean;
  /** Hub decision for matching cards (default `"approve"`). */
  action?: "approve" | "reject";
  /** `"learned"` marks rules created from a human swipe (I-1003);
   *  absent/`"manual"` otherwise. Advisory only — never matched on. */
  source?: "manual" | "learned";
}

/** True when this rule is currently allowed to fire for `task` at `now`,
 *  ignoring the lease count (which the hub tracks in `leaseUsed`). */
export function ruleMatches(rule: Rule, task: TaskCardPayload, now: number): boolean {
  if (!rule.enabled) return false;
  const until = rule.lease?.until;
  if (until !== undefined) {
    const at = Date.parse(until);
    if (!Number.isFinite(at) || at <= now) return false;
  }
  const m = rule.match;
  if (m.agent !== undefined && !task.agent.name.includes(m.agent)) return false;
  if (
    m.severity !== undefined &&
    m.severity.length > 0 &&
    !m.severity.includes(task.severity ?? "info")
  ) {
    return false;
  }
  if (m.groupKey !== undefined && !(task.groupKey ?? "").includes(m.groupKey)) {
    return false;
  }
  if (m.maxCost !== undefined && (task.impact?.cost?.amount ?? 0) > m.maxCost) {
    return false;
  }
  if (
    m.minConfidence !== undefined &&
    (task.confidence === undefined || task.confidence < m.minConfidence)
  ) {
    return false;
  }
  return true;
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
  /** Multi-party approval (I-502): this many distinct approvals are
   *  required before the card commits. Absent = 1. Integer ≥ 1. */
  requiredApprovals?: number;
  /** Options for `decisionKind: "choose"` (I-111); at least two, each
   *  `{id, label}`. Frozen on the card so the reply can echo `id`. */
  choices?: Choice[];
  /** Hub-set: the colleague this card was delegated to (I-501). Set by
   *  an `action: "delegate"` reply; never sent by agents. */
  delegatedTo?: string;
  /** Hub-computed urgency score (I-206); higher = more urgent. Never
   *  sent by agents — attached by the hub on broadcast/snapshot. */
  priority?: number;
  /** Hub marker on `createTaskCard` re-broadcasts after an agent update
   *  (I-204): clients may show a 「更新されました」 hint. */
  revised?: boolean;
  /** I-804: agent-declared scope required to act on this card. */
  requiredScope?: string;
  /** I-804: hub stamps true when the agent is unverified or lacks the
   *  required scope (card still enqueues; clients warn). */
  scopeViolation?: boolean;
  /** I-208: dry-run preview rendered in the details/inspect view as a
   *  実行プレビュー section. Malformed preview/components are dropped. */
  preview?: { title?: string; components: CardComponent[] };
}

export interface ActionReply {
  taskId: string;
  nonce: string;
  actionName: string;
  timestamp: string;
  source: string;
  data?: Record<string, unknown>;
  /** `"snooze"` asks the hub to hide the card until `until` instead of
   *  processing it (server-side snooze); `"delegate"` hands the card to
   *  a colleague (`data.to`) without deciding it (I-501). */
  action?: "snooze" | "delegate";
  /** ISO 8601 instant the snoozed card resurfaces; required with
   *  `action: "snooze"`, at most 7 days out. */
  until?: string;
  /** I-1003: on a committed approve/reject, also learn a `"learned"`
   *  rule from this card's agent/severity/groupKey. Advisory only —
   *  ignored on snooze/delegate/partial approvals. */
  /**
   * I-1003/I-1005: learn a rule from this swipe. `true` = current behavior.
   * Object form builds a rule from the card but merges/overrides with
   * provided match/action/lease; `source: "learned"`.
   */
  learnRule?: boolean | { match?: RuleMatch; action?: "approve" | "reject"; lease?: RuleLease };
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
  /** Partial approvals so far for a `requiredApprovals > 1` card
   *  (I-502). The card stays `pending` until `approvals.length` reaches
   *  `task.requiredApprovals`. */
  approvals?: Approval[];
}

/** One recorded approval on a multi-party card (I-502). */
export interface Approval {
  source: string;
  at: string;
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
  /** True while the operator has paused the fleet (I-403). Advisory:
   *  agents SHOULD stop starting new work (see docs/protocol.md). */
  paused: boolean;
  /** Current auto-approval rules (I-304/I-807). */
  rules: Rule[];
  /** Partial-approval progress for `requiredApprovals > 1` cards, keyed
   *  by taskId → approvals recorded so far (I-502). */
  approvalProgress: Record<string, number>;
}

export type ActionDecision =
  | { kind: "apply" }
  | { kind: "snooze" }
  | { kind: "delegate" }
  | { kind: "approve_partial" }
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
  // Delegation (I-501): hand the card to a colleague without deciding it;
  // the card stays pending (and keeps its nonce).
  if (reply.action === "delegate") return { kind: "delegate" };
  // Multi-party approval (I-502): an approve on a card that needs more
  // than one distinct approval records a partial until the Nth arrives.
  if (reply.actionName === "approve") {
    const required = stored.task.requiredApprovals ?? 1;
    if (required > 1 && (stored.approvals?.length ?? 0) + 1 < required) {
      return { kind: "approve_partial" };
    }
  }
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
    for (const key of [
      "onSwipeRight",
      "onSwipeLeft",
      "onSwipeUp",
      "onSwipeDown",
    ] as const) {
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

  // I-502: multi-party approval count (absent = 1).
  let requiredApprovals: number | undefined;
  if (body.requiredApprovals !== undefined) {
    const raw = body.requiredApprovals;
    if (typeof raw !== "number" || !Number.isInteger(raw) || raw < 1) {
      return fail("requiredApprovals must be an integer >= 1");
    }
    requiredApprovals = raw;
  }

  // I-111: choose options. `decisionKind: "choose"` cards must offer at
  // least two and declare both up/down swipe bindings; the reply echoes
  // the picked option back as `data.choice = id`.
  let choices: Choice[] | undefined;
  if (body.choices !== undefined) {
    if (!Array.isArray(body.choices)) return fail("choices must be an array");
    const kept: Choice[] = [];
    for (const c of body.choices) {
      if (
        !isRecord(c) ||
        typeof c.id !== "string" ||
        c.id.length === 0 ||
        typeof c.label !== "string" ||
        c.label.length === 0
      ) {
        return fail("every choice needs non-empty string id and label");
      }
      kept.push({ id: c.id, label: c.label });
    }
    choices = kept;
  }
  if (
    decisionKind === "choose" &&
    ((choices?.length ?? 0) < 2 || !actions.onSwipeUp || !actions.onSwipeDown)
  ) {
    return fail(
      'decisionKind "choose" requires >= 2 choices and both onSwipeUp / onSwipeDown bindings',
    );
  }

  // I-804: optional agent-declared required scope.
  let requiredScope: string | undefined;
  if (body.requiredScope !== undefined) {
    if (typeof body.requiredScope !== "string" || body.requiredScope.length === 0) {
      return fail("requiredScope must be a non-empty string");
    }
    requiredScope = body.requiredScope;
  }

  // I-208: preview. Lenient validation — malformed fields/components
  // dropped, field dropped if nothing valid remains.
  let preview: { title?: string; components: CardComponent[] } | undefined;
  if (isRecord(body.preview)) {
    const raw = body.preview;
    const componentsRaw = raw.components;
    if (Array.isArray(componentsRaw)) {
      const kept: CardComponent[] = [];
      for (const c of componentsRaw) {
        if (
          isRecord(c) &&
          typeof c.id === "string" &&
          typeof c.component === "string"
        ) {
          kept.push(c as unknown as CardComponent);
        }
      }
      if (kept.length > 0) {
        preview = {
          components: kept,
          ...(typeof raw.title === "string" && raw.title.length > 0
            ? { title: raw.title }
            : {}),
        };
      }
    }
  }

  // Hub-set delegation target (I-501). Agents never send it; accepted so
  // an update round-trips the current value.
  let delegatedTo: string | undefined;
  if (body.delegatedTo !== undefined) {
    if (typeof body.delegatedTo !== "string" || body.delegatedTo.length === 0) {
      return fail("delegatedTo must be a non-empty string");
    }
    delegatedTo = body.delegatedTo;
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
    ...(requiredApprovals !== undefined ? { requiredApprovals } : {}),
    ...(choices !== undefined ? { choices } : {}),
    ...(delegatedTo !== undefined ? { delegatedTo } : {}),
    ...(requiredScope !== undefined ? { requiredScope } : {}),
    ...(preview !== undefined ? { preview } : {}),
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

  if (
    body.action !== undefined &&
    body.action !== "snooze" &&
    body.action !== "delegate"
  ) {
    return fail('action must be "snooze" or "delegate" when present');
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

  if (body.action === "delegate") {
    const to = isRecord(body.data) ? body.data.to : undefined;
    if (typeof to !== "string" || to.length === 0) {
      return fail("delegate requires data.to (non-empty string)");
    }
    return {
      ok: true,
      value: {
        taskId,
        nonce,
        actionName: "delegate",
        timestamp:
          typeof body.timestamp === "string"
            ? body.timestamp
            : new Date().toISOString(),
        source: typeof body.source === "string" ? body.source : "delegate",
        action: "delegate",
        data: body.data as Record<string, unknown>,
      },
    };
  }

  if (typeof actionName !== "string" || actionName.length === 0) {
    return fail("actionName (string) is required");
  }

  // I-1005: learnRule can be boolean or object form.
  let learnRule:
    | true
    | { match?: RuleMatch; action?: "approve" | "reject"; lease?: RuleLease }
    | undefined;
  if (body.learnRule === true) {
    learnRule = true;
  } else if (isRecord(body.learnRule)) {
    const lr = body.learnRule;
    const lrMatch = lr.match;
    let match: RuleMatch | undefined;
    if (isRecord(lrMatch)) {
      const m: RuleMatch = {};
      if (typeof lrMatch.agent === "string" && lrMatch.agent.length > 0) {
        m.agent = lrMatch.agent;
      }
      if (Array.isArray(lrMatch.severity)) {
        const kept = lrMatch.severity.filter(
          (s): s is "info" | "warning" | "critical" =>
            s === "info" || s === "warning" || s === "critical",
        );
        if (kept.length > 0) m.severity = kept;
      }
      if (typeof lrMatch.groupKey === "string" && lrMatch.groupKey.length > 0) {
        m.groupKey = lrMatch.groupKey;
      }
      if (typeof lrMatch.maxCost === "number") m.maxCost = lrMatch.maxCost;
      if (
        typeof lrMatch.minConfidence === "number" &&
        lrMatch.minConfidence >= 0 &&
        lrMatch.minConfidence <= 1
      ) {
        m.minConfidence = lrMatch.minConfidence;
      }
      if (Object.keys(m).length > 0) match = m;
    }
    const action =
      lr.action === "approve" || lr.action === "reject" ? lr.action : undefined;
    const lease = isRecord(lr.lease) ? (lr.lease as RuleLease) : undefined;
    if (match !== undefined || action !== undefined || lease !== undefined) {
      learnRule = {
        ...(match ? { match } : {}),
        ...(action ? { action } : {}),
        ...(lease ? { lease } : {}),
      };
    }
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
      ...(learnRule === true
        ? { learnRule: true as const }
        : learnRule && typeof learnRule === "object"
          ? { learnRule }
          : {}),
    },
  };
}

/** One item of a bulk triage request (I-201 `POST /api/v1/actions/bulk`). */
export interface BulkActionItem {
  taskId: string;
  nonce: string;
  actionName: string;
  source: string;
  /** Present only for `delegate` items (I-501). */
  action?: "delegate";
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
    if (action === "delegate") {
      const to = isRecord(item.data) ? item.data.to : undefined;
      if (typeof to !== "string" || to.length === 0) {
        return fail("delegate requires data.to (non-empty string)");
      }
      actions.push({
        taskId,
        nonce,
        actionName: "delegate",
        source: typeof source === "string" ? source : "bulk",
        action: "delegate",
        data: item.data as Record<string, unknown>,
      });
      continue;
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

/**
 * Validates a `PUT /api/v1/rules` body `{rules:[…]}` (I-304/I-807). Each
 * rule is normalized strictly — a malformed rule would silently widen an
 * auto-approval policy, so it is rejected rather than dropped.
 */
export function validateRules(body: unknown): ValidationResult<Rule[]> {
  if (!isRecord(body)) return fail("payload must be a JSON object");
  const raw = body.rules;
  if (!Array.isArray(raw)) return fail("rules must be an array");
  const rules: Rule[] = [];
  for (const item of raw) {
    if (!isRecord(item)) return fail("every rule must be an object");
    const id = item.id;
    if (typeof id !== "string" || id.length === 0) {
      return fail("every rule needs a non-empty string id");
    }

    const match: RuleMatch = {};
    if (item.match !== undefined) {
      if (!isRecord(item.match)) return fail("rule.match must be an object");
      const m = item.match;
      if (m.agent !== undefined) {
        if (typeof m.agent !== "string") {
          return fail("rule.match.agent must be a string");
        }
        match.agent = m.agent;
      }
      if (m.severity !== undefined) {
        if (!Array.isArray(m.severity) || m.severity.some((s) => typeof s !== "string")) {
          return fail("rule.match.severity must be an array of strings");
        }
        match.severity = m.severity as string[];
      }
      if (m.maxCost !== undefined) {
        if (typeof m.maxCost !== "number" || !Number.isFinite(m.maxCost)) {
          return fail("rule.match.maxCost must be a number");
        }
        match.maxCost = m.maxCost;
      }
      if (m.groupKey !== undefined) {
        if (typeof m.groupKey !== "string") {
          return fail("rule.match.groupKey must be a string");
        }
        match.groupKey = m.groupKey;
      }
      if (m.minConfidence !== undefined) {
        if (
          typeof m.minConfidence !== "number" ||
          !Number.isFinite(m.minConfidence) ||
          m.minConfidence < 0 ||
          m.minConfidence > 1
        ) {
          return fail("rule.match.minConfidence must be a number between 0 and 1");
        }
        match.minConfidence = m.minConfidence;
      }
    }

    let lease: RuleLease | undefined;
    if (item.lease !== undefined) {
      if (!isRecord(item.lease)) return fail("rule.lease must be an object");
      const l = item.lease;
      lease = {};
      if (l.until !== undefined) {
        if (typeof l.until !== "string" || !Number.isFinite(Date.parse(l.until))) {
          return fail("rule.lease.until must be an ISO 8601 date string");
        }
        lease.until = l.until;
      }
      if (l.maxCount !== undefined) {
        if (typeof l.maxCount !== "number" || !Number.isInteger(l.maxCount) || l.maxCount < 1) {
          return fail("rule.lease.maxCount must be an integer >= 1");
        }
        lease.maxCount = l.maxCount;
      }
    }

    const enabled = item.enabled === undefined ? true : item.enabled;
    if (typeof enabled !== "boolean") {
      return fail("rule.enabled must be a boolean");
    }
    const action = item.action;
    if (action !== undefined && action !== "approve" && action !== "reject") {
      return fail('rule.action must be "approve" or "reject" when present');
    }
    const source = item.source;
    if (source !== undefined && source !== "manual" && source !== "learned") {
      return fail('rule.source must be "manual" or "learned" when present');
    }
    rules.push({
      id,
      match,
      ...(lease !== undefined ? { lease } : {}),
      enabled,
      // Absent stays absent: pre-I-1002 payloads round-trip unchanged
      // (existing tests/clients); match time treats it as "approve".
      ...(action !== undefined ? { action } : {}),
      ...(source !== undefined ? { source } : {}),
    });
  }
  return { ok: true, value: rules };
}

/** One-time pairing code TTL (I-808). */
export const PAIR_TTL_MS = 5 * 60 * 1000;

/** `POST /api/v1/pair` body (I-808): both fields optional. */
export interface PairRequest {
  device?: string;
  user?: string;
}

/** Stored pairing challenge (`pair:<code>`). */
export interface PairCode {
  user: string;
  device?: string;
  expiresAt: number;
}

/** Stored device-token record (`device:<sha256>`), I-808/I-809. */
export interface DeviceRecord {
  user: string;
  createdAt: string;
}

export function validatePairRequest(
  body: unknown,
): ValidationResult<PairRequest> {
  if (body === undefined || body === null) return { ok: true, value: {} };
  if (!isRecord(body)) return fail("payload must be a JSON object");
  const out: PairRequest = {};
  if (body.device !== undefined) {
    if (typeof body.device !== "string" || body.device.length === 0) {
      return fail("device must be a non-empty string");
    }
    out.device = body.device;
  }
  if (body.user !== undefined) {
    if (typeof body.user !== "string" || body.user.length === 0) {
      return fail("user must be a non-empty string");
    }
    out.user = body.user;
  }
  return { ok: true, value: out };
}

export function validateRedeemRequest(
  body: unknown,
): ValidationResult<{ code: string }> {
  if (!isRecord(body)) return fail("payload must be a JSON object");
  const code = body.code;
  if (typeof code !== "string" || code.length === 0) {
    return fail("code (string) is required");
  }
  return { ok: true, value: { code } };
}

/** `POST /api/v1/rules/simulate` body (I-1002): an optional candidate
 *  `match` evaluated on top of the stored rules plus an optional
 *  candidate `action`. Both absent = dry-run the current rule set. */
export interface SimulateRequest {
  match?: RuleMatch;
  action?: "approve" | "reject";
}

export function validateSimulateRequest(
  body: unknown,
): ValidationResult<SimulateRequest> {
  if (body === undefined || body === null) return { ok: true, value: {} };
  if (!isRecord(body)) return fail("payload must be a JSON object");
  const out: SimulateRequest = {};
  if (body.match !== undefined) {
    if (!isRecord(body.match)) return fail("match must be an object");
    const parsed = validateRules({ rules: [{ id: "candidate", match: body.match }] });
    if (!parsed.ok) return fail(parsed.error.replace(/^rule\./, "match."));
    out.match = parsed.value[0].match;
  }
  if (body.action !== undefined) {
    if (body.action !== "approve" && body.action !== "reject") {
      return fail('action must be "approve" or "reject" when present');
    }
    out.action = body.action;
  }
  return { ok: true, value: out };
}

/** `POST /api/v1/attachments` body (I-1001). */
export interface AttachmentUpload {
  kind: "audio" | "image";
  contentType: string;
  dataBase64: string;
}

/** Decoded size cap: 413 past 2 MiB. */
export const MAX_ATTACHMENT_BYTES = 2 * 1024 * 1024;

export function validateAttachmentUpload(
  body: unknown,
): ValidationResult<AttachmentUpload> {
  if (!isRecord(body)) return fail("payload must be a JSON object");
  const { kind, contentType, dataBase64 } = body;
  if (kind !== "audio" && kind !== "image") {
    return fail('kind must be "audio" or "image"');
  }
  if (typeof contentType !== "string" || contentType.length === 0) {
    return fail("contentType (non-empty string) is required");
  }
  if (!/^[-\w.+]+\/[-\w.+]+$/.test(contentType)) {
    return fail("contentType must look like a MIME type");
  }
  if (typeof dataBase64 !== "string" || dataBase64.length === 0) {
    return fail("dataBase64 (non-empty string) is required");
  }
  return { ok: true, value: { kind, contentType, dataBase64 } };
}
