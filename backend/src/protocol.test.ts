import { describe, expect, it } from "vitest";
import {
  decideAction,
  StoredTask,
  validateActionReply,
  validateTaskCard,
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
