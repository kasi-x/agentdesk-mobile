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

echo "smoke OK ✅"
