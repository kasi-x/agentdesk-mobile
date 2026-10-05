/* Pure helpers shared across modules — no DOM, no state. */

/** Risk levels mirror mobile task_card.dart (I-102). */
export function riskLevel(task) {
  const impact = task.impact || {};
  const irreversible = impact.reversible === false;
  if (task.severity === 'critical' && irreversible) return 'locked';
  if (task.severity === 'critical' || irreversible ||
      (impact.cost && impact.cost.amount > 0)) return 'high';
  return 'normal';
}

/** Relative time label: 「たった今」「3分前」…; blank for unparseable input. */
export function timeAgo(iso) {
  const t = new Date(iso);
  if (Number.isNaN(t.getTime())) return '';
  const s = Math.max(0, (Date.now() - t.getTime()) / 1000);
  if (s < 60) return 'たった今';
  if (s < 3600) return `${Math.floor(s / 60)}分前`;
  if (s < 86400) return `${Math.floor(s / 3600)}時間前`;
  return `${Math.floor(s / 86400)}日前`;
}

/** Display name for a card's agent (never empty). */
export function agentName(task) {
  return (task && task.agent && task.agent.name) || 'Agent';
}
