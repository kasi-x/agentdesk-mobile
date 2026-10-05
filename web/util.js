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

/** Parse a bare number out of a payload string ("$120.00" → 120). */
export function parseEditNumber(raw) {
  const s = String(raw ?? '');
  const m = s.replace(/,/g, '').match(/-?\d+(?:\.\d+)?/);
  return m ? parseFloat(m[0]) : null;
}

/**
 * Parse a payload datetime into an ISO 8601 string. Accepts ISO, local
 * "YYYY-MM-DD HH:MM[:SS]" (read as local time) and "HH:MM" (today, local).
 */
export function parseEditDateTime(raw) {
  const s = String(raw ?? '').trim();
  if (!s) return null;
  let d;
  const m = s.match(/^(\d{4})-(\d{1,2})-(\d{1,2})[ T](\d{1,2}):(\d{2})(?::(\d{2}))?$/);
  if (m) {
    d = new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +(m[6] || 0));
  } else if (/^\d{1,2}:\d{2}$/.test(s)) {
    const [h, mm] = s.split(':').map(Number);
    d = new Date();
    d.setHours(h, mm, 0, 0);
  } else {
    d = new Date(s);
  }
  return d && !Number.isNaN(d.getTime()) ? d.toISOString() : null;
}

/** Display an ISO datetime as short local text ("10/5 16:30"). */
export function fmtEditDateTime(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return String(iso ?? '');
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getMonth() + 1}/${d.getDate()} ${p(d.getHours())}:${p(d.getMinutes())}`;
}

/** Display an ISO datetime + until-label ("〜 10/6 08:00"). */
export function snoozeUntilLabel(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  const p = (n) => String(n).padStart(2, '0');
  return `〜 ${d.getMonth() + 1}/${d.getDate()} ${p(d.getHours())}:${p(d.getMinutes())}`;
}

/** True for a choose card (decisionKind 'choose' with ≥2 choices). */
export function isChooseTask(task) {
  return !!task &&
    task.decisionKind === 'choose' &&
    Array.isArray(task.choices) &&
    task.choices.length >= 2;
}

/** Choice id for a choose-cards choice, falling back to its index. */
export function choiceId(choice, index) {
  if (choice && choice.id !== undefined && choice.id !== null) return String(choice.id);
  return String(index);
}
