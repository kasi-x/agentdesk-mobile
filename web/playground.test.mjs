import test from 'node:test';
import assert from 'node:assert/strict';

globalThis.localStorage = { getItem: () => null, setItem: () => {} };
globalThis.location = { origin: 'http://localhost' };
globalThis.document = {
  readyState: 'complete',
  getElementById: () => null,
  querySelectorAll: () => [],
  createElement: () => ({
    className: '', textContent: '', style: {}, dataset: {},
    appendChild() {}, setAttribute() {}, addEventListener() {},
    classList: { toggle() {}, add() {} },
  }),
  addEventListener() {},
};

const { TEMPLATES, lintTaskCard } = await import('./playground.js');
test('all embedded templates pass playground lintTaskCard', () => {
  for (const [key, tmpl] of Object.entries(TEMPLATES)) {
    const err = lintTaskCard(JSON.stringify(tmpl));
    assert.equal(err, null, `template ${key} failed lint: ${err}`);
  }
});

test('lintTaskCard catches invalid schema errors', () => {
  assert.match(lintTaskCard('invalid json'), /パースエラー/);
  assert.match(lintTaskCard('[]'), /オブジェクト/);
  assert.match(lintTaskCard('{}'), /agent\.name/);
  assert.match(lintTaskCard('{"agent":{"name":"bot"}}'), /summary/);
  assert.match(lintTaskCard('{"agent":{"name":"bot"},"summary":"test","components":"not_arr"}'), /components/);
  assert.match(lintTaskCard('{"agent":{"name":"bot"},"summary":"test","components":[{}]}'), /id.*component/);
  assert.match(lintTaskCard('{"agent":{"name":"bot"},"summary":"test","confidence":1.5}'), /confidence/);
  assert.match(lintTaskCard('{"agent":{"name":"bot"},"summary":"test","severity":"invalid"}'), /severity/);
});
