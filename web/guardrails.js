/* Executive Desk guardrails panel (I-1002, web side): list, enable-toggle
 * and delete auto-approval rules, plus a rule composer with a debounced
 * simulate preview. Text reaches the DOM only via textContent/createElement
 * (NFR-2.1) — never innerHTML, never eval.
 *
 * Probe-tolerant (mirrors `api is HubRulesApi` on mobile): a 404 on
 * GET /api/v1/rules drops to a snapshot-backed read-only list, and a 404 on
 * POST /api/v1/rules/simulate hides the preview instead of erroring.
 */
import { state } from './store.js';
import { el, clear, toast } from './dom.js';
import { fetchRules, saveRules, simulateRule } from './net.js';

const SEVERITIES = ['info', 'warning', 'critical'];
const ACTION_LABEL = { approve: '承認', reject: '却下' };
const SIM_DEBOUNCE_MS = 300;

let _open = false;
let _loading = false;
let _note = '';
let _rules = [];
let _readOnly = false;
let _simSupported = true;
let _simTimer = 0;
let _simSeq = 0;
let _editorNodes = null; // composer inputs — reattached on list re-render

function newRuleId() {
  return `r_${Date.now().toString(36)}`;
}

/** Tolerant one-line summary of a Rule (unknown fields are ignored). */
function describeRule(rule) {
  const m = (rule && rule.match && typeof rule.match === 'object') ? rule.match : {};
  const parts = [];
  if (typeof m.agent === 'string' && m.agent) parts.push(`agent: ${m.agent}`);
  if (Array.isArray(m.severity) && m.severity.length) parts.push(`severity: ${m.severity.join(',')}`);
  if (typeof m.maxCost === 'number' && Number.isFinite(m.maxCost)) parts.push(`maxCost: ${m.maxCost}`);
  if (typeof m.minConfidence === 'number' && Number.isFinite(m.minConfidence)) {
    parts.push(`信頼度 ≥ ${Math.round(m.minConfidence * 100)}%`);
  }
  if (typeof m.groupKey === 'string' && m.groupKey) parts.push(`group: ${m.groupKey}`);
  if (!parts.length) return 'すべてに一致';
  return parts.join(' · ');
}

function cloneRules(rules) {
  try {
    return JSON.parse(JSON.stringify(rules));
  } catch {
    return [];
  }
}

async function loadRules() {
  _loading = true;
  renderGuardrails();
  try {
    const res = await fetchRules();
    if (res === 'unsupported') {
      _rules = cloneRules(state.rules);
      _readOnly = true;
      _note = 'ハブ未対応：表示のみ（snapshot）';
    } else {
      _rules = cloneRules(res);
      _readOnly = false;
      _note = '';
      state.rules = cloneRules(res);
    }
  } catch {
    _rules = cloneRules(state.rules);
    _readOnly = true;
    _note = 'オフライン：表示のみ';
  }
  _loading = false;
  renderGuardrails();
}

async function saveAll() {
  renderGuardrails(); // optimistic: toggle/delete reflect immediately
  try {
    const res = await saveRules(_rules);
    if (res === 'unsupported') toast('ハブ未対応（この端末のみ変更）');
    else {
      toast('ルールを保存しました');
      state.rules = cloneRules(_rules);
    }
  } catch {
    toast('ルールを保存できませんでした（オフライン）');
  }
  renderGuardrails();
}

function ruleRow(rule) {
  const row = el('div', 'rule-row');
  const main = el('div', 'rule-main');
  main.appendChild(el('div', 'rule-id', rule.id || '(no id)'));
  main.appendChild(el('div', 'rule-desc', describeRule(rule)));
  const badges = el('div', 'rule-badges');
  const action = rule.action === 'reject' ? 'reject' : 'approve';
  badges.appendChild(el('span', `rbadge ${action}`, ACTION_LABEL[action]));
  if (rule.source === 'learned') badges.appendChild(el('span', 'rbadge learned', '学習'));
  if (rule.enabled === false) badges.appendChild(el('span', 'rbadge off', '無効'));
  main.appendChild(badges);
  row.appendChild(main);
  const on = rule.enabled !== false;
  const toggle = el('button', 'btn ghost sm rule-toggle' + (on ? ' on' : ''), on ? '有効' : '無効');
  toggle.type = 'button';
  toggle.setAttribute('aria-pressed', String(on));
  toggle.disabled = _readOnly;
  toggle.addEventListener('click', () => {
    rule.enabled = !on;
    saveAll();
  });
  row.appendChild(toggle);
  const del = el('button', 'btn dim sm', '削除');
  del.type = 'button';
  del.disabled = _readOnly;
  del.addEventListener('click', () => {
    _rules = _rules.filter((r) => r !== rule);
    saveAll();
  });
  row.appendChild(del);
  return row;
}

function checkOption(row, value) {
  const label = document.createElement('label');
  label.className = 'check';
  const box = document.createElement('input');
  box.type = 'checkbox';
  box.value = value;
  label.appendChild(box);
  label.appendChild(el('span', '', value));
  row.appendChild(label);
  return box;
}

function editorForm(saved) {
  const wrap = el('div', 'rule-editor');
  wrap.appendChild(el('div', 'rule-editor-title', '新しいルール'));

  const agentField = el('div', 'form-field');
  agentField.appendChild(el('label', '', 'エージェント（空=すべて）'));
  const agent = el('input');
  agent.type = 'text';
  agent.placeholder = '例: scheduler';
  if (saved && typeof saved.agent === 'string') agent.value = saved.agent;
  agentField.appendChild(agent);
  wrap.appendChild(agentField);

  const sevField = el('div', 'form-field');
  sevField.appendChild(el('label', '', '重要度（空=すべて）'));
  const sevRow = el('div', 'check-row');
  const sevBoxes = SEVERITIES.map((s) => {
    const box = checkOption(sevRow, s);
    if (saved && Array.isArray(saved.severity) && saved.severity.includes(s)) box.checked = true;
    return box;
  });
  sevField.appendChild(sevRow);
  wrap.appendChild(sevField);

  const costField = el('div', 'form-field');
  costField.appendChild(el('label', '', '上限金額（空=なし）'));
  const cost = el('input');
  cost.type = 'number';
  cost.min = '0';
  cost.placeholder = '例: 1000';
  if (saved && saved.cost !== '') cost.value = saved.cost;
  costField.appendChild(cost);
  wrap.appendChild(costField);

  const confField = el('div', 'form-field');
  confField.appendChild(el('label', '', '最低信頼度'));
  const confRow = el('div', 'range-row');
  const conf = el('input');
  conf.type = 'range';
  conf.min = '0';
  conf.max = '100';
  conf.value = (saved && saved.conf) || '0';
  const confVal = el('span', 'range-value', conf.value === '0' ? '指定なし' : `${conf.value}%`);
  conf.addEventListener('input', () => {
    confVal.textContent = conf.value === '0' ? '指定なし' : `${conf.value}%`;
  });
  confRow.append(conf, confVal);
  confField.appendChild(confRow);
  wrap.appendChild(confField);

  const actionField = el('div', 'form-field');
  actionField.appendChild(el('label', '', 'アクション'));
  const actionSel = document.createElement('select');
  const optApprove = document.createElement('option');
  optApprove.value = 'approve';
  optApprove.textContent = '承認して自動化';
  const optReject = document.createElement('option');
  optReject.value = 'reject';
  optReject.textContent = '自動で却下';
  actionSel.append(optApprove, optReject);
  if (saved && saved.action === 'reject') actionSel.value = 'reject';
  actionField.appendChild(actionSel);
  wrap.appendChild(actionField);

  const preview = el('div', 'sim-preview');
  preview.hidden = true;
  wrap.appendChild(preview);

  const draft = () => {
    const match = {};
    const name = agent.value.trim();
    if (name) match.agent = name;
    const sevs = sevBoxes.filter((b) => b.checked).map((b) => b.value);
    if (sevs.length) match.severity = sevs;
    if (cost.value !== '') {
      const n = Number(cost.value);
      if (Number.isFinite(n) && n >= 0) match.maxCost = n;
    }
    if (conf.value !== '0') match.minConfidence = Number(conf.value) / 100;
    return { match, action: actionSel.value === 'reject' ? 'reject' : 'approve' };
  };
  const schedule = () => scheduleSimulate(draft, preview);
  agent.addEventListener('input', schedule);
  cost.addEventListener('input', schedule);
  conf.addEventListener('input', schedule);
  actionSel.addEventListener('change', schedule);
  for (const b of sevBoxes) b.addEventListener('change', schedule);

  const add = el('button', 'btn primary', '追加して保存');
  add.type = 'button';
  add.addEventListener('click', async () => {
    if (_readOnly) {
      toast('オフライン：保存できません');
      return;
    }
    const current = draft();
    _rules = [{
      id: newRuleId(),
      match: current.match,
      action: current.action,
      source: 'manual',
      enabled: true,
    }].concat(_rules);
    await saveAll();
  });
  wrap.appendChild(add);
  schedule(); // baseline preview for the empty draft
  return wrap;
}

function scheduleSimulate(draftFn, preview) {
  if (!_simSupported) {
    preview.hidden = true;
    return;
  }
  clearTimeout(_simTimer);
  _simTimer = setTimeout(async () => {
    const seq = ++_simSeq;
    let res;
    try {
      const draft = draftFn();
      res = await simulateRule(draft.match, draft.action);
    } catch {
      return; // offline — leave the last preview in place
    }
    if (seq !== _simSeq || !_open) return;
    if (res === 'unsupported') {
      _simSupported = false;
      preview.hidden = true;
      return;
    }
    renderPreview(preview, res || {});
  }, SIM_DEBOUNCE_MS);
}

function renderPreview(preview, stats) {
  clear(preview);
  const auto = Number(stats.autoApprove) || 0;
  const rej = Number(stats.autoReject) || 0;
  const human = Number(stats.hitl) || 0;
  const total = auto + rej + human;
  preview.hidden = false;
  const bar = el('div', 'sim-bar');
  const segs = [['approve', auto], ['human', human], ['reject', rej]];
  for (const pair of segs) {
    const seg = el('div', `sim-seg ${pair[0]}`);
    seg.style.width = total > 0 ? `${(pair[1] / total) * 100}%` : '0%';
    bar.appendChild(seg);
  }
  preview.appendChild(bar);
  preview.appendChild(el('div', 'sim-labels', `自動 ${auto} · 手動 ${human} · 却下 ${rej}`));
  if (Number.isFinite(Number(stats.sampleSize))) {
    preview.appendChild(el('div', 'sim-size', `n=${stats.sampleSize}`));
  }
}

function snapshotDraft() {
  // The composer lives in the panel DOM; capture its current values so a
  // toggle/delete/save re-render can reseed the rebuilt form.
  if (!_open || _readOnly) return null;
  const panel = document.getElementById('guardrails-panel');
  if (!panel || !panel.querySelector('.rule-editor')) return _editorNodes;
  const inputs = panel.querySelectorAll('.rule-editor .form-field');
  // Field order is fixed: agent(text) · severity(checks) · cost(number) ·
  // confidence(range) · action(select).
  if (inputs.length < 5) return _editorNodes;
  const agentEl = inputs[0].querySelector('input');
  const sevEls = Array.from(inputs[1].querySelectorAll('input:checked')).map((b) => b.value);
  const costEl = inputs[2].querySelector('input');
  const confEl = inputs[3].querySelector('input');
  const actionEl = inputs[4].querySelector('select');
  _editorNodes = {
    agent: agentEl ? agentEl.value : '',
    severity: sevEls,
    cost: costEl ? costEl.value : '',
    conf: confEl ? confEl.value : '0',
    action: actionEl ? actionEl.value : 'approve',
  };
  return _editorNodes;
}

function renderGuardrails() {
  const panel = document.getElementById('guardrails-panel');
  if (!panel) return;
  const draft = snapshotDraft();
  clear(panel);
  const head = el('div', 'sheet-head');
  head.appendChild(el('div', 'sheet-title', `自動承認ルール${_rules.length ? ` (${_rules.length})` : ''}`));
  const close = el('button', 'btn dim sm', '閉じる');
  close.type = 'button';
  close.addEventListener('click', closeGuardrails);
  head.appendChild(close);
  panel.appendChild(head);
  if (_note) panel.appendChild(el('div', 'rule-note', _note));
  if (_loading) {
    panel.appendChild(el('div', 'rule-empty', '読み込み中…'));
    return;
  }
  const list = el('div', 'rule-list');
  if (!_rules.length) list.appendChild(el('div', 'rule-empty', 'ルールはありません'));
  for (const rule of _rules) list.appendChild(ruleRow(rule));
  panel.appendChild(list);
  // A toggle/delete re-render must not wipe the in-progress composer.
  _editorNodes = null;
  if (!_readOnly) panel.appendChild(editorForm(draft));
}

export function isGuardrailsOpen() {
  return _open;
}

export function toggleGuardrails() {
  if (_open) closeGuardrails();
  else openGuardrails();
}

export function openGuardrails() {
  _open = true;
  const panel = document.getElementById('guardrails-panel');
  const backdrop = document.getElementById('guardrails-backdrop');
  const btn = document.getElementById('guardrails-toggle');
  if (panel) panel.hidden = false;
  if (backdrop) backdrop.hidden = false;
  if (btn) {
    btn.setAttribute('aria-pressed', 'true');
    btn.classList.add('on');
  }
  renderGuardrails();
  loadRules();
}

export function closeGuardrails() {
  _open = false;
  const panel = document.getElementById('guardrails-panel');
  const backdrop = document.getElementById('guardrails-backdrop');
  const btn = document.getElementById('guardrails-toggle');
  if (panel) panel.hidden = true;
  if (backdrop) backdrop.hidden = true;
  if (btn) {
    btn.setAttribute('aria-pressed', 'false');
    btn.classList.remove('on');
  }
}

export function wireGuardrails() {
  const btn = document.getElementById('guardrails-toggle');
  if (btn) btn.addEventListener('click', toggleGuardrails);
  const backdrop = document.getElementById('guardrails-backdrop');
  if (backdrop) backdrop.addEventListener('click', closeGuardrails);
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && _open) closeGuardrails();
  });
}
