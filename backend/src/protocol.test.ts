import { describe, expect, it } from "vitest";
import {
  decideAction,
  decideUndo,
  expiryDue,
  StoredTask,
  validateActionReply,
  validateTaskCard,
  validateUndoRequest,
} from "./protocol";

const baseCard = {
  type: "createTaskCard",
  agent: { name: "Calendar & Meeting Agent" },
  confidence: 0.94,
  summary: "ミーティングの日程変更リクエスト",
  components: [
    {
      id: "root_card",
      component: "TriageCard",
      children: ["diff_view", "reasoning_text"],
    },
    {
      id: "diff_view",
      component: "DiffBox",
      properties: {
        title: "定例ミーティング時間",
        before: "2026-10-05 14:00",
        after: "2026-10-05 16:30",
        highlight: "warning",
      },
    },
    {
      id: "reasoning_text",
      component: "Text",
      properties: { text: "参加者3名中2名が14:00に重複予定…", variant: "caption" },
    },
  ],
  actions: {
    onSwipeRight: { actionName: "approve", payload: { decision: "ACCEPT" } },
    onSwipeLeft: { actionName: "reject", payload: { decision: "DECLINE" } },
    inspectForm: [
      {
        id: "time_picker",
        component: "TimePicker",
        properties: { label: "別の時間を指定", default: "16:30" },
      },
    ],
  },
};

function storedFixture(
  overrides: Partial<StoredTask> = {},
): StoredTask {
  const card = validateTaskCard(baseCard);
  if (!card.ok) throw new Error("fixture invalid");
  return {
    task: card.value,
    status: "pending",
    nonce: "tok_1",
    createdAt: 1,
    ...overrides,
  };
}

describe("validateTaskCard", () => {
  it("accepts the reference payload and fills hub-managed fields", () => {
    const result = validateTaskCard(baseCard);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.taskId).toMatch(/^task_/);
    expect(result.value.nonce).toMatch(/^tok_/);
    expect(result.value.createdAt).toBeTruthy();
    expect(result.value.actions.onSwipeRight?.actionName).toBe("approve");
    expect(result.value.actions.inspectForm?.[0]?.component).toBe("TimePicker");
  });

  it("keeps agent-supplied identity (taskId/nonce) intact", () => {
    const result = validateTaskCard({
      ...baseCard,
      taskId: "task_98234",
      nonce: "tok_sec_abc123",
    });
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.taskId).toBe("task_98234");
    expect(result.value.nonce).toBe("tok_sec_abc123");
  });

  it("passes unknown component types through for client-side fallback (FR-1.3)", () => {
    const result = validateTaskCard({
      ...baseCard,
      components: [
        ...baseCard.components,
        { id: "x", component: "BrandNewWidget", properties: { whatever: 1 } },
      ],
    });
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(
      result.value.components.some((c) => c.component === "BrandNewWidget"),
    ).toBe(true);
  });

  it("rejects malformed payloads", () => {
    expect(validateTaskCard("nope").ok).toBe(false);
    expect(validateTaskCard({ ...baseCard, summary: "" }).ok).toBe(false);
    expect(validateTaskCard({ ...baseCard, agent: { name: "" } }).ok).toBe(false);
    expect(validateTaskCard({ ...baseCard, confidence: 1.5 }).ok).toBe(false);
    expect(
      validateTaskCard({ ...baseCard, replyUrl: "javascript:alert(1)" }).ok,
    ).toBe(false);
    expect(
      validateTaskCard({ ...baseCard, components: "not-an-array" }).ok,
    ).toBe(false);
  });

  it("passes valid rejectReasons through and drops malformed entries (I-118)", () => {
    const withReasons = validateTaskCard({
      ...baseCard,
      actions: {
        ...baseCard.actions,
        rejectReasons: [
          { id: "time_conflict", label: "時間が合わない" },
          { id: "bad" }, // dropped: label missing
          "nope", // dropped: not an object
        ],
      },
    });
    expect(withReasons.ok).toBe(true);
    if (!withReasons.ok) return;
    expect(withReasons.value.actions.rejectReasons).toEqual([
      { id: "time_conflict", label: "時間が合わない" },
    ]);
    expect(
      validateTaskCard({
        ...baseCard,
        actions: { ...baseCard.actions, rejectReasons: "oops" },
      }).ok,
    ).toBe(false);
  });
});

describe("validateActionReply", () => {
  it("fills timestamp and source defaults", () => {
    const result = validateActionReply({
      taskId: "t",
      nonce: "n",
      actionName: "approve",
    });
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.source).toBe("unknown");
    expect(result.value.timestamp).toBeTruthy();
  });

  it("keeps data payloads intact", () => {
    const result = validateActionReply({
      taskId: "t",
      nonce: "n",
      actionName: "approve",
      source: "inspect_form",
      data: { decision: "ACCEPT", newTime: "16:30" },
    });
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.data).toEqual({
      decision: "ACCEPT",
      newTime: "16:30",
    });
  });

  it("rejects missing required fields", () => {
    expect(validateActionReply({ nonce: "n", actionName: "a" }).ok).toBe(false);
    expect(validateActionReply({ taskId: "t", actionName: "a" }).ok).toBe(false);
    expect(validateActionReply({ taskId: "t", nonce: "n" }).ok).toBe(false);
    expect(validateActionReply(null).ok).toBe(false);
  });
});

describe("decideAction (nonce CAS, FR-3.1/FR-3.3)", () => {
  it("applies a first action on a pending task with a matching nonce", () => {
    expect(
      decideAction(storedFixture(), {
        taskId: "task_x",
        nonce: "tok_1",
        actionName: "approve",
        timestamp: "2026-10-04T00:00:00Z",
        source: "swipe_gesture",
      }),
    ).toEqual({ kind: "apply" });
  });

  it("rejects a replayed action as already_processed", () => {
    const processed = storedFixture({ status: "processed", processedAt: 2 });
    expect(
      decideAction(processed, {
        taskId: "task_x",
        nonce: "tok_1",
        actionName: "approve",
        timestamp: "2026-10-04T00:00:00Z",
        source: "web_ui",
      }),
    ).toEqual({ kind: "conflict", reason: "already_processed" });
  });

  it("rejects a stale nonce (bad_nonce)", () => {
    expect(
      decideAction(storedFixture(), {
        taskId: "task_x",
        nonce: "tok_other",
        actionName: "approve",
        timestamp: "2026-10-04T00:00:00Z",
        source: "swipe_gesture",
      }),
    ).toEqual({ kind: "bad_nonce" });
  });

  it("reports not_found for unknown tasks", () => {
    expect(
      decideAction(undefined, {
        taskId: "task_missing",
        nonce: "tok_1",
        actionName: "approve",
        timestamp: "2026-10-04T00:00:00Z",
        source: "swipe_gesture",
      }),
    ).toEqual({ kind: "not_found" });
  });
});

describe("decideUndo (I-104 grace window)", () => {
  const committing = () =>
    storedFixture({
      status: "committing",
      commitAt: Date.now() + 5000,
      pendingReply: {
        taskId: "task_x",
        nonce: "tok_1",
        actionName: "approve",
        timestamp: "2026-10-04T00:00:00Z",
        source: "swipe_gesture",
      },
    });

  it("reverts a committing task", () => {
    expect(
      decideUndo(committing(), { taskId: "task_x", nonce: "tok_1" }),
    ).toEqual({ kind: "undo" });
  });

  it("answers too_late once processed", () => {
    const processed = storedFixture({ status: "processed", processedAt: 2 });
    expect(
      decideUndo(processed, { taskId: "task_x", nonce: "tok_1" }),
    ).toEqual({ kind: "conflict", reason: "too_late" });
  });

  it("answers too_late on a still-pending task (nothing to undo)", () => {
    expect(
      decideUndo(storedFixture(), { taskId: "task_x", nonce: "tok_1" }),
    ).toEqual({ kind: "conflict", reason: "too_late" });
  });

  it("rejects a stale nonce before checking status", () => {
    expect(
      decideUndo(committing(), { taskId: "task_x", nonce: "tok_other" }),
    ).toEqual({ kind: "bad_nonce" });
  });

  it("double undo: second call sees pending and gets too_late", () => {
    // The hub rotates the nonce and flips to pending after the first undo,
    // so a replayed request hits the same too_late path as never-committed.
    const reverted = storedFixture(); // pending with a fresh nonce
    expect(
      decideUndo(reverted, { taskId: "task_x", nonce: "tok_1" }),
    ).toEqual({ kind: "conflict", reason: "too_late" });
  });

  it("reports not_found for unknown tasks", () => {
    expect(decideUndo(undefined, { taskId: "task_x", nonce: "tok_1" })).toEqual({
      kind: "not_found",
    });
  });
});

describe("validateUndoRequest", () => {
  it("accepts taskId + nonce", () => {
    expect(validateUndoRequest({ taskId: "t", nonce: "n" })).toEqual({
      ok: true,
      value: { taskId: "t", nonce: "n" },
    });
  });

  it("rejects missing fields and non-objects", () => {
    expect(validateUndoRequest({ nonce: "n" }).ok).toBe(false);
    expect(validateUndoRequest({ taskId: "t" }).ok).toBe(false);
    expect(validateUndoRequest(null).ok).toBe(false);
  });
});

describe("decideAction under committing (I-104)", () => {
  it("a second action during the grace window is already_processed", () => {
    const committing = storedFixture({
      status: "committing",
      commitAt: Date.now() + 5000,
    });
    expect(
      decideAction(committing, {
        taskId: "task_x",
        nonce: "tok_1",
        actionName: "reject",
        timestamp: "2026-10-04T00:00:00Z",
        source: "web_ui",
      }),
    ).toEqual({ kind: "conflict", reason: "already_processed" });
  });
});

describe("context block (裏面)", () => {
  it("keeps a well-formed context", () => {
    const result = validateTaskCard({
      ...baseCard,
      context: {
        requester: { name: "Bさん", onBehalfOf: "リード" },
        participants: [{ name: "Aさん", status: "busy" }, { name: "自分", status: "free" }],
        reasoning: "重複のため",
        source: { label: "Gmail", url: "https://mail.example.com/1" },
      },
    });
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.context?.requester?.name).toBe("Bさん");
    expect(result.value.context?.participants).toHaveLength(2);
    expect(result.value.context?.reasoning).toBe("重複のため");
    expect(result.value.context?.source?.url).toBe("https://mail.example.com/1");
  });

  it("drops malformed pieces instead of rejecting (advisory data)", () => {
    const result = validateTaskCard({
      ...baseCard,
      context: {
        requester: { name: "" },
        participants: [{ name: "x" }, "junk", { nope: 1 }],
        reasoning: "",
        source: { label: "L", url: "javascript:alert(1)" },
      },
    });
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.context?.requester).toBeUndefined();
    expect(result.value.context?.participants).toHaveLength(1);
    expect(result.value.context?.source?.url).toBeUndefined();
    expect(result.value.context?.source?.label).toBe("L");
  });

  it("omits context entirely when nothing survives", () => {
    const result = validateTaskCard({ ...baseCard, context: { reasoning: "" } });
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.context).toBeUndefined();
  });
});

describe("expiry policy (I-203)", () => {
  const past = "2026-01-01T00:00:00Z";
  const future = "2999-01-01T00:00:00Z";

  function cardFixture(
    overrides: Record<string, unknown>,
  ): StoredTask {
    const card = validateTaskCard({ ...baseCard, ...overrides });
    if (!card.ok) throw new Error(`fixture invalid: ${card.error}`);
    return storedFixture({ task: card.value });
  }

  it("validates expiresAt / onExpire strictly", () => {
    expect(validateTaskCard({ ...baseCard, expiresAt: past }).ok).toBe(true);
    expect(validateTaskCard({ ...baseCard, expiresAt: "not-a-date" }).ok).toBe(
      false,
    );
    expect(validateTaskCard({ ...baseCard, onExpire: "approve" }).ok).toBe(
      false,
    );
    expect(
      validateTaskCard({ ...baseCard, expiresAt: past, onExpire: "nope" }).ok,
    ).toBe(false);
  });

  it("fires approve with the declared swipe binding once past due", () => {
    expect(
      expiryDue(cardFixture({ expiresAt: past, onExpire: "approve" }), Date.now()),
    ).toEqual({
      action: "approve",
      binding: { actionName: "approve", payload: { decision: "ACCEPT" } },
    });
  });

  it("does not fire before the deadline", () => {
    expect(expiryDue(cardFixture({ expiresAt: future }), Date.now())).toBeNull();
  });

  it("defaults to drop, and never fires for non-pending or escalated tasks", () => {
    expect(expiryDue(cardFixture({ expiresAt: past }), Date.now())).toEqual({
      action: "drop",
    });
    const pastCard = validateTaskCard({ ...baseCard, expiresAt: past });
    if (!pastCard.ok) throw new Error("fixture invalid");
    expect(
      expiryDue(
        storedFixture({ task: pastCard.value, status: "processed" }),
        Date.now(),
      ),
    ).toBeNull();
    expect(
      expiryDue(
        storedFixture({ task: pastCard.value, status: "committing" }),
        Date.now(),
      ),
    ).toBeNull();
    expect(
      expiryDue(storedFixture({ task: pastCard.value, escalatedAt: 1 }), Date.now()),
    ).toBeNull();
  });

  it("degrades approve/reject without the matching binding to drop", () => {
    expect(
      expiryDue(
        cardFixture({
          expiresAt: past,
          onExpire: "reject",
          actions: { ...baseCard.actions, onSwipeLeft: undefined },
        }),
        Date.now(),
      ),
    ).toEqual({ action: "drop" });
  });
});
