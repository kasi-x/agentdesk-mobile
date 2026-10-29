import test from 'node:test';
import assert from 'node:assert/strict';

// automation.js pulls in net.js → store.js (localStorage) and render.js
// (document) — stub the browser globals before importing.
globalThis.localStorage = {
  getItem: () => null,
  setItem: () => {},
};
globalThis.location = { origin: 'http://localhost' };
globalThis.document = {
  getElementById: () => null,
  querySelectorAll: () => [],
  createElement: () => ({
    className: '', textContent: '', style: {}, dataset: {},
    appendChild() {}, setAttribute() {}, addEventListener() {},
    classList: { toggle() {}, add() {} },
  }),
};

const { automationOffer, buildRuleMatch } = await import('./automation.js');

const card = (over = {}) => ({
  taskId: 't1',
  nonce: 'n1',
  agent: { name: 'Billing' },
  severity: 'warning',
  ...over,
});

test('automationOffer: approve builds a learned-rule draft from the card', () => {
  const task = card({ groupKey: 'refunds', impact: { cost: { amount: 120, currency: 'USD' } } });
  const offer = automationOffer(task, { taskId: 't1', actionName: 'approve' });
  assert.equal(offer.action, 'approve');
  assert.deepEqual(offer.match, { agent: 'Billing', severity: ['warning'], groupKey: 'refunds' });
  assert.equal(offer.maxCostSeed, '120');
});

test('automationOffer: reject maps to a reject rule', () => {
  const offer = automationOffer(card(), { taskId: 't1', actionName: 'reject' });
  assert.equal(offer.action, 'reject');
});

test('automationOffer: snooze/delegate/learnRule/multi-party are skipped', () => {
  const t = card();
  assert.equal(automationOffer(t, { actionName: 'snooze', action: 'snooze' }), null);
  assert.equal(automationOffer(t, { actionName: 'delegate', action: 'delegate' }), null);
  assert.equal(automationOffer(t, { actionName: 'approve', learnRule: true }), null);
  assert.equal(
    automationOffer(card({ requiredApprovals: 2 }), { actionName: 'approve' }),
    null,
  );
  assert.equal(automationOffer(t, null), null);
});

test('buildRuleMatch: tolerant of missing fields', () => {
  assert.deepEqual(buildRuleMatch({ agent: {} }), {});
  assert.deepEqual(buildRuleMatch(card()), { agent: 'Billing', severity: ['warning'] });
});
