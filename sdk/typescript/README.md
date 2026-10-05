# @agentdesk/sdk — TypeScript / JavaScript

Zero-dependency AgentDesk agent client. Node **>= 18** (uses global `fetch`),
ESM only, no build step.

```bash
# copy the folder into your project, or reference it by path
npm install ./sdk/typescript     # from the agentdesk-mobile repo
```

## Ask a human (blocking)

```js
import { createClient } from "@agentdesk/sdk";

const desk = createClient({
  hubUrl: process.env.HUB_URL,          // default http://127.0.0.1:8787
  agentToken: process.env.AGENT_TOKEN,  // required
});

const { actionName, data, source } = await desk.ask(
  {
    type: "createTaskCard",
    agent: { name: "Deploy Bot" },
    severity: "warning",
    summary: "Deploy release/1.4.0 to production?",
    replyUrl: "https://my-agent.example.com/callback",
    components: [
      {
        id: "diff",
        component: "DiffBox",
        properties: { title: "Version", before: "1.3.9", after: "1.4.0" },
      },
    ],
    actions: {
      onSwipeRight: {
        actionName: "approve",
        label: "Deploy",
        payload: { decision: "ACCEPT" },
      },
      onSwipeLeft: { actionName: "reject", label: "Hold", payload: { decision: "DECLINE" } },
    },
  },
  { timeout: 600_000 }, // ms; default 5 min, Infinity to wait forever
);

if (actionName === "approve") {
  await deploy(data);
}
```

`ask()` POSTs the card to `POST /api/v1/tasks`, then long-polls
`GET /api/v1/tasks/{taskId}/result?wait=60` until the task reaches a terminal
status (`approved`, `rejected`, `withdrawn`, `expired`) and resolves with
`{ taskId, status, actionName, data, source, action, delivery }`. On timeout it
throws `DeskTimeoutError` (the task keeps waiting in the hub — retry `result()`).

## Update / withdraw a pending card

```js
await desk.update("task_98234", { ...fullReplacementCard }); // rotates nonce, revised:true
await desk.withdraw("task_98234");                           // broadcasts withdrawTask
```

## Verify `replyUrl` callbacks (Express-free)

The hub POSTs the decision to your `replyUrl`, signed with
`X-AgentDesk-Signature: t=<ts>,v1=<hex-hmac-sha256 of "ts.body">` and
`X-AgentDesk-Event: triage_reply|expire`. The secret is
`REPLY_SIGNING_SECRET`, falling back to `AGENT_TOKEN`; the SDK reads
`AGENTDESK_SECRET` first.

```js
import http from "node:http";

const replies = desk.replyHandler(); // secret from AGENTDESK_SECRET → REPLY_SIGNING_SECRET → agentToken

http
  .createServer((req, res) => {
    let raw = "";
    req.on("data", (chunk) => (raw += chunk));
    req.on("end", () => {
      try {
        const { event, reply } = replies.handle(req.headers, raw); // throws DeskError on bad sig
        console.log(event, reply.actionName, reply.data);
        res.writeHead(200).end("ok");
      } catch {
        res.writeHead(401).end("bad signature");
      }
    });
  })
  .listen(8799);
```

Sign a body yourself (tests, replay tools):

```js
import { verifySignature, signBody, parseSignatureHeader } from "@agentdesk/sdk";

const header = signBody(secret, rawBody); // t=<ts>,v1=<hex>
verifySignature({ "x-agentdesk-signature": header }, rawBody, secret); // true
```

Pass the **raw** body (string or `Buffer`) — re-serializing JSON changes the
bytes and invalidates the signature. `handle()` also throws on non-JSON.
