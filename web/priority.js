/* AgentDesk タスクの優先度スコアリング & 並び替え (I-206)。
 *
 * priorityScore(task, nowMs) は 0〜約100 の「緊急度」を返す(高いほど優先)。
 * 各要素は独立に加算される:
 *   deadline   = expiresAt が近いほど 40(満24時間先で 0、現在/超過で 40)
 *   severity   = critical 25 / warning 15 / info(欠落) 0
 *   cost       = impact.cost.amount の桁数に応じて最大 15(log10 スケール)
 *   confidence = 信頼度が低い(0)ほど 10、高い(1)ほど 0
 *   wait       = createdAt からの経過で最大 15(24時間で飽和)
 *
 * 並び替えモード (compareTasks / sortTasks):
 *   'urgent' : スコア降順 → createdAt 降順 → taskId 昇順(完全決定)
 *   'newest' : createdAt 降順 → taskId 昇順
 *   'agent'  : agent.name のロケール順 → スコア降順 → createdAt 降順 → taskId 昇順
 *
 * スヌーズの末尾固定(stack の最後尾へ)は app.js 側の責務で、ここでは扱わない。
 * ワイヤペイロードは非信用のため、フィールド欠落や NaN は 0 として扱い
 * 例外を投げない。
 */
const DAY_MS = 86_400_000;

function clamp01(x) {
  return Math.min(Math.max(x, 0), 1);
}

/** Date.parse で ISO 文字列→ミリ秒。解釈不能なら 0(無限・NaN を流さない)。 */
function tsMs(iso) {
  const v = Date.parse(iso);
  return Number.isNaN(v) ? 0 : v;
}

function priorityScore(task, nowMs) {
  const t = task && typeof task === 'object' ? task : {};
  const now = Number(nowMs);
  const nowValid = Number.isFinite(now) ? now : Date.now();

  // deadline: 期限が近いほど 40 へ。満24時間先で 0、現在/超過で 40。
  let deadline = 0;
  if (t.expiresAt !== undefined && t.expiresAt !== null) {
    const exp = Date.parse(t.expiresAt);
    if (!Number.isNaN(exp)) {
      deadline = 40 * (1 - clamp01((exp - nowValid) / DAY_MS));
    }
  }

  // severity
  let severity = 0;
  if (t.severity === 'critical') severity = 25;
  else if (t.severity === 'warning') severity = 15;

  // cost: 金額の桁数に応じて最大 15。
  let cost = 0;
  const amount = t.impact && t.impact.cost && t.impact.cost.amount;
  if (typeof amount === 'number' && amount > 0) {
    cost = 15 * Math.min(Math.log10(amount + 1) / 5, 1);
  }

  // confidence: 信頼度が低いほど 10。
  let confidence = 0;
  if (typeof t.confidence === 'number' && t.confidence >= 0 && t.confidence <= 1) {
    confidence = 10 * (1 - t.confidence);
  }

  // wait: 生成から24時間で飽和する待機時間 15。
  let wait = 0;
  if (t.createdAt !== undefined && t.createdAt !== null) {
    const created = Date.parse(t.createdAt);
    if (!Number.isNaN(created)) {
      wait = 15 * clamp01((nowValid - created) / DAY_MS);
    }
  }

  return deadline + severity + cost + confidence + wait;
}

function idKey(t) {
  const v = t && t.taskId != null ? t.taskId : '';
  return String(v);
}

function createdAtMs(t) {
  return t && t.createdAt != null ? tsMs(t.createdAt) : 0;
}

/** a が b より先に来るべきなら <0。taskId 昇順で完全決定。 */
function tiebreakId(a, b) {
  const ai = idKey(a);
  const bi = idKey(b);
  if (ai === bi) return 0;
  return ai < bi ? -1 : 1;
}

function compareTasks(a, b, mode, nowMs) {
  const m = mode === 'newest' || mode === 'agent' ? mode : 'urgent';
  const now = Number(nowMs);
  const nowValid = Number.isFinite(now) ? now : Date.now();

  if (m === 'agent') {
    const an = String((a && a.agent && a.agent.name) || '');
    const bn = String((b && b.agent && b.agent.name) || '');
    const byName = an.localeCompare(bn);
    if (byName !== 0) return byName;
    // グループ内は 'urgent' と同じ順序。
  }

  if (m === 'newest') {
    const ac = createdAtMs(a);
    const bc = createdAtMs(b);
    if (ac !== bc) return ac > bc ? -1 : 1; // 新しい方が先
    return tiebreakId(a, b);
  }

  // 'urgent': スコア降順 → createdAt 降順 → taskId 昇順。
  const as = priorityScore(a, nowValid);
  const bs = priorityScore(b, nowValid);
  if (as !== bs) return as > bs ? -1 : 1;
  const ac = createdAtMs(a);
  const bc = createdAtMs(b);
  if (ac !== bc) return ac > bc ? -1 : 1;
  return tiebreakId(a, b);
}

/** 新しい配列を返す(入力は変更しない)。 */
function sortTasks(tasks, mode, nowMs) {
  const arr = Array.isArray(tasks) ? tasks.slice() : [];
  const m = mode === 'newest' || mode === 'agent' ? mode : 'urgent';
  const now = Number(nowMs);
  const nowValid = Number.isFinite(now) ? now : Date.now();
  arr.sort((a, b) => compareTasks(a, b, m, nowValid));
  return arr;
}

// ブラウザではグローバル関数宣言として、Node では module.exports として公開。
if (typeof module !== 'undefined' && module.exports) {
  module.exports = { priorityScore, compareTasks, sortTasks };
}