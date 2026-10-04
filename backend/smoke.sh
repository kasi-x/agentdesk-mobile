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

echo "smoke OK ✅"
