// I-909: adversarial payload fuzzing for the wire-protocol validators and
// the pure CAS decision functions. Deterministic (mulberry32, fixed seed),
// so every failure is reproducible from the seed + mutation labels printed
// in the assertion message.
//
// Contract under test:
//  - validateTaskCard / validateActionReply never throw; they always return
//    a ValidationResult (`{ok:true,value}` | `{ok:false,error}`).
//  - Malformed behavior-bearing fields (agent/summary/components/actions/
//    confidence/expiresAt/onExpire) are rejected, never normalized into a
//    silently different behavior.
//  - Advisory fields (severity/surfaceId/createdAt/confidenceReasons/impact/
//    context/rejectReasons/unknown keys) are dropped or normalized tolerantly
//    and never crash.
//  - decideAction / decideUndo never throw for any status/nonce combination.

import { describe, expect, it } from "vitest";
import {
  decideAction,
  decideUndo,
  validateActionReply,
  validateTaskCard,
} from "./protocol";
import type {
  ActionDecision,
  ActionReply,
  StoredTask,
  TaskCardPayload,
  TaskStatus,
  UndoDecision,
  ValidationResult,
} from "./protocol";

// ---------------------------------------------------------------------------
// determinism helpers
// ---------------------------------------------------------------------------

/** Deterministic PRNG so a failing case can be replayed from its seed. */
function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const SEED = 0x909;

function randInt(rnd: () => number, maxExclusive: number): number {
  return Math.floor(rnd() * maxExclusive);
}

function pick<T>(rnd: () => number, arr: readonly T[]): T {
  return arr[randInt(rnd, arr.length)];
}

// ---------------------------------------------------------------------------
// fixtures
// ---------------------------------------------------------------------------

/** A fully-populated, valid agent card. Fresh each call (mutated by fuzz). */
function baseCard() {
  return {
    type: "createTaskCard",
    taskId: "task_fuzz_1",
    nonce: "tok_fuzz_1",
    agent: { name: "Fuzz Agent", avatarUrl: "https://example.com/a.png" },
    confidence: 0.8,
    confidenceReasons: ["r1", "r2"],
    severity: "warning",
    summary: "Fuzz summary 日本語",
    surfaceId: "surface_1",
    createdAt: "2026-10-05T00:00:00.000Z",
    replyUrl: "https://example.com/reply",
    components: [
      { id: "root", component: "TriageCard", children: ["t", "d"] },
      { id: "t", component: "Text", properties: { text: "hi" } },
      { id: "d", component: "DiffBox", properties: { before: "a", after: "b" } },
      { id: "q", component: "QuickOptions", properties: { options: [] } },
    ],
    actions: {
      onSwipeRight: { actionName: "approve", payload: { decision: "ACCEPT" } },
      onSwipeLeft: { actionName: "reject", payload: { decision: "DECLINE" } },
      inspectForm: [
        { id: "tp", component: "TimePicker", properties: { label: "t" } },
      ],
      rejectReasons: [{ id: "r", label: "reason" }],
    },
    impact: {
      summary: "does X",
      reversible: false,
      cost: { amount: 10, currency: "JPY" },
      scope: "s",
    },
    context: {
      requester: { name: "req", onBehalfOf: "boss" },
      participants: [{ name: "p1", status: "busy" }],
      reasoning: "because",
      source: { label: "mail", url: "https://example.com/m" },
    },
    expiresAt: "2026-10-05T01:00:00.000Z",
    onExpire: "drop",
    protocolVersion: 1,
    groupKey: "grp_1",
    decisionKind: "choose",
    editable: { componentId: "t", kind: "number", min: 0, max: 10, step: 1 },
    // Hub-attached only (I-206/I-204): an agent that sends these must not
    // have them echoed back by validation.
    priority: 42,
    revised: true,
  };
}

function baseReply() {
  return {
    taskId: "task_1",
    nonce: "tok_1",
    actionName: "approve",
    timestamp: "2026-10-05T00:00:00.000Z",
    source: "swipe_gesture",
    data: { decision: "ACCEPT" },
  };
}

function cardFixture(nonce: string): TaskCardPayload {
  return {
    type: "createTaskCard",
    taskId: "task_1",
    nonce,
    agent: { name: "A" },
    summary: "s",
    createdAt: "2026-10-05T00:00:00.000Z",
    components: [],
    actions: {},
  };
}

// ---------------------------------------------------------------------------
// result plumbing (unwraps "never throws, always a ValidationResult")
// ---------------------------------------------------------------------------

function cardResult(
  body: unknown,
  label: string,
): ValidationResult<TaskCardPayload> {
  let result: ValidationResult<TaskCardPayload> | undefined;
  let threw: unknown = null;
  try {
    result = validateTaskCard(body);
  } catch (error) {
    threw = error;
  }
  expect(threw, `${label}: validator threw`).toBeNull();
  expect(result, label).toBeDefined();
  return result as ValidationResult<TaskCardPayload>;
}

function replyResult(
  body: unknown,
  label: string,
): ValidationResult<ActionReply> {
  let result: ValidationResult<ActionReply> | undefined;
  let threw: unknown = null;
  try {
    result = validateActionReply(body);
  } catch (error) {
    threw = error;
  }
  expect(threw, `${label}: validator threw`).toBeNull();
  expect(result, label).toBeDefined();
  return result as ValidationResult<ActionReply>;
}

/** Invariants every `ok:true` card must satisfy, plus normalization. */
function assertCardShape(value: TaskCardPayload, label: string): void {
  expect(value.type, label).toBe("createTaskCard");
  expect(typeof value.taskId, label).toBe("string");
  expect(value.taskId.length, label).toBeGreaterThan(0);
  expect(typeof value.nonce, label).toBe("string");
  expect(value.nonce.length, label).toBeGreaterThan(0);
  expect(typeof value.agent.name, label).toBe("string");
  expect(value.agent.name.length, label).toBeGreaterThan(0);
  expect(typeof value.summary, label).toBe("string");
  expect(value.summary.length, label).toBeGreaterThan(0);
  expect(Array.isArray(value.components), label).toBe(true);
  for (const c of value.components) {
    expect(typeof c.id, label).toBe("string");
    expect(typeof c.component, label).toBe("string");
  }
  expect(typeof value.actions, label).toBe("object");
  if (value.confidence !== undefined) {
    expect(Number.isFinite(value.confidence), label).toBe(true);
    expect(value.confidence, label).toBeGreaterThanOrEqual(0);
    expect(value.confidence, label).toBeLessThanOrEqual(1);
  }
  if (value.expiresAt !== undefined) {
    expect(typeof value.expiresAt, label).toBe("string");
    expect(Number.isFinite(Date.parse(value.expiresAt)), label).toBe(true);
  }
  if (value.onExpire !== undefined) {
    expect(
      value.expiresAt,
      `${label} (onExpire requires expiresAt)`,
    ).toBeDefined();
  }
  // I-606: when a wire version is present it is a positive integer.
  if (value.protocolVersion !== undefined) {
    expect(Number.isInteger(value.protocolVersion), label).toBe(true);
    expect(value.protocolVersion, label).toBeGreaterThanOrEqual(1);
  }
  if (value.groupKey !== undefined) {
    expect(typeof value.groupKey, label).toBe("string");
    expect(value.groupKey.length, label).toBeGreaterThan(0);
  }
  if (value.decisionKind !== undefined) {
    expect(["approve", "choose", "fill"], label).toContain(value.decisionKind);
  }
  if (value.editable !== undefined) {
    expect(typeof value.editable.componentId, label).toBe("string");
    expect(value.editable.componentId.length, label).toBeGreaterThan(0);
    expect(["number", "datetime"], label).toContain(value.editable.kind);
  }
}

function assertReplyShape(value: ActionReply, label: string): void {
  expect(typeof value.taskId, label).toBe("string");
  expect(value.taskId.length, label).toBeGreaterThan(0);
  expect(typeof value.nonce, label).toBe("string");
  expect(value.nonce.length, label).toBeGreaterThan(0);
  expect(typeof value.actionName, label).toBe("string");
  expect(value.actionName.length, label).toBeGreaterThan(0);
  expect(typeof value.timestamp, label).toBe("string");
  expect(typeof value.source, label).toBe("string");
  if (value.data !== undefined) {
    expect(typeof value.data, label).toBe("object");
    expect(Array.isArray(value.data), label).toBe(false);
  }
  if (value.action === "snooze") {
    expect(typeof value.until, label).toBe("string");
    expect(Number.isFinite(Date.parse(value.until ?? "")), label).toBe(true);
  }
}

// ---------------------------------------------------------------------------
// random JSON + mutation engine
// ---------------------------------------------------------------------------

const JUNK_KEYS = [
  "agent",
  "summary",
  "components",
  "actions",
  "confidence",
  "confidenceReasons",
  "severity",
  "surfaceId",
  "createdAt",
  "replyUrl",
  "expiresAt",
  "onExpire",
  "taskId",
  "nonce",
  "impact",
  "context",
  "type",
  "protocolVersion",
  "groupKey",
  "decisionKind",
  "editable",
  "__junk",
  "",
  "🤖",
];

const WILD_STRINGS = [
  "approve",
  "drop",
  "explode",
  "",
  "🚀🚀🚀",
  "\u202Ertl-override\u202C",
  "עברית",
  "العربية",
  "👨‍👩‍👧‍👦",
  "\u0000\u0001",
  "https://example.com/x",
  "javascript:alert(1)",
];

/** A random JSON-ish value (never NaN/Infinity: the wire is JSON). */
function randomJson(rnd: () => number, depth: number): unknown {
  if (depth <= 0 || rnd() < 0.35) {
    switch (randInt(rnd, 7)) {
      case 0:
        return null;
      case 1:
        return rnd() < 0.5;
      case 2:
        return randInt(rnd, 2_000_000) - 1_000_000;
      case 3:
        return (rnd() - 0.5) * 2000;
      case 4:
        return "";
      case 5:
        return pick(rnd, WILD_STRINGS);
      default:
        return rnd() * 100;
    }
  }
  if (rnd() < 0.5) {
    const n = randInt(rnd, 5);
    return Array.from({ length: n }, () => randomJson(rnd, depth - 1));
  }
  const obj: Record<string, unknown> = {};
  const n = randInt(rnd, 6);
  for (let i = 0; i < n; i++) {
    obj[pick(rnd, JUNK_KEYS)] = randomJson(rnd, depth - 1);
  }
  return obj;
}

interface Mutation {
  name: string;
  apply: (rnd: () => number, body: Record<string, unknown>) => void;
}

const WRONG_TYPES: readonly unknown[] = [
  null,
  true,
  42,
  -1.5,
  "",
  "nope",
  [],
  {},
  ["x"],
  { nested: true },
];

const MUTATIONS: readonly Mutation[] = [
  {
    name: "drop-random-field",
    apply: (rnd, body) => {
      const keys = Object.keys(body);
      if (keys.length > 0) delete body[pick(rnd, keys)];
    },
  },
  {
    name: "randomize-field",
    apply: (rnd, body) => {
      const keys = Object.keys(body);
      if (keys.length > 0) body[pick(rnd, keys)] = randomJson(rnd, 3);
    },
  },
  {
    name: "summary-wrong-type",
    apply: (rnd, body) => {
      body.summary = pick(rnd, WRONG_TYPES);
    },
  },
  {
    name: "agent-wrong-type",
    apply: (rnd, body) => {
      body.agent = pick(rnd, WRONG_TYPES);
    },
  },
  {
    name: "agent-name-wrong-type",
    apply: (rnd, body) => {
      body.agent = { name: pick(rnd, WRONG_TYPES) };
    },
  },
  {
    name: "confidence-out-of-range",
    apply: (rnd, body) => {
      body.confidence = pick(rnd, [
        -0.0001,
        -1,
        1.0001,
        2,
        "0.5",
        null,
        {},
        [],
        true,
      ]);
    },
  },
  {
    name: "expiresAt-invalid",
    apply: (rnd, body) => {
      body.expiresAt = pick(rnd, [
        "not-a-date",
        12345,
        null,
        "",
        {},
        "2026-13-45T99:99:99Z",
        ["2026-10-05T00:00:00Z"],
      ]);
    },
  },
  {
    name: "onExpire-invalid",
    apply: (rnd, body) => {
      body.onExpire = pick(rnd, ["explode", "APPROVE", "", 5, null, {}, true]);
    },
  },
  {
    name: "onExpire-without-expiresAt",
    apply: (rnd, body) => {
      delete body.expiresAt;
      body.onExpire = pick(rnd, ["approve", "reject", "escalate", "drop"]);
    },
  },
  {
    name: "components-not-array",
    apply: (rnd, body) => {
      body.components = pick(rnd, ["nope", {}, 5, null, true]);
    },
  },
  {
    name: "component-entry-malformed",
    apply: (rnd, body) => {
      const list = Array.isArray(body.components) ? body.components : [];
      list.push(pick(rnd, [null, "x", 5, {}, { id: 5 }, { component: 5 }]));
      body.components = list;
    },
  },
  {
    name: "actions-wrong-type",
    apply: (rnd, body) => {
      body.actions = pick(rnd, [[], "approve", 5, null, true]);
    },
  },
  {
    name: "swipe-binding-malformed",
    apply: (rnd, body) => {
      const actions =
        typeof body.actions === "object" && body.actions !== null
          ? (body.actions as Record<string, unknown>)
          : {};
      actions.onSwipeRight = pick(rnd, [
        "approve",
        { label: "no actionName" },
        { actionName: 5 },
        null,
        [],
      ]);
      body.actions = actions;
    },
  },
  {
    name: "inspectForm-malformed",
    apply: (rnd, body) => {
      const actions =
        typeof body.actions === "object" && body.actions !== null
          ? (body.actions as Record<string, unknown>)
          : {};
      actions.inspectForm = pick(rnd, [
        "nope",
        5,
        {},
        [null],
        [{ id: 1 }],
      ]);
      body.actions = actions;
    },
  },
  {
    name: "rejectReasons-malformed",
    apply: (rnd, body) => {
      const actions =
        typeof body.actions === "object" && body.actions !== null
          ? (body.actions as Record<string, unknown>)
          : {};
      actions.rejectReasons = pick(rnd, [
        "oops",
        [{ id: 1, label: 2 }],
        [{ id: "ok", label: "ok" }, "junk"],
        null,
      ]);
      body.actions = actions;
    },
  },
  {
    name: "replyUrl-invalid",
    apply: (rnd, body) => {
      body.replyUrl = pick(rnd, [
        "javascript:alert(1)",
        "ftp://x",
        "example.com",
        5,
        null,
        {},
      ]);
    },
  },
  {
    name: "unknown-component-type",
    apply: (rnd, body) => {
      const list = Array.isArray(body.components) ? body.components : [];
      list.push({
        id: `unknown_${randInt(rnd, 1e6)}`,
        component: pick(rnd, ["HologramWidget", "🧩", "", "TriageCard2"]),
        properties: { weird: [1, { deep: true }] },
      });
      body.components = list;
    },
  },
  {
    name: "unicode-payload",
    apply: (rnd, body) => {
      body[pick(rnd, ["summary", "surfaceId", "taskId"])] = pick(
        rnd,
        WILD_STRINGS,
      );
      if (typeof body.agent !== "object" || body.agent === null) {
        body.agent = { name: pick(rnd, WILD_STRINGS) };
      } else {
        (body.agent as Record<string, unknown>).name = pick(rnd, WILD_STRINGS);
      }
    },
  },
  {
    name: "jumbo-string",
    apply: (rnd, body) => {
      const keys = Object.keys(body);
      if (keys.length === 0) return;
      body[pick(rnd, keys)] = "x".repeat(rnd() < 0.25 ? 1 << 20 : 1 << 12);
    },
  },
  {
    name: "deep-nesting",
    apply: (rnd, body) => {
      let nested: unknown = { leaf: true };
      const depth = 40 + randInt(rnd, 12); // up to depth ~52
      for (let i = 0; i < depth; i++) nested = { child: [nested] };
      const list = Array.isArray(body.components) ? body.components : [];
      list.push({ id: "deep", component: "Text", properties: { nested } });
      body.components = list;
    },
  },
  {
    name: "context-malformed",
    apply: (rnd, body) => {
      body.context = pick(rnd, [
        "oops",
        5,
        { participants: "not-array" },
        { participants: [null, 5, { name: 1 }] },
        { requester: { name: 5 }, source: { label: 5, url: "javascript:1" } },
      ]);
    },
  },
  {
    name: "impact-malformed",
    apply: (rnd, body) => {
      body.impact = pick(rnd, [
        "oops",
        5,
        { cost: { amount: "x", currency: 1 } },
        { reversible: "yes", summary: 5 },
      ]);
    },
  },
  {
    name: "protocolVersion-invalid",
    apply: (rnd, body) => {
      body.protocolVersion = pick(rnd, [0, -1, 1.5, "1", null, {}, Number.NaN]);
    },
  },
  {
    name: "groupKey-invalid",
    apply: (rnd, body) => {
      body.groupKey = pick(rnd, ["", 5, null, {}, []]);
    },
  },
  {
    name: "decisionKind-invalid",
    apply: (rnd, body) => {
      body.decisionKind = pick(rnd, ["explode", "APPROVE", 5, null, {}]);
    },
  },
  {
    name: "editable-invalid",
    apply: (rnd, body) => {
      body.editable = pick(rnd, [
        "x",
        5,
        {},
        { componentId: "", kind: "number" },
        { componentId: "c", kind: "slider" },
        { componentId: "c", kind: "number", min: "0" },
      ]);
    },
  },
];

function mutate(rnd: () => number, body: Record<string, unknown>): string[] {
  const applied: string[] = [];
  const k = 1 + randInt(rnd, 3);
  for (let i = 0; i < k; i++) {
    const m = pick(rnd, MUTATIONS);
    m.apply(rnd, body);
    applied.push(m.name);
  }
  return applied;
}

// ---------------------------------------------------------------------------
// validateTaskCard
// ---------------------------------------------------------------------------

describe("fuzz: validateTaskCard", () => {
  it("rejects non-object roots without throwing", () => {
    const roots: [string, unknown][] = [
      ["null", null],
      ["undefined", undefined],
      ["number", 42],
      ["NaN", Number.NaN],
      ["string", "nope"],
      ["bool", true],
      ["array", []],
      ["array-of-object", [{}]],
      ["function", () => 1],
      ["date", new Date()],
      ["map", new Map()],
      ["empty-object", {}],
    ];
    for (const [label, root] of roots) {
      const result = cardResult(root, label);
      expect(result.ok, label).toBe(false);
    }
  });

  it("rejects wrong types per field, tolerating advisory-only corruption", () => {
    const base = baseCard();
    const cases: [string, unknown, boolean][] = [
      ["agent missing", { ...base, agent: undefined }, false],
      ["agent string", { ...base, agent: "x" }, false],
      ["agent.name number", { ...base, agent: { name: 5 } }, false],
      ["agent.name empty", { ...base, agent: { name: "" } }, false],
      ["summary number", { ...base, summary: 5 }, false],
      ["summary empty", { ...base, summary: "" }, false],
      ["summary null", { ...base, summary: null }, false],
      ["components string", { ...base, components: "nope" }, false],
      [
        "components entry missing id",
        { ...base, components: [{ component: "Text" }] },
        false,
      ],
      ["components entry non-object", { ...base, components: ["x"] }, false],
      ["actions array", { ...base, actions: [] }, false],
      ["actions string", { ...base, actions: "approve" }, false],
      ["onSwipeRight string", { ...base, actions: { onSwipeRight: "approve" } }, false],
      [
        "onSwipeRight no actionName",
        { ...base, actions: { onSwipeRight: { label: "L" } } },
        false,
      ],
      [
        "onSwipeRight actionName number",
        { ...base, actions: { onSwipeRight: { actionName: 5 } } },
        false,
      ],
      ["inspectForm string", { ...base, actions: { inspectForm: "x" } }, false],
      ["inspectForm bad entry", { ...base, actions: { inspectForm: [null] } }, false],
      ["rejectReasons string", { ...base, actions: { rejectReasons: "oops" } }, false],
      ["replyUrl javascript", { ...base, replyUrl: "javascript:alert(1)" }, false],
      ["replyUrl number", { ...base, replyUrl: 5 }, false],
      ["expiresAt garbage", { ...base, expiresAt: "not-a-date" }, false],
      ["expiresAt number", { ...base, expiresAt: 12345 }, false],
      ["expiresAt null", { ...base, expiresAt: null }, false],
      ["onExpire unknown", { ...base, onExpire: "explode" }, false],
      ["onExpire number", { ...base, onExpire: 5 }, false],
      // I-606 / I-201 / I-114 behavior-bearing additions validate strictly:
      ["protocolVersion zero", { ...base, protocolVersion: 0 }, false],
      ["protocolVersion negative", { ...base, protocolVersion: -1 }, false],
      ["protocolVersion float", { ...base, protocolVersion: 1.5 }, false],
      ["protocolVersion string", { ...base, protocolVersion: "1" }, false],
      ["protocolVersion NaN", { ...base, protocolVersion: Number.NaN }, false],
      ["groupKey empty", { ...base, groupKey: "" }, false],
      ["groupKey number", { ...base, groupKey: 5 }, false],
      ["groupKey null", { ...base, groupKey: null }, false],
      ["decisionKind unknown", { ...base, decisionKind: "explode" }, false],
      ["decisionKind number", { ...base, decisionKind: 5 }, false],
      ["editable string", { ...base, editable: "x" }, false],
      ["editable missing componentId", { ...base, editable: { kind: "number" } }, false],
      ["editable empty componentId", { ...base, editable: { componentId: "", kind: "number" } }, false],
      [
        "editable bad kind",
        { ...base, editable: { componentId: "c", kind: "slider" } },
        false,
      ],
      [
        "editable bad min",
        { ...base, editable: { componentId: "c", kind: "number", min: "0" } },
        false,
      ],
      [
        "editable bad max",
        { ...base, editable: { componentId: "c", kind: "number", max: [] } },
        false,
      ],
      ["protocolVersion 2", { ...base, protocolVersion: 2 }, true],
      ["protocolVersion absent", { ...base, protocolVersion: undefined }, true],
      ["groupKey string", { ...base, groupKey: "g" }, true],
      ["decisionKind fill", { ...base, decisionKind: "fill" }, true],
      [
        "editable datetime",
        { ...base, editable: { componentId: "c", kind: "datetime" } },
        true,
      ],
      // advisory-only corruption is normalized, not rejected:
      ["severity wrong type", { ...base, severity: 5 }, true],
      ["severity unknown token", { ...base, severity: "urgent" }, true],
      ["surfaceId number", { ...base, surfaceId: 5 }, true],
      ["createdAt number", { ...base, createdAt: 5 }, true],
      ["confidenceReasons string", { ...base, confidenceReasons: "x" }, true],
      [
        "impact cost mistyped",
        { ...base, impact: { cost: { amount: "x", currency: 1 } } },
        true,
      ],
      ["impact string", { ...base, impact: "oops" }, true],
      ["context string", { ...base, context: "oops" }, true],
      ["type wrong", { ...base, type: "notCreateTaskCard" }, true],
      ["unknown top-level field", { ...base, __extra: { a: 1 } }, true],
    ];
    for (const [label, body, ok] of cases) {
      const result = cardResult(body, label);
      expect(result.ok, label).toBe(ok);
      if (result.ok) assertCardShape(result.value, label);
      else expect(typeof result.error, label).toBe("string");
    }
  });

  it("preserves unicode / RTL / emoji payloads verbatim", () => {
    const summary = "עברית · العربية · 🇯🇵 · \u202Ereversed\u202C · \u0000";
    const result = cardResult({ ...baseCard(), summary }, "unicode");
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.summary).toBe(summary);
  });

  it("tolerates 1 MiB strings in required and advisory fields", () => {
    const jumbo = "x".repeat(1024 * 1024);
    const bodies: [string, unknown][] = [
      ["summary", { ...baseCard(), summary: jumbo }],
      ["agent.name", { ...baseCard(), agent: { name: jumbo } }],
      [
        "component id",
        { ...baseCard(), components: [{ id: jumbo, component: "Text" }] },
      ],
      ["surfaceId", { ...baseCard(), surfaceId: jumbo }],
      ["replyUrl", { ...baseCard(), replyUrl: `https://example.com/${jumbo}` }],
    ];
    for (const [label, body] of bodies) {
      const result = cardResult(body, label);
      expect(result.ok, label).toBe(true);
      if (result.ok) assertCardShape(result.value, label);
    }
  });

  it("tolerates depth-50 nested properties and context", () => {
    let nested: unknown = { leaf: true };
    for (let i = 0; i < 50; i++) nested = { child: [nested] };
    const result = cardResult(
      {
        ...baseCard(),
        components: [
          { id: "deep", component: "Text", properties: { nested } },
          ...baseCard().components,
        ],
        context: { reasoning: "deep", extra: nested },
        impact: { summary: "deep", extra: nested },
      },
      "depth-50",
    );
    expect(result.ok).toBe(true);
    if (result.ok) assertCardShape(result.value, "depth-50");
  });

  it("passes unknown component types through untouched (FR-1.3)", () => {
    const unknown = {
      id: "hologram_1",
      component: "HologramWidget",
      properties: { spin: true, frames: [1, 2, 3] },
      children: ["a", "b"],
    };
    const result = cardResult(
      { ...baseCard(), components: [...baseCard().components, unknown] },
      "unknown-component",
    );
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    const kept = result.value.components.find((c) => c.id === "hologram_1");
    expect(kept).toBeDefined();
    expect(kept?.component).toBe("HologramWidget");
    expect(kept?.properties).toEqual({ spin: true, frames: [1, 2, 3] });
    expect(kept?.children).toEqual(["a", "b"]);
  });

  it("is stateless about duplicate taskIds (hub owns uniqueness)", () => {
    const first = cardResult(
      { ...baseCard(), taskId: "task_dup" },
      "dup-first",
    );
    const second = cardResult(
      { ...baseCard(), taskId: "task_dup" },
      "dup-second",
    );
    expect(first.ok).toBe(true);
    expect(second.ok).toBe(true);
    if (first.ok && second.ok) {
      expect(first.value.taskId).toBe("task_dup");
      expect(second.value.taskId).toBe("task_dup");
    }
  });

  it("drops unknown top-level fields without echoing them back", () => {
    const result = cardResult(
      { ...baseCard(), extra_field: 42, __junk: { polluted: true } },
      "unknown-fields",
    );
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    assertCardShape(result.value, "unknown-fields");
    expect(Object.keys(result.value)).not.toContain("extra_field");
    expect(Object.keys(result.value)).not.toContain("__junk");
    // Hub-attached fields (I-206/I-204) are never echoed from agent input.
    expect(Object.keys(result.value)).not.toContain("priority");
    expect(Object.keys(result.value)).not.toContain("revised");
  });

  it("never throws and always yields a well-formed result for random shapes", () => {
    const rnd = mulberry32(SEED);
    for (let i = 0; i < 400; i++) {
      const label = `seed=${SEED} randomJson i=${i}`;
      const result = cardResult(randomJson(rnd, 1 + randInt(rnd, 4)), label);
      expect(typeof result.ok, label).toBe("boolean");
      if (result.ok) assertCardShape(result.value, label);
      else expect(typeof result.error, label).toBe("string");
    }
  });

  it("never throws for seeded structural mutations of a valid card", () => {
    const rnd = mulberry32(SEED);
    for (let i = 0; i < 600; i++) {
      const body = JSON.parse(JSON.stringify(baseCard())) as Record<
        string,
        unknown
      >;
      const applied = mutate(rnd, body);
      const label =
        `seed=${SEED} i=${i} [${applied.join(" + ")}] ` +
        JSON.stringify(body).slice(0, 240);
      const result = cardResult(body, label);
      expect(typeof result.ok, label).toBe("boolean");
      if (result.ok) assertCardShape(result.value, label);
      else {
        expect(typeof result.error, label).toBe("string");
        expect(result.error.length, label).toBeGreaterThan(0);
      }
    }
  });
});

// ---------------------------------------------------------------------------
// validateActionReply
// ---------------------------------------------------------------------------

describe("fuzz: validateActionReply", () => {
  it("rejects non-object roots without throwing", () => {
    const roots: [string, unknown][] = [
      ["null", null],
      ["undefined", undefined],
      ["array", []],
      ["string", "approve"],
      ["number", 1],
      ["bool", false],
    ];
    for (const [label, root] of roots) {
      const result = replyResult(root, label);
      expect(result.ok, label).toBe(false);
    }
  });

  it("rejects missing/empty/wrong-typed required fields", () => {
    const cases: [string, unknown, boolean][] = [
      ["taskId missing", { nonce: "n", actionName: "a" }, false],
      ["nonce missing", { taskId: "t", actionName: "a" }, false],
      ["actionName missing", { taskId: "t", nonce: "n" }, false],
      ["taskId empty", { taskId: "", nonce: "n", actionName: "a" }, false],
      ["nonce empty", { taskId: "t", nonce: "", actionName: "a" }, false],
      ["actionName empty", { taskId: "t", nonce: "n", actionName: "" }, false],
      ["taskId number", { taskId: 5, nonce: "n", actionName: "a" }, false],
      ["nonce array", { taskId: "t", nonce: [], actionName: "a" }, false],
      ["actionName object", { taskId: "t", nonce: "n", actionName: {} }, false],
      ["minimal valid", { taskId: "t", nonce: "n", actionName: "a" }, true],
      ["data non-object", { ...baseReply(), data: "oops" }, true],
      ["source non-string", { ...baseReply(), source: 5 }, true],
      ["timestamp non-string", { ...baseReply(), timestamp: 5 }, true],
      ["extra fields", { ...baseReply(), junk: 1 }, true],
    ];
    for (const [label, body, ok] of cases) {
      const result = replyResult(body, label);
      expect(result.ok, label).toBe(ok);
      if (result.ok) assertReplyShape(result.value, label);
      else expect(typeof result.error, label).toBe("string");
    }
  });

  it("fills defaults and keeps a valid data payload", () => {
    const minimal = replyResult(
      { taskId: "t", nonce: "n", actionName: "approve" },
      "minimal",
    );
    expect(minimal.ok).toBe(true);
    if (!minimal.ok) return;
    expect(minimal.value.source).toBe("unknown");
    expect(minimal.value.timestamp).toBeTruthy();

    const withData = replyResult(baseReply(), "with-data");
    expect(withData.ok).toBe(true);
    if (withData.ok) {
      expect(withData.value.data).toEqual({ decision: "ACCEPT" });
    }
  });

  it("tolerates 1 MiB / unicode strings", () => {
    const jumbo = "x".repeat(1024 * 1024);
    const bodies: [string, unknown][] = [
      ["taskId jumbo", { ...baseReply(), taskId: jumbo }],
      ["actionName unicode", { ...baseReply(), actionName: "🛑\u202E" }],
      ["source jumbo", { ...baseReply(), source: jumbo }],
    ];
    for (const [label, body] of bodies) {
      const result = replyResult(body, label);
      expect(result.ok, label).toBe(true);
      if (result.ok) assertReplyShape(result.value, label);
    }
  });

  it("validates server-side snooze replies (I-903)", () => {
    const inOneHour = new Date(Date.now() + 3_600_000).toISOString();
    const plusEightDays = new Date(
      Date.now() + 8 * 24 * 3_600_000,
    ).toISOString();
    const cases: [string, unknown, boolean][] = [
      [
        "snooze valid",
        { taskId: "t", nonce: "n", action: "snooze", until: inOneHour },
        true,
      ],
      [
        "snooze defaults actionName",
        { taskId: "t", nonce: "n", action: "snooze", until: inOneHour },
        true,
      ],
      [
        "snooze missing until",
        { taskId: "t", nonce: "n", action: "snooze" },
        false,
      ],
      [
        "snooze bad until",
        { taskId: "t", nonce: "n", action: "snooze", until: "not-a-date" },
        false,
      ],
      [
        "snooze until number",
        { taskId: "t", nonce: "n", action: "snooze", until: 12345 },
        false,
      ],
      [
        "snooze too far out",
        { taskId: "t", nonce: "n", action: "snooze", until: plusEightDays },
        false,
      ],
      [
        "action not snooze",
        { taskId: "t", nonce: "n", action: "approve", actionName: "approve" },
        false,
      ],
      [
        "action number",
        { taskId: "t", nonce: "n", action: 5, actionName: "approve" },
        false,
      ],
    ];
    for (const [label, body, ok] of cases) {
      const result = replyResult(body, label);
      expect(result.ok, label).toBe(ok);
      if (result.ok) assertReplyShape(result.value, label);
      else expect(typeof result.error, label).toBe("string");
    }
    const snoozed = replyResult(
      { taskId: "t", nonce: "n", action: "snooze", until: inOneHour },
      "snooze-defaults",
    );
    expect(snoozed.ok).toBe(true);
    if (snoozed.ok) {
      expect(snoozed.value.action).toBe("snooze");
      expect(snoozed.value.actionName).toBe("snooze");
      expect(snoozed.value.source).toBe("snooze");
    }
  });

  it("never throws for random shapes or mutations", () => {
    const rnd = mulberry32(SEED);
    for (let i = 0; i < 400; i++) {
      const label = `seed=${SEED} randomReply i=${i}`;
      const result = replyResult(randomJson(rnd, 1 + randInt(rnd, 4)), label);
      expect(typeof result.ok, label).toBe("boolean");
      if (result.ok) assertReplyShape(result.value, label);
      else expect(typeof result.error, label).toBe("string");
    }
    for (let i = 0; i < 400; i++) {
      const body = JSON.parse(JSON.stringify(baseReply())) as Record<
        string,
        unknown
      >;
      const keys = Object.keys(body);
      const mode = randInt(rnd, 4);
      if (mode === 0) {
        body.action = pick(rnd, ["approve", "explode", "SNOOZE", 5, {}]);
      } else if (mode === 1) {
        body.action = "snooze";
        body.until = pick(rnd, [
          "not-a-date",
          5,
          null,
          new Date(Date.now() + 10 * 24 * 3_600_000).toISOString(),
        ]);
      } else {
        body[pick(rnd, keys)] = pick(rnd, WRONG_TYPES.concat([1e21, "🛑"]));
      }
      if (rnd() < 0.3) delete body[pick(rnd, keys)];
      const label = `seed=${SEED} replyMutation i=${i} ${JSON.stringify(body).slice(0, 160)}`;
      const result = replyResult(body, label);
      expect(typeof result.ok, label).toBe("boolean");
      if (result.ok) assertReplyShape(result.value, label);
      else expect(typeof result.error, label).toBe("string");
    }
  });
});

// ---------------------------------------------------------------------------
// decideAction / decideUndo
// ---------------------------------------------------------------------------

const STATUSES: readonly TaskStatus[] = ["pending", "committing", "processed"];
// Values outside the union on purpose: runtime status is data, not a type.
const GARBAGE_STATUSES = ["weird", "", "PENDING", "pending ", "⏳"];

function expectedAction(
  stored: StoredTask | undefined,
  nonce: string,
): ActionDecision {
  if (!stored) return { kind: "not_found" };
  if (stored.nonce !== nonce) return { kind: "bad_nonce" };
  if (stored.status !== "pending") {
    return { kind: "conflict", reason: "already_processed" };
  }
  return { kind: "apply" };
}

function expectedUndo(
  stored: StoredTask | undefined,
  nonce: string,
): UndoDecision {
  if (!stored) return { kind: "not_found" };
  if (stored.nonce !== nonce) return { kind: "bad_nonce" };
  if (stored.status !== "committing") {
    return { kind: "conflict", reason: "too_late" };
  }
  return { kind: "undo" };
}

describe("fuzz: decideAction / decideUndo", () => {
  it("never throws and returns the documented decision for random status/nonce", () => {
    const rnd = mulberry32(SEED);
    for (let i = 0; i < 2000; i++) {
      const storedNonce = `tok_${randInt(rnd, 4)}`;
      const status =
        rnd() < 0.75
          ? pick(rnd, STATUSES)
          : (pick(rnd, GARBAGE_STATUSES) as TaskStatus);
      const stored: StoredTask | undefined =
        rnd() < 0.9
          ? {
              task: cardFixture(storedNonce),
              status,
              nonce: storedNonce,
              createdAt: 1,
            }
          : undefined;
      const replyNonce = rnd() < 0.5 ? storedNonce : `tok_${randInt(rnd, 4)}`;
      const reply: ActionReply = {
        taskId: "task_1",
        nonce: replyNonce,
        actionName: pick(rnd, ["approve", "reject", "snooze", ""]),
        timestamp: "2026-10-05T00:00:00.000Z",
        source: "swipe_gesture",
      };
      const label =
        `seed=${SEED} i=${i} status=${status} stored=${stored ? "yes" : "no"} ` +
        `storedNonce=${storedNonce} replyNonce=${replyNonce}`;

      let decision: ActionDecision | undefined;
      let threw: unknown = null;
      try {
        decision = decideAction(stored, reply);
      } catch (error) {
        threw = error;
      }
      expect(threw, `${label}: decideAction threw`).toBeNull();
      expect(decision, label).toEqual(expectedAction(stored, replyNonce));

      let undo: UndoDecision | undefined;
      let undoThrew: unknown = null;
      try {
        undo = decideUndo(stored, { taskId: "task_1", nonce: replyNonce });
      } catch (error) {
        undoThrew = error;
      }
      expect(undoThrew, `${label}: decideUndo threw`).toBeNull();
      expect(undo, label).toEqual(expectedUndo(stored, replyNonce));
    }
  });

  it("only applies on pending + matching nonce (spot checks)", () => {
    const stored: StoredTask = {
      task: cardFixture("tok_a"),
      status: "pending",
      nonce: "tok_a",
      createdAt: 1,
    };
    const reply = (nonce: string): ActionReply => ({
      taskId: "task_1",
      nonce,
      actionName: "approve",
      timestamp: "2026-10-05T00:00:00.000Z",
      source: "swipe_gesture",
    });
    expect(decideAction(undefined, reply("tok_a"))).toEqual({
      kind: "not_found",
    });
    expect(decideAction(stored, reply("tok_b"))).toEqual({ kind: "bad_nonce" });
    expect(decideAction(stored, reply("tok_a"))).toEqual({ kind: "apply" });
    expect(
      decideAction({ ...stored, status: "committing" }, reply("tok_a")),
    ).toEqual({ kind: "conflict", reason: "already_processed" });
    expect(
      decideAction({ ...stored, status: "processed" }, reply("tok_a")),
    ).toEqual({ kind: "conflict", reason: "already_processed" });
    expect(decideUndo(stored, { taskId: "task_1", nonce: "tok_a" })).toEqual({
      kind: "conflict",
      reason: "too_late",
    });
  });
});
