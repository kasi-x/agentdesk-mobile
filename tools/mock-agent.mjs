#!/usr/bin/env node
// Dependency-free mock agent for local E2E (Phase 1 verification:
// "swipe decisions reach the agent callback URL").
//
//   node tools/mock-agent.mjs listen [--port 8799]
//   node tools/mock-agent.mjs send   [--port 8799]
//
// Env: HUB_URL (default http://127.0.0.1:8787), AGENT_TOKEN (default
// dev-agent-token), CALLBACK_PORT (default 8799).

import crypto from "node:crypto";
import http from "node:http";

const HUB_URL = process.env.HUB_URL ?? "http://127.0.0.1:8787";
const AGENT_TOKEN = process.env.AGENT_TOKEN ?? "dev-agent-token";
const CALLBACK_PORT = Number(process.env.CALLBACK_PORT ?? 8799);

const argPort = (flag, fallback) => {
  const i = process.argv.indexOf(flag);
  return i !== -1 && process.argv[i + 1] ? Number(process.argv[i + 1]) : fallback;
};

const shortId = () => `task_${crypto.randomUUID().slice(0, 8)}`;

function sampleCards(callbackBase) {
  return [
    {
      type: "createTaskCard",
      taskId: shortId(),
      agent: { name: "Calendar & Meeting Agent" },
      confidence: 0.94,
      severity: "info",
      summary: "ミーティングの日程変更リクエスト",
      replyUrl: `${callbackBase}/callback/calendar`,
      components: [
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
          properties: {
            text: "参加者3名中2名が14:00に重複予定があるため、全員が空いている16:30への変更を提案します。",
            variant: "caption",
          },
        },
      ],
      actions: {
        onSwipeRight: {
          actionName: "approve",
          label: "日程を変更する",
          payload: { decision: "ACCEPT", newTime: "2026-10-05 16:30" },
        },
        onSwipeLeft: { actionName: "reject", payload: { decision: "DECLINE" } },
        inspectForm: [
          {
            id: "time_picker",
            component: "TimePicker",
            properties: { label: "別の時間を指定", default: "16:30" },
          },
        ],
      },
    },
    {
      type: "createTaskCard",
      taskId: shortId(),
      agent: { name: "Billing Agent" },
      confidence: 0.62,
      severity: "warning",
      confidenceReasons: ["返金額が$100超", "対象ユーザーの異議申立履歴あり"],
      summary: "Stripe返金の承認依頼",
      impact: {
        summary: "UserA に $120.00 を返金します",
        reversible: false,
        cost: { amount: 120, currency: "USD" },
        scope: "Stripe",
      },
      replyUrl: `${callbackBase}/callback/billing`,
      components: [
        {
          id: "diff_view",
          component: "DiffBox",
          properties: {
            title: "Stripe返金",
            before: "$120.00 請求済み",
            after: "$120.00 返金 → 対象: UserA",
            highlight: "critical",
          },
        },
        {
          id: "source_quote",
          component: "Text",
          properties: {
            text: "（外部メール引用）商品が届かないため全額返金を要求します…",
            source: "external",
          },
        },
      ],
      actions: {
        onSwipeRight: {
          actionName: "approve",
          label: "返金する $120",
          payload: { decision: "REFUND", amount: 120 },
        },
        onSwipeLeft: { actionName: "reject", payload: { decision: "DENY" } },
        inspectForm: [
          {
            id: "amount",
            component: "Slider",
            properties: { label: "返金額 ($)", min: 0, max: 120, default: 60, divisions: 12 },
          },
          {
            id: "note",
            component: "TextField",
            properties: { label: "対応メモ", multiline: true },
          },
        ],
      },
    },
    {
      type: "createTaskCard",
      taskId: shortId(),
      agent: { name: "Inbox Triage Agent" },
      confidence: 0.99,
      severity: "info",
      summary: "迷惑メール判定: 削除してよいか確認",
      replyUrl: `${callbackBase}/callback/inbox`,
      components: [
        {
          id: "mail_quote",
          component: "Text",
          properties: {
            text: "（メール本文）おめでとうございます！あなたは当選しました…",
            source: "external",
          },
        },
        {
          id: "quick_options",
          component: "Chips",
          properties: {
            options: [
              { label: "削除して報告", actionName: "delete_and_report" },
              { label: "受信箱に残す", actionName: "keep" },
              { label: "内容を詳しく見る" },
            ],
          },
        },
      ],
      actions: {
        onSwipeRight: { actionName: "delete_and_report", payload: { decision: "DELETE" } },
        onSwipeLeft: { actionName: "keep", payload: { decision: "KEEP" } },
      },
    },
  ];
}

async function send(port) {
  const callbackBase = `http://127.0.0.1:${port}`;
  const cards = sampleCards(callbackBase);
  for (const card of cards) {
    const res = await fetch(`${HUB_URL}/api/v1/tasks`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${AGENT_TOKEN}`,
      },
      body: JSON.stringify(card),
    });
    const body = await res.text();
    console.log(`${res.status}  ${card.taskId}  ${card.summary}${res.ok ? "" : ` — ${body}`}`);
  }
  console.log(
    `\n✅ ${cards.length} cards sent to ${HUB_URL}.\nStart 'node tools/mock-agent.mjs listen' and swipe them in the app — triage replies will be printed there.`,
  );
}

function listen(port) {
  const server = http.createServer((req, res) => {
    let raw = "";
    req.on("data", (chunk) => (raw += chunk));
    req.on("end", () => {
      console.log(`\n📥 ${req.method} ${req.url}`);
      try {
        console.log(JSON.stringify(JSON.parse(raw || "{}"), null, 2));
      } catch {
        console.log(raw);
      }
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ ok: true }));
    });
  });
  server.listen(port, "127.0.0.1", () => {
    console.log(
      `Mock agent listening on http://127.0.0.1:${port} — waiting for triage replies…`,
    );
  });
}

const [command] = process.argv.slice(2);
if (command === "listen") {
  listen(argPort("--port", CALLBACK_PORT));
} else if (command === "send") {
  await send(argPort("--port", CALLBACK_PORT));
} else {
  console.error("usage: node tools/mock-agent.mjs <send|listen> [--port 8799]");
  process.exit(1);
}
