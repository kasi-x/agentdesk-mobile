/* I-1005 post-decision scoped-rule creation (web side).
 *
 * After a committed approve/reject, the undo toast offers 「同種を自動化」.
 * The sheet always shows: what the rule will match, an editable scope
 * (maxCost prefilled from impact.cost), a lease period (7日/30日/無制限),
 * an impact preview via POST /api/v1/rules/simulate, and an explicit
 * cancel — 「今回だけ」 is the default because doing nothing creates
 * nothing (strategy.md P0, P6: 観測・段階・取消可能).
 */
import { el, clear, toast } from './dom.js';
import { fetchRules, saveRules, simulateRule } from './net.js';
import { agentName } from './util.js';

const SEV_LABEL = { info: 'info', warning: '警告', critical: '緊急' };

/**
 * Build the offer context for a committed triage reply, or null when no
 * offer should be shown: delegate/snooze actions, replies already
 * carrying learnRule (two-stage swipe already learned), and multi-party
 * cards still short of requiredApprovals.
 */
export function automationOffer(task, reply) {
  if (!task || !reply) return null;
  if (reply.action === 'snooze' || reply.action === 'delegate') return null;
  if (reply.learnRule) return null;
  const req = Number(task.requiredApprovals || 1);
  if (req > 1) return null; // partial commit — the card is still pending
  const action = reply.actionName === 'reject' ? 'reject' : 'approve';
  return {
    task,
    action,
    match: buildRuleMatch(task),
    maxCostSeed: seedCost(task),
  };
}

/** RuleMatch derived from the card: agent name + severity + groupKey. */
export function buildRuleMatch(task) {
  const match = {};
  const name = agentName(task);
  if (name && name !== 'Agent') match.agent = name;
  if (typeof task.severity === 'string' && task.severity) {
    match.severity = [task.severity];
  }
  if (typeof task.groupKey === 'string' && task.groupKey) {
    match.groupKey = task.groupKey;
  }
  return match;
}

/** Prefill for the scope cap: the card's declared cost, when present. */
function seedCost(task) {
  const c = task && task.impact && task.impact.cost;
  return c && typeof c.amount === 'number' && Number.isFinite(c.amount)
    ? String(c.amount) : '';
}

function describeOffer(offer) {
  const parts = [];
  if (offer.match.agent) parts.push(offer.match.agent);
  if (offer.match.severity && offer.match.severity.length) {
    parts.push(offer.match.severity.map((s) => SEV_LABEL[s] || s).join('/'));
  }
  if (offer.match.groupKey) parts.push(`グループ ${offer.match.groupKey}`);
  return parts.join(' · ') || '同じ条件のカード';
}

const PERIODS = [
  { id: '7d', label: '7日間' },
  { id: '30d', label: '30日間' },
  { id: 'none', label: '無制限' },
];

function leaseUntil(id) {
  const days = id === '7d' ? 7 : id === '30d' ? 30 : 0;
  if (!days) return null;
  return new Date(Date.now() + days * 86400_000).toISOString();
}

export function openAutomationSheet(offer) {
  const sheet = document.getElementById('automation-sheet');
  const backdrop = document.getElementById('automation-backdrop');
  if (!sheet || !backdrop) return;
  clear(sheet);

  const close = () => {
    sheet.hidden = true;
    backdrop.hidden = true;
  };
  backdrop.onclick = close;

  const head = el('div', 'sheet-head');
  head.appendChild(el('div', 'sheet-title', '同種を自動化'));
  const x = el('button', 'btn dim sm', '今回だけ');
  x.type = 'button';
  x.addEventListener('click', close);
  head.appendChild(x);
  sheet.appendChild(head);

  // 何に効くか — readable scope before any switch is flipped (I-1005).
  const verb = offer.action === 'reject' ? '自動で却下' : '自動で承認';
  sheet.appendChild(el('div', 'rule-note',
    `${describeOffer(offer)} を今後 ${verb}します。いつでもルール画面から取り消せます。`));

  const costField = el('div', 'form-field');
  costField.appendChild(el('label', '', '上限金額（空=なし）'));
  const cost = el('input');
  cost.type = 'number';
  cost.min = '0';
  cost.placeholder = '例: 1000';
  cost.value = offer.maxCostSeed;
  costField.appendChild(cost);
  sheet.appendChild(costField);

  const periodField = el('div', 'form-field');
  periodField.appendChild(el('label', '', '適用期間'));
  const periodSel = document.createElement('select');
  for (const p of PERIODS) {
    const o = document.createElement('option');
    o.value = p.id;
    o.textContent = p.label;
    periodSel.appendChild(o);
  }
  periodSel.value = '30d'; // 段階的: a bounded lease is the safe default.
  periodField.appendChild(periodSel);
  sheet.appendChild(periodField);

  const preview = el('div', 'sim-preview');
  preview.hidden = true;
  sheet.appendChild(preview);

  const draft = () => {
    const match = { ...offer.match };
    if (cost.value !== '') {
      const n = Number(cost.value);
      if (Number.isFinite(n) && n >= 0) match.maxCost = n;
    }
    const until = leaseUntil(periodSel.value);
    const lease = until ? { until } : null;
    return { match, action: offer.action, lease };
  };

  let simSeq = 0;
  const refreshPreview = async () => {
    const seq = ++simSeq;
    let res;
    try {
      const d = draft();
      res = await simulateRule(d.match, d.action);
    } catch {
      return; // offline — keep the last preview
    }
    if (seq !== simSeq || sheet.hidden) return;
    if (res === 'unsupported' || !res) {
      preview.hidden = true; // old hub — save stays available
      return;
    }
    clear(preview);
    const auto = Number(res.autoApprove) || 0;
    const rej = Number(res.autoReject) || 0;
    const human = Number(res.hitl) || 0;
    const total = auto + rej + human;
    preview.hidden = false;
    const bar = el('div', 'sim-bar');
    for (const [cls, n] of [['approve', auto], ['human', human], ['reject', rej]]) {
      const seg = el('div', `sim-seg ${cls}`);
      seg.style.width = total > 0 ? `${(n / total) * 100}%` : '0%';
      bar.appendChild(seg);
    }
    preview.appendChild(bar);
    const mine = offer.action === 'reject' ? rej : auto;
    preview.appendChild(el('div', 'sim-labels',
      `直近 ${Number(res.sampleSize) || total} 件中 ${mine} 件を自動処理 · 手動 ${human} 件`));
  };
  cost.addEventListener('input', refreshPreview);
  periodSel.addEventListener('change', refreshPreview);
  refreshPreview();

  const row = el('div', 'sheet-actions');
  const cancel = el('button', 'btn dim', '今回だけ');
  cancel.type = 'button';
  cancel.addEventListener('click', close);
  const save = el('button', 'btn primary', 'ルールを作成');
  save.type = 'button';
  save.addEventListener('click', async () => {
    save.disabled = true;
    try {
      const rules = await fetchRules();
      if (rules === 'unsupported') {
        toast('このハブはルールに未対応です');
        return;
      }
      const d = draft();
      const next = (Array.isArray(rules) ? rules : []).concat([{
        id: `r_${Date.now().toString(36)}`,
        match: d.match,
        action: d.action,
        source: 'learned',
        enabled: true,
        ...(d.lease ? { lease: d.lease } : {}),
      }]);
      const res = await saveRules(next);
      if (res === 'ok') {
        toast('ルールを作成しました — ルール画面で取り消せます');
        close();
      } else {
        toast('ルールを保存できませんでした');
      }
    } catch {
      toast('オフライン: ルールを保存できませんでした');
    } finally {
      save.disabled = false;
    }
  });
  row.append(cancel, save);
  sheet.appendChild(row);

  backdrop.hidden = false;
  sheet.hidden = false;
}
