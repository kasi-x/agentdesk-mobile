import { describe, expect, it } from "vitest";
import {
  decideAction,
  ruleMatches,
  Rule,
  StoredTask,
  TaskCardPayload,
  validateActionReply,
  validateBulkRequest,
  validatePairRequest,
  validateRedeemRequest,
  validateRules,
  validateTaskCard,
} from "./protocol";

function card(overrides: Record<string, unknown> = {}): TaskCardPayload {
  const result = validateTaskCard({
    type: "createTaskCard",
    agent: { name: "Calendar Agent" },
    summary: "s",
    components: [],
    ...overrides,
  });
  if (!result.ok) throw new Error(`fixture invalid: ${result.error}`);
  return result.value;
}

function stored(
  task: TaskCardPayload,
  overrides: Partial<StoredTask> = {},
): StoredTask {
  return { task, status: "pending", nonce: task.nonce, createdAt: 1, ...overrides };
}

const FUTURE = "2999-01-01T00:00:00Z";
const PAST = "2026-01-01T00:00:00Z";

describe("requiredApprovals + choices + onSwipeDown + delegatedTo (I-111/I-501/I-502)", () => {
  it("passes requiredApprovals through and rejects non-integers below 1", () => {
    const two = validateTaskCard({
      type: "createTaskCard",
      agent: { name: "A" },
      summary: "s",
      components: [],
      requiredApprovals: 2,
    });
    expect(two.ok).toBe(true);
    if (!two.ok) return;
    expect(two.value.requiredApprovals).toBe(2);

    expect(
      validateTaskCard({
        type: "createTaskCard",
        agent: { name: "A" },
        summary: "s",
        components: [],
        requiredApprovals: 0,
      }).ok,
    ).toBe(false);
    expect(
      validateTaskCard({
        type: "createTaskCard",
        agent: { name: "A" },
        summary: "s",
        components: [],
        requiredApprovals: 1.5,
      }).ok,
    ).toBe(false);
    expect(
      validateTaskCard({
        type: "createTaskCard",
        agent: { name: "A" },
        summary: "s",
        components: [],
        requiredApprovals: "2",
      }).ok,
    ).toBe(false);
  });

  it("requires >= 2 choices and both up/down bindings for decisionKind choose", () => {
    const bindings = {
      onSwipeUp: { actionName: "pick_first" },
      onSwipeDown: { actionName: "pick_second" },
    };
    const choices = [
      { id: "a", label: "A" },
      { id: "b", label: "B" },
    ];
    const ok = validateTaskCard({
      type: "createTaskCard",
      agent: { name: "A" },
      summary: "s",
      components: [],
      decisionKind: "choose",
      choices,
      actions: bindings,
    });
    expect(ok.ok).toBe(true);
    if (!ok.ok) return;
    expect(ok.value.choices).toEqual(choices);
    expect(ok.value.actions.onSwipeDown?.actionName).toBe("pick_second");

    const oneChoice = {
      type: "createTaskCard",
      agent: { name: "A" },
      summary: "s",
      components: [],
      decisionKind: "choose",
      choices: [{ id: "a", label: "A" }],
      actions: bindings,
    };
    expect(validateTaskCard(oneChoice).ok).toBe(false);
    expect(
      validateTaskCard({
        ...oneChoice,
        choices,
        actions: { onSwipeUp: { actionName: "pick_first" } },
      }).ok,
    ).toBe(false);
    expect(validateTaskCard({ ...oneChoice, choices: undefined }).ok).toBe(
      false,
    );
    expect(
      validateTaskCard({
        ...oneChoice,
        choices: [{ id: "a" }],
      }).ok,
    ).toBe(false);
  });

  it("round-trips delegatedTo for hub-set cards", () => {
    const result = validateTaskCard({
      type: "createTaskCard",
      agent: { name: "A" },
      summary: "s",
      components: [],
      delegatedTo: "alice",
    });
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.delegatedTo).toBe("alice");
    expect(
      validateTaskCard({
        type: "createTaskCard",
        agent: { name: "A" },
        summary: "s",
        components: [],
        delegatedTo: "",
      }).ok,
    ).toBe(false);
  });
});

describe("decideAction: delegate + approve_partial (I-501/I-502)", () => {
  it("delegates a pending card without deciding it", () => {
    const task = card();
    expect(
      decideAction(stored(task), {
        taskId: "t",
        nonce: task.nonce,
        actionName: "delegate",
        timestamp: "2026-10-05T00:00:00Z",
        source: "web_ui",
        action: "delegate",
        data: { to: "alice" },
      }),
    ).toEqual({ kind: "delegate" });
  });

  it("records a partial approval until the Nth arrives", () => {
    const task = card({ requiredApprovals: 2 });
    const reply = {
      taskId: "t",
      nonce: task.nonce,
      actionName: "approve",
      timestamp: "2026-10-05T00:00:00Z",
      source: "web_ui",
    };
    expect(decideAction(stored(task), reply)).toEqual({
      kind: "approve_partial",
    });
    const oneDown = stored(task, {
      approvals: [{ source: "web_ui", at: "2026-10-05T00:00:00Z" }],
    });
    expect(decideAction(oneDown, reply)).toEqual({ kind: "apply" });
  });

  it("does not partially approve rejects or single-approval cards", () => {
    const task = card({ requiredApprovals: 2 });
    const reject = {
      taskId: "t",
      nonce: task.nonce,
      actionName: "reject",
      timestamp: "2026-10-05T00:00:00Z",
      source: "web_ui",
    };
    expect(decideAction(stored(task), reject)).toEqual({ kind: "apply" });
    const single = card();
    expect(
      decideAction(stored(single), {
        ...reject,
        actionName: "approve",
        nonce: single.nonce,
      }),
    ).toEqual({ kind: "apply" });
  });
});

describe("delegate reply + bulk delegate (I-501)", () => {
  it("normalizes a delegate reply and requires data.to", () => {
    const ok = validateActionReply({
      taskId: "t",
      nonce: "n",
      action: "delegate",
      data: { to: "alice" },
    });
    expect(ok.ok).toBe(true);
    if (!ok.ok) return;
    expect(ok.value.action).toBe("delegate");
    expect(ok.value.actionName).toBe("delegate");
    expect(ok.value.source).toBe("delegate");

    expect(
      validateActionReply({ taskId: "t", nonce: "n", action: "delegate" }).ok,
    ).toBe(false);
    expect(
      validateActionReply({
        taskId: "t",
        nonce: "n",
        action: "delegate",
        data: { to: "" },
      }).ok,
    ).toBe(false);
  });

  it("accepts a delegate item in bulk and rejects one without data.to", () => {
    const ok = validateBulkRequest({
      actions: [{ taskId: "a", nonce: "n", action: "delegate", data: { to: "x" } }],
    });
    expect(ok.ok).toBe(true);
    if (!ok.ok) return;
    expect(ok.value.actions[0].action).toBe("delegate");
    expect(ok.value.actions[0].actionName).toBe("delegate");
    expect(
      validateBulkRequest({
        actions: [{ taskId: "a", nonce: "n", action: "delegate" }],
      }).ok,
    ).toBe(false);
  });
});

describe("rules + lease matching (I-304/I-602/I-807)", () => {
  const rule: Rule = {
    id: "cheap-calendar",
    match: { agent: "Calendar", severity: ["info", "warning"], maxCost: 50 },
    lease: { until: FUTURE, maxCount: 3 },
    enabled: true,
  };

  it("validates rule envelopes strictly", () => {
    expect(validateRules({ rules: [rule] })).toEqual({
      ok: true,
      value: [rule],
    });
    // enabled defaults to true
    const implicit = validateRules({
      rules: [{ id: "r", match: {} }],
    });
    expect(implicit.ok).toBe(true);
    if (!implicit.ok) return;
    expect(implicit.value[0].enabled).toBe(true);

    expect(validateRules({ rules: [{ match: {} }] }).ok).toBe(false);
    expect(validateRules({ rules: "nope" }).ok).toBe(false);
    expect(
      validateRules({ rules: [{ id: "r", match: { severity: "info" } }] }).ok,
    ).toBe(false);
    expect(
      validateRules({ rules: [{ id: "r", match: { maxCost: "cheap" } }] }).ok,
    ).toBe(false);
    expect(
      validateRules({
        rules: [{ id: "r", match: {}, lease: { maxCount: 0 } }],
      }).ok,
    ).toBe(false);
    expect(
      validateRules({
        rules: [{ id: "r", match: {}, lease: { until: "soon" } }],
      }).ok,
    ).toBe(false);
    expect(
      validateRules({ rules: [{ id: "r", match: {}, enabled: "yes" }] }).ok,
    ).toBe(false);
  });

  it("ANDs every match constraint", () => {
    const now = Date.now();
    expect(ruleMatches(rule, card(), now)).toBe(true);
    expect(
      ruleMatches(rule, card({ agent: { name: "Billing Agent" } }), now),
    ).toBe(false);
    expect(ruleMatches(rule, card({ severity: "critical" }), now)).toBe(false);
    expect(
      ruleMatches(
        rule,
        card({ impact: { cost: { amount: 51, currency: "USD" } } }),
        now,
      ),
    ).toBe(false);
    // cost exactly at the cap still matches
    expect(
      ruleMatches(
        rule,
        card({ impact: { cost: { amount: 50, currency: "USD" } } }),
        now,
      ),
    ).toBe(true);
  });

  it("disables on switch-off, expiry, and group mismatch", () => {
    const now = Date.now();
    expect(ruleMatches({ ...rule, enabled: false }, card(), now)).toBe(false);
    expect(
      ruleMatches({ ...rule, lease: { ...rule.lease, until: PAST } }, card(), now),
    ).toBe(false);
    expect(
      ruleMatches(
        { ...rule, match: { agent: "Calendar", groupKey: "zzz" } },
        card({ groupKey: "inbox" }),
        now,
      ),
    ).toBe(false);
    // empty match = match all
    expect(
      ruleMatches({ id: "x", match: {}, enabled: true }, card(), now),
    ).toBe(true);
  });
});

describe("pairing (I-808)", () => {
  it("accepts empty and partial pair requests", () => {
    expect(validatePairRequest(undefined)).toEqual({ ok: true, value: {} });
    expect(validatePairRequest({ device: "phone", user: "u" })).toEqual({
      ok: true,
      value: { device: "phone", user: "u" },
    });
    expect(validatePairRequest({ device: "" }).ok).toBe(false);
    expect(validatePairRequest("nope").ok).toBe(false);
  });

  it("requires a code to redeem", () => {
    expect(validateRedeemRequest({ code: "ABC123" })).toEqual({
      ok: true,
      value: { code: "ABC123" },
    });
    expect(validateRedeemRequest({}).ok).toBe(false);
    expect(validateRedeemRequest({ code: "" }).ok).toBe(false);
  });
});
