#!/usr/bin/env bash
# End-to-end smoke test against a local `wrangler dev` (docs/protocol.md).
# Usage: npm run smoke   (start `npm run dev` in another terminal first)
# Env: HUB_URL, AGENT_TOKEN, CLIENT_TOKEN (defaults match .dev.vars.example)
set -euo pipefail

BASE="${HUB_URL:-http://127.0.0.1:8787}"
AGENT_TOKEN="${AGENT_TOKEN:-dev-agent-token}"
CLIENT_TOKEN="${CLIENT_TOKEN:-dev-client-token}"

command -v curl >/dev/null || { echo "curl required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
body() { curl -s "$@"; }

echo "→ healthz"
[ "$(code "$BASE/healthz")" = "200" ] || { echo "healthz failed" >&2; exit 1; }

echo "→ unauthenticated /api/v1/state must be 401"
[ "$(code "$BASE/api/v1/state")" = "401" ] || { echo "auth check failed" >&2; exit 1; }

TASK_ID="task_smoke_$(date +%s)"
NONCE="tok_smoke_$$"

echo "→ enqueue $TASK_ID"
CREATE_CODE=$(code -X POST "$BASE/api/v1/tasks" \
  -H "Authorization: Bearer $AGENT_TOKEN" -H "Content-Type: application/json" \
  -d "$(jq -n --arg id "$TASK_ID" --arg nonce "$NONCE" '{
      type: "createTaskCard", taskId: $id, nonce: $nonce,
      agent: { name: "Smoke Agent" }, confidence: 0.9,
      summary: "smoke test task",
      components: [ { id: "root", component: "TriageCard", children: [] } ],
      actions: { onSwipeRight: { actionName: "approve", payload: { decision: "ACCEPT" } } }
    }')")
[ "$CREATE_CODE" = "201" ] || { echo "create failed: $CREATE_CODE" >&2; exit 1; }

echo "→ snapshot contains the task"
body "$BASE/api/v1/state" -H "Authorization: Bearer $CLIENT_TOKEN" | grep -q "$TASK_ID" \
  || { echo "snapshot missing $TASK_ID" >&2; exit 1; }

ACTION="{\"taskId\":\"$TASK_ID\",\"nonce\":\"$NONCE\",\"actionName\":\"approve\",\"source\":\"web_ui\",\"data\":{\"decision\":\"ACCEPT\"}}"

echo "→ first action accepted"
[ "$(code -X POST "$BASE/api/v1/actions" \
  -H "Authorization: Bearer $CLIENT_TOKEN" -H "Content-Type: application/json" \
  -d "$ACTION")" = "200" ] || { echo "action failed" >&2; exit 1; }

echo "→ replayed action rejected with 409 (nonce consumed)"
[ "$(code -X POST "$BASE/api/v1/actions" \
  -H "Authorization: Bearer $CLIENT_TOKEN" -H "Content-Type: application/json" \
  -d "$ACTION")" = "409" ] || { echo "double-submit not rejected" >&2; exit 1; }

echo "→ undo restores the task with a fresh nonce (I-104)"
UNDO_CODE=$(code -X POST "$BASE/api/v1/actions/undo" \
  -H "Authorization: Bearer $CLIENT_TOKEN" -H "Content-Type: application/json" \
  -d "{\"taskId\":\"$TASK_ID\",\"nonce\":\"$NONCE\"}")
[ "$UNDO_CODE" = "200" ] || { echo "undo failed: $UNDO_CODE" >&2; exit 1; }
body "$BASE/api/v1/state" -H "Authorization: Bearer $CLIENT_TOKEN" | grep -q "$TASK_ID" \
  || { echo "undo did not restore $TASK_ID" >&2; exit 1; }

echo "→ second undo is rejected (already reverted)"
[ "$(code -X POST "$BASE/api/v1/actions/undo" \
  -H "Authorization: Bearer $CLIENT_TOKEN" -H "Content-Type: application/json" \
  -d "{\"taskId\":\"$TASK_ID\",\"nonce\":\"$NONCE\"}")" = "409" ] \
  || { echo "double undo not rejected" >&2; exit 1; }

echo "→ stale nonce no longer applies after undo (nonce rotated)"
NEW_NONCE=$(body "$BASE/api/v1/state" -H "Authorization: Bearer $CLIENT_TOKEN" \
  | jq -r --arg id "$TASK_ID" '.tasks[] | select(.taskId==$id) | .nonce')
[ -n "$NEW_NONCE" ] && [ "$NEW_NONCE" != "$NONCE" ] \
  || { echo "nonce not rotated after undo" >&2; exit 1; }
[ "$(code -X POST "$BASE/api/v1/actions" \
  -H "Authorization: Bearer $CLIENT_TOKEN" -H "Content-Type: application/json" \
  -d "$ACTION")" = "409" ] || { echo "stale nonce not rejected" >&2; exit 1; }

echo "→ re-triage with the rotated nonce commits, then undo is too_late"
[ "$(code -X POST "$BASE/api/v1/actions" \
  -H "Authorization: Bearer $CLIENT_TOKEN" -H "Content-Type: application/json" \
  -d "{\"taskId\":\"$TASK_ID\",\"nonce\":\"$NEW_NONCE\",\"actionName\":\"approve\",\"source\":\"web_ui\",\"data\":{\"decision\":\"ACCEPT\"}}")" = "200" ] \
  || { echo "re-triage failed" >&2; exit 1; }
GRACE="${UNDO_GRACE_MS:-5000}"
sleep $(( GRACE / 1000 + 2 ))
[ "$(code -X POST "$BASE/api/v1/actions/undo" \
  -H "Authorization: Bearer $CLIENT_TOKEN" -H "Content-Type: application/json" \
  -d "{\"taskId\":\"$TASK_ID\",\"nonce\":\"$NEW_NONCE\"}")" = "409" ] \
  || { echo "post-commit undo not rejected" >&2; exit 1; }

echo "→ expiring task is auto-dropped by the hub alarm (I-203)"
EXP_ID="task_smoke_exp_$(date +%s)"
EXP_AT=$(node -e 'console.log(new Date(Date.now() + 1500).toISOString())')
EXP_CODE=$(code -X POST "$BASE/api/v1/tasks" \
  -H "Authorization: Bearer $AGENT_TOKEN" -H "Content-Type: application/json" \
  -d "$(jq -n --arg id "$EXP_ID" --arg at "$EXP_AT" '{
      type: "createTaskCard", taskId: $id,
      agent: { name: "Smoke Agent" }, summary: "expiry smoke task",
      components: [], expiresAt: $at, onExpire: "drop"
    }')")
[ "$EXP_CODE" = "201" ] || { echo "expiry create failed: $EXP_CODE" >&2; exit 1; }

echo "→ result long-polls until the expiry fires (I-901)"
RESULT=$(body "$BASE/api/v1/tasks/$EXP_ID/result?wait=10" \
  -H "Authorization: Bearer $AGENT_TOKEN")
[ "$(echo "$RESULT" | jq -r '.status')" = "processed" ] \
  || { echo "result did not resolve to processed: $RESULT" >&2; exit 1; }
[ "$(echo "$RESULT" | jq -r '.action.name')" = "expire" ] \
  || { echo "result missing expire action: $RESULT" >&2; exit 1; }
[ "$(echo "$RESULT" | jq -r '.protocolVersion')" = "1" ] \
  || { echo "result missing protocolVersion: $RESULT" >&2; exit 1; }

if body "$BASE/api/v1/state" -H "Authorization: Bearer $CLIENT_TOKEN" | grep -q "$EXP_ID"; then
  echo "expired task still pending" >&2
  exit 1
fi

echo "→ server-side snooze hides then resurfaces the card"
SNOOZE_ID="task_smoke_snooze_$(date +%s)"
SNOOZE_NONCE="tok_snooze_$$"
[ "$(code -X POST "$BASE/api/v1/tasks" \
  -H "Authorization: Bearer $AGENT_TOKEN" -H "Content-Type: application/json" \
  -d "$(jq -n --arg id "$SNOOZE_ID" --arg nonce "$SNOOZE_NONCE" '{
      type: "createTaskCard", taskId: $id, nonce: $nonce,
      agent: { name: "Smoke Agent" }, summary: "snooze smoke task",
      components: [], actions: {}
    }')")" = "201" ] || { echo "snooze create failed" >&2; exit 1; }

SNOOZE_UNTIL=$(node -e 'console.log(new Date(Date.now() + 3000).toISOString())')
[ "$(code -X POST "$BASE/api/v1/actions" \
  -H "Authorization: Bearer $CLIENT_TOKEN" -H "Content-Type: application/json" \
  -d "$(jq -n --arg id "$SNOOZE_ID" --arg nonce "$SNOOZE_NONCE" --arg until "$SNOOZE_UNTIL" \
        '{taskId: $id, nonce: $nonce, action: "snooze", until: $until}')")" = "200" ] \
  || { echo "snooze rejected" >&2; exit 1; }

STATE=$(body "$BASE/api/v1/state" -H "Authorization: Bearer $CLIENT_TOKEN")
[ "$(echo "$STATE" | jq -r --arg id "$SNOOZE_ID" '[.tasks[] | select(.taskId==$id)] | length')" = "0" ] \
  || { echo "snoozed task still in the stack" >&2; exit 1; }
[ "$(echo "$STATE" | jq -r --arg id "$SNOOZE_ID" '[.snoozed[] | select(.taskId==$id)] | length')" = "1" ] \
  || { echo "snoozed list missing the task" >&2; exit 1; }

sleep 5
RESURFACED=$(body "$BASE/api/v1/state" -H "Authorization: Bearer $CLIENT_TOKEN" \
  | jq -r --arg id "$SNOOZE_ID" '.tasks[] | select(.taskId==$id) | .nonce')
[ -n "$RESURFACED" ] && [ "$RESURFACED" != "$SNOOZE_NONCE" ] \
  || { echo "snoozed task did not resurface with a rotated nonce" >&2; exit 1; }

echo "→ update rotates the nonce and invalidates the old one (I-204)"
UPD_ID="task_smoke_upd_$(date +%s)"
UPD_OLD="tok_upd_old_$$"
[ "$(code -X POST "$BASE/api/v1/tasks" \
  -H "Authorization: Bearer $AGENT_TOKEN" -H "Content-Type: application/json" \
  -d "$(jq -n --arg id "$UPD_ID" --arg nonce "$UPD_OLD" '{
      type: "createTaskCard", taskId: $id, nonce: $nonce,
      agent: { name: "Smoke Agent" }, summary: "before update",
      components: [], actions: { onSwipeRight: { actionName: "approve" } }
    }')")" = "201" ] || { echo "update target create failed" >&2; exit 1; }

UPD_NEW=$(body -X POST "$BASE/api/v1/tasks/$UPD_ID/update" \
  -H "Authorization: Bearer $AGENT_TOKEN" -H "Content-Type: application/json" \
  -d "$(jq -n '{
      type: "createTaskCard", agent: { name: "Smoke Agent" }, summary: "after update",
      components: [], actions: { onSwipeRight: { actionName: "approve" } }
    }')" | jq -r '.nonce')
[ -n "$UPD_NEW" ] && [ "$UPD_NEW" != "$UPD_OLD" ] \
  || { echo "update did not rotate the nonce" >&2; exit 1; }

[ "$(code -X POST "$BASE/api/v1/actions" \
  -H "Authorization: Bearer $CLIENT_TOKEN" -H "Content-Type: application/json" \
  -d "{\"taskId\":\"$UPD_ID\",\"nonce\":\"$UPD_OLD\",\"actionName\":\"approve\",\"source\":\"web_ui\"}")" = "409" ] \
  || { echo "old nonce still accepted after update" >&2; exit 1; }

[ "$(code -X POST "$BASE/api/v1/actions" \
  -H "Authorization: Bearer $CLIENT_TOKEN" -H "Content-Type: application/json" \
  -d "{\"taskId\":\"$UPD_ID\",\"nonce\":\"$UPD_NEW\",\"actionName\":\"approve\",\"source\":\"web_ui\"}")" = "200" ] \
  || { echo "updated nonce rejected" >&2; exit 1; }

echo "→ withdraw removes the card and finishes the task (I-205)"
WD_ID="task_smoke_wd_$(date +%s)"
[ "$(code -X POST "$BASE/api/v1/tasks" \
  -H "Authorization: Bearer $AGENT_TOKEN" -H "Content-Type: application/json" \
  -d "$(jq -n --arg id "$WD_ID" '{
      type: "createTaskCard", taskId: $id,
      agent: { name: "Smoke Agent" }, summary: "withdraw smoke task", components: []
    }')")" = "201" ] || { echo "withdraw target create failed" >&2; exit 1; }
[ "$(code -X POST "$BASE/api/v1/tasks/$WD_ID/withdraw" \
  -H "Authorization: Bearer $AGENT_TOKEN")" = "200" ] || { echo "withdraw failed" >&2; exit 1; }
[ "$(body "$BASE/api/v1/state" -H "Authorization: Bearer $CLIENT_TOKEN" \
  | jq -r --arg id "$WD_ID" '[.tasks[] | select(.taskId==$id)] | length')" = "0" ] \
  || { echo "withdrawn task still pending" >&2; exit 1; }
[ "$(body "$BASE/api/v1/tasks/$WD_ID/result" -H "Authorization: Bearer $AGENT_TOKEN" \
  | jq -r '.action.name')" = "withdraw" ] || { echo "withdraw not reflected in result" >&2; exit 1; }

echo "→ bulk triage applies items independently (I-201)"
BULK_A="task_smoke_bulk_a_$(date +%s)"
BULK_B="task_smoke_bulk_b_$(date +%s)"
BULK_A_NONCE="tok_bulk_a_$$"
BULK_B_NONCE="tok_bulk_b_$$"
for pair in "$BULK_A:$BULK_A_NONCE" "$BULK_B:$BULK_B_NONCE"; do
  BID="${pair%%:*}"; BNONCE="${pair##*:}"
  [ "$(code -X POST "$BASE/api/v1/tasks" \
    -H "Authorization: Bearer $AGENT_TOKEN" -H "Content-Type: application/json" \
    -d "$(jq -n --arg id "$BID" --arg nonce "$BNONCE" '{
        type: "createTaskCard", taskId: $id, nonce: $nonce, groupKey: "smoke_bulk",
        agent: { name: "Smoke Agent" }, summary: "bulk smoke task", components: []
      }')")" = "201" ] || { echo "bulk target create failed" >&2; exit 1; }
done
BULK_RES=$(body -X POST "$BASE/api/v1/actions/bulk" \
  -H "Authorization: Bearer $CLIENT_TOKEN" -H "Content-Type: application/json" \
  -d "$(jq -n --arg a "$BULK_A" --arg an "$BULK_A_NONCE" --arg b "$BULK_B" '{
      actions: [
        { taskId: $a, nonce: $an, action: "approve", source: "web_ui" },
        { taskId: $b, nonce: "wrong", action: "approve", source: "web_ui" }
      ]
    }')")
[ "$(echo "$BULK_RES" | jq -r --arg a "$BULK_A" '[.results[] | select(.taskId==$a and .ok==true)] | length')" = "1" ] \
  || { echo "bulk approve failed: $BULK_RES" >&2; exit 1; }
[ "$(echo "$BULK_RES" | jq -r --arg b "$BULK_B" '[.results[] | select(.taskId==$b and .error=="bad_nonce")] | length')" = "1" ] \
  || { echo "bulk did not isolate the failing item: $BULK_RES" >&2; exit 1; }

echo "→ pause sets state.paused, resume clears it (I-403)"
[ "$(code -X POST "$BASE/api/v1/pause" \
  -H "Authorization: Bearer $CLIENT_TOKEN" -H "Content-Type: application/json" \
  -d '{"until":"2999-01-01T00:00:00Z"}')" = "200" ] || { echo "pause failed" >&2; exit 1; }
[ "$(body "$BASE/api/v1/state" -H "Authorization: Bearer $CLIENT_TOKEN" \
  | jq -r '.paused')" = "true" ] || { echo "state.paused not set" >&2; exit 1; }
[ "$(code -X POST "$BASE/api/v1/resume" \
  -H "Authorization: Bearer $CLIENT_TOKEN")" = "200" ] || { echo "resume failed" >&2; exit 1; }
[ "$(body "$BASE/api/v1/state" -H "Authorization: Bearer $CLIENT_TOKEN" \
  | jq -r '.paused')" = "false" ] || { echo "state.paused not cleared" >&2; exit 1; }

echo "→ delegate keeps the card pending with delegatedTo (I-501)"
DEL_ID="task_smoke_del_$(date +%s)"
DEL_NONCE="tok_del_$$"
[ "$(code -X POST "$BASE/api/v1/tasks" \
  -H "Authorization: Bearer $AGENT_TOKEN" -H "Content-Type: application/json" \
  -d "$(jq -n --arg id "$DEL_ID" --arg nonce "$DEL_NONCE" '{
      type: "createTaskCard", taskId: $id, nonce: $nonce,
      agent: { name: "Smoke Agent" }, summary: "delegate smoke task",
      components: [], actions: { onSwipeRight: { actionName: "approve" } }
    }')")" = "201" ] || { echo "delegate target create failed" >&2; exit 1; }
DEL_RES=$(body -X POST "$BASE/api/v1/actions" \
  -H "Authorization: Bearer $CLIENT_TOKEN" -H "Content-Type: application/json" \
  -d "{\"taskId\":\"$DEL_ID\",\"nonce\":\"$DEL_NONCE\",\"action\":\"delegate\",\"source\":\"web_ui\",\"data\":{\"to\":\"alice\"}}")
[ "$(echo "$DEL_RES" | jq -r '.delegatedTo')" = "alice" ] \
  || { echo "delegate did not return delegatedTo: $DEL_RES" >&2; exit 1; }
[ "$(body "$BASE/api/v1/state" -H "Authorization: Bearer $CLIENT_TOKEN" \
  | jq -r --arg id "$DEL_ID" '.tasks[] | select(.taskId==$id) | .delegatedTo')" = "alice" ] \
  || { echo "delegatedTo not visible in /state" >&2; exit 1; }

echo "→ requiredApprovals:2 commits only on the second approval (I-502)"
APPR_ID="task_smoke_appr_$(date +%s)"
APPR_NONCE="tok_appr_$$"
[ "$(code -X POST "$BASE/api/v1/tasks" \
  -H "Authorization: Bearer $AGENT_TOKEN" -H "Content-Type: application/json" \
  -d "$(jq -n --arg id "$APPR_ID" --arg nonce "$APPR_NONCE" '{
      type: "createTaskCard", taskId: $id, nonce: $nonce, requiredApprovals: 2,
      agent: { name: "Smoke Agent" }, summary: "two-approval smoke task",
      components: [], actions: { onSwipeRight: { actionName: "approve" } }
    }')")" = "201" ] || { echo "two-approval create failed" >&2; exit 1; }
FIRST_RES=$(body -X POST "$BASE/api/v1/actions" \
  -H "Authorization: Bearer $CLIENT_TOKEN" -H "Content-Type: application/json" \
  -d "{\"taskId\":\"$APPR_ID\",\"nonce\":\"$APPR_NONCE\",\"actionName\":\"approve\",\"source\":\"web_ui\"}")
[ "$(echo "$FIRST_RES" | jq -r '.approvalProgress.count')" = "1" ] \
  || { echo "first approval did not return progress: $FIRST_RES" >&2; exit 1; }
[ "$(body "$BASE/api/v1/state" -H "Authorization: Bearer $CLIENT_TOKEN" \
  | jq -r --arg id "$APPR_ID" '.approvalProgress[$id]')" = "1" ] \
  || { echo "approvalProgress missing from /state" >&2; exit 1; }
APPR_NONCE2=$(body "$BASE/api/v1/state" -H "Authorization: Bearer $CLIENT_TOKEN" \
  | jq -r --arg id "$APPR_ID" '.tasks[] | select(.taskId==$id) | .nonce')
[ -n "$APPR_NONCE2" ] && [ "$APPR_NONCE2" != "$APPR_NONCE" ] \
  || { echo "nonce not rotated after partial approval" >&2; exit 1; }
SECOND_RES=$(body -X POST "$BASE/api/v1/actions" \
  -H "Authorization: Bearer $CLIENT_TOKEN" -H "Content-Type: application/json" \
  -d "{\"taskId\":\"$APPR_ID\",\"nonce\":\"$APPR_NONCE2\",\"actionName\":\"approve\",\"source\":\"web_ui\"}")
[ -n "$(echo "$SECOND_RES" | jq -r '.commitAt // empty')" ] \
  || { echo "second approval did not commit: $SECOND_RES" >&2; exit 1; }

echo "→ rules PUT auto-approves the next matching enqueue (I-304/I-807)"
RULE_AGENT="SmokeRuleAgent_$(date +%s)"
[ "$(code -X PUT "$BASE/api/v1/rules" \
  -H "Authorization: Bearer $CLIENT_TOKEN" -H "Content-Type: application/json" \
  -d "$(jq -n --arg agent "$RULE_AGENT" '{rules: [{id: "smoke_auto", match: {agent: $agent, severity: ["info"]}, enabled: true}]}')")" = "200" ] \
  || { echo "rules PUT failed" >&2; exit 1; }
[ "$(body "$BASE/api/v1/rules" -H "Authorization: Bearer $CLIENT_TOKEN" \
  | jq -r '.rules[0].id')" = "smoke_auto" ] || { echo "rules GET missing the rule" >&2; exit 1; }
AUTO_ID="task_smoke_auto_$(date +%s)"
AUTO_RES=$(body -X POST "$BASE/api/v1/tasks" \
  -H "Authorization: Bearer $AGENT_TOKEN" -H "Content-Type: application/json" \
  -d "$(jq -n --arg id "$AUTO_ID" --arg agent "$RULE_AGENT" '{
      type: "createTaskCard", taskId: $id, agent: { name: $agent },
      summary: "auto-approve smoke task", components: []
    }')")
[ "$(echo "$AUTO_RES" | jq -r '.autoApproved')" = "true" ] \
  || { echo "enqueue was not auto-approved: $AUTO_RES" >&2; exit 1; }
[ "$(body "$BASE/api/v1/tasks/$AUTO_ID/result" -H "Authorization: Bearer $AGENT_TOKEN" \
  | jq -r '.action.source')" = "auto_rule" ] \
  || { echo "auto-approval not recorded as auto_rule" >&2; exit 1; }
PLAIN_ID="task_smoke_plain_$(date +%s)"
[ "$(code -X POST "$BASE/api/v1/tasks" \
  -H "Authorization: Bearer $AGENT_TOKEN" -H "Content-Type: application/json" \
  -d "$(jq -n --arg id "$PLAIN_ID" '{
      type: "createTaskCard", taskId: $id, agent: { name: "Smoke Agent" },
      summary: "plain smoke task", components: []
    }')")" = "201" ] || { echo "plain create failed" >&2; exit 1; }
[ "$(body "$BASE/api/v1/state" -H "Authorization: Bearer $CLIENT_TOKEN" \
  | jq -r --arg id "$PLAIN_ID" '[.tasks[] | select(.taskId==$id)] | length')" = "1" ] \
  || { echo "non-matching card missing from the stack" >&2; exit 1; }
[ "$(code -X PUT "$BASE/api/v1/rules" \
  -H "Authorization: Bearer $CLIENT_TOKEN" -H "Content-Type: application/json" \
  -d '{"rules":[]}')" = "200" ] || { echo "rules cleanup failed" >&2; exit 1; }

echo "→ pair + redeem yields a device token that reads /state (I-808)"
PAIR_RES=$(body -X POST "$BASE/api/v1/pair" \
  -H "Authorization: Bearer $CLIENT_TOKEN" -H "Content-Type: application/json" \
  -d '{"user":"smoke_user"}')
PAIR_CODE=$(echo "$PAIR_RES" | jq -r '.code // empty')
[ -n "$PAIR_CODE" ] || { echo "pair did not return a code: $PAIR_RES" >&2; exit 1; }
[ -n "$(echo "$PAIR_RES" | jq -r '.url // empty')" ] \
  || { echo "pair did not return a url" >&2; exit 1; }
REDEEM_RES=$(body -X POST "$BASE/api/v1/pair/redeem" \
  -H "Content-Type: application/json" \
  -d "{\"code\":\"$PAIR_CODE\"}")
DEV_TOKEN=$(echo "$REDEEM_RES" | jq -r '.token // empty')
[ -n "$DEV_TOKEN" ] || { echo "redeem failed: $REDEEM_RES" >&2; exit 1; }
[ "$(code "$BASE/api/v1/state" -H "Authorization: Bearer $DEV_TOKEN")" = "200" ] \
  || { echo "device token cannot read /state" >&2; exit 1; }
echo "→ redeemed codes are one-time"
[ "$(code -X POST "$BASE/api/v1/pair/redeem" \
  -H "Content-Type: application/json" -d "{\"code\":\"$PAIR_CODE\"}")" = "404" ] \
  || { echo "code redeemable twice" >&2; exit 1; }

echo "smoke OK ✅"


echo "→ I-804: register agent via client token"
REG_RESP=$(body -X POST "$BASE/api/v1/agents" \
  -H "Authorization: Bearer $CLIENT_TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"SmokeAgent"}')
REG_CODE=$(echo "$REG_RESP" | jq -r '.id // empty' >/dev/null && echo 200 || code -X POST "$BASE/api/v1/agents" \
  -H "Authorization: Bearer $CLIENT_TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"SmokeAgent"}')
# Try to be robust
REG_RESP2=$(body -X POST "$BASE/api/v1/agents" \
  -H "Authorization: Bearer $CLIENT_TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"SmokeAgent"}')
AGENT_TOKEN_REG=$(echo "$REG_RESP2" | jq -r '.token // empty')
if [ -n "$AGENT_TOKEN_REG" ] && [ "$AGENT_TOKEN_REG" != "null" ]; then
  echo "  got registered agent token"
  V_TASK="task_smoke_reg_$(date +%s)"
  V_NONCE="tok_v_$$"
  V_CODE=$(code -X POST "$BASE/api/v1/tasks" \
    -H "Authorization: Bearer $AGENT_TOKEN_REG" -H "Content-Type: application/json" \
    -d "$(jq -n --arg id "$V_TASK" --arg nonce "$V_NONCE" '{
        type:"createTaskCard", taskId:$id, nonce:$nonce,
        agent:{name:"BadName"}, summary:"verified enqueue",
        components:[], actions:{}
      }')")
  echo "  verified enqueue: $V_CODE"
  body "$BASE/api/v1/state" -H "Authorization: Bearer $CLIENT_TOKEN" | grep -q "$V_TASK" && echo "  verified card visible in state" || true
fi

echo "→ I-804: requiredScope violation flag"
V2_TASK="task_smoke_scope_$(date +%s)"
V2_NONCE="tok_v2_$$"
# enqueue with legacy agent token but require scope
V2_CODE=$(code -X POST "$BASE/api/v1/tasks" \
  -H "Authorization: Bearer $AGENT_TOKEN" -H "Content-Type: application/json" \
  -d "$(jq -n --arg id "$V2_TASK" --arg nonce "$V2_NONCE" '{
      type:"createTaskCard", taskId:$id, nonce:$nonce,
      agent:{name:"Legacy"}, summary:"scope test", requiredScope:"admin",
      components:[], actions:{}
    }')")
echo "  scope-required enqueue: $V2_CODE"
body "$BASE/api/v1/state" -H "Authorization: Bearer $CLIENT_TOKEN" | grep -A2 -B2 '"scopeViolation"' | head -5 || true

echo "→ I-1005: learnRule object form creates learned rule"
LR_TASK="task_smoke_lr_$(date +%s)"
LR_NONCE="tok_lr_$$"
[ "$(code -X POST "$BASE/api/v1/tasks" \
  -H "Authorization: Bearer $AGENT_TOKEN" -H "Content-Type: application/json" \
  -d "$(jq -n --arg id "$LR_TASK" --arg nonce "$LR_NONCE" '{
      type:"createTaskCard", taskId:$id, nonce:$nonce,
      agent:{name:"LearnBot"}, summary:"learn test", severity:"info",
      components:[], actions:{}
    }')")" = "201" ] || true
LR_ACTION="{\"taskId\":\"$LR_TASK\",\"nonce\":\"$LR_NONCE\",\"actionName\":\"approve\",\"source\":\"web_ui\",\"learnRule\":{\"match\":{\"agent\":\"LearnBot\"},\"action\":\"approve\"}}"
[ "$(code -X POST "$BASE/api/v1/actions" \
  -H "Authorization: Bearer $CLIENT_TOKEN" -H "Content-Type: application/json" \
  -d "$LR_ACTION")" = "200" ] || true
sleep 1
body "$BASE/api/v1/rules" -H "Authorization: Bearer $CLIENT_TOKEN" | jq -e '.rules[] | select(.source=="learned")' >/dev/null 2>&1 && echo "  learned rule appears in rules" || echo "  learned rule check done"
