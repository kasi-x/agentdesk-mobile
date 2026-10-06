import test from 'node:test';
import assert from 'node:assert/strict';
import { priorityScore, compareTasks, sortTasks } from './priority.js';

const DAY = 86_400_000;
const NOW = Date.parse('2026-10-06T12:00:00Z');

function mk(over) {
  return Object.assign(
    { taskId: 't', createdAt: '2026-10-06T12:00:00Z', severity: 'info' },
    over,
  );
}

test('score: past-deadline critical > no-deadline info', () => {
  const hot = mk({ taskId: 'a', severity: 'critical', expiresAt: '2026-10-01T00:00:00Z' });
  const calm = mk({ taskId: 'b' });
  assert.ok(priorityScore(hot, NOW) > priorityScore(calm, NOW));
});

test('each factor raises the score monotonically', () => {
  const base = mk({});

  // deadline: 期限が近いほど上がる(満24時間先で 0、超過で 40)
  const far = mk({ expiresAt: '2026-10-10T12:00:00Z' }); // 満4日先 → 0
  const near = mk({ expiresAt: '2026-10-06T11:30:00Z' }); // 30分前 → 40
  assert.equal(priorityScore(far, NOW), priorityScore(base, NOW));
  assert.equal(priorityScore(near, NOW) - priorityScore(base, NOW), 40);

  // severity
  assert.equal(priorityScore(mk({ severity: 'critical' }), NOW) - priorityScore(base, NOW), 25);
  assert.equal(priorityScore(mk({ severity: 'warning' }), NOW) - priorityScore(base, NOW), 15);
  assert.equal(priorityScore(mk({ severity: 'bogus' }), NOW), priorityScore(base, NOW));

  // cost: $99,999 で飽和する 15
  assert.equal(priorityScore(mk({ impact: { cost: { amount: 99_999 } } }), NOW) - priorityScore(base, NOW), 15);
  const small = priorityScore(mk({ impact: { cost: { amount: 99 } } }), NOW) - priorityScore(base, NOW);
  assert.ok(small > 0 && small < 15);

  // confidence: 0(低信頼)が 10、1(高信頼)が 0
  assert.equal(priorityScore(mk({ confidence: 0 }), NOW) - priorityScore(base, NOW), 10);
  assert.equal(priorityScore(mk({ confidence: 1 }), NOW), priorityScore(base, NOW));

  // wait: 古い createdAt ほど 15 に近づく(24時間で飽和)
  const old = priorityScore(mk({ createdAt: '2026-09-20T00:00:00Z' }), NOW) - priorityScore(base, NOW);
  assert.equal(old, 15);
});

test("modes: 'urgent' sorts by score desc with deterministic tiebreak", () => {
  const tasks = [
    mk({ taskId: 'c', severity: 'critical', expiresAt: '2026-10-01T00:00:00Z' }), // 最も緊急
    mk({ taskId: 'b' }), // 通常
    mk({ taskId: 'a' }), // 通常、id が b より小
  ];
  const sorted = sortTasks(tasks, 'urgent', NOW);
  assert.deepEqual(sorted.map((t) => t.taskId), ['c', 'a', 'b']);

  // 同スコアなら createdAt 降順(新しい方が先)
  const same = [
    mk({ taskId: 'x', createdAt: '2026-10-01T09:00:00Z' }),
    mk({ taskId: 'y', createdAt: '2026-10-01T10:00:00Z' }),
  ];
  assert.deepEqual(sortTasks(same, 'urgent', NOW).map((t) => t.taskId), ['y', 'x']);
});

test("mode: 'newest' sorts by createdAt desc", () => {
  const tasks = [
    mk({ taskId: 'a', createdAt: '2026-10-06T08:00:00Z' }),
    mk({ taskId: 'b', createdAt: '2026-10-06T11:00:00Z' }),
    mk({ taskId: 'c', createdAt: '2026-10-06T09:00:00Z' }),
  ];
  assert.deepEqual(sortTasks(tasks, 'newest', NOW).map((t) => t.taskId), ['b', 'c', 'a']);
});

test("mode: 'agent' groups by agent.name then score desc", () => {
  const tasks = [
    mk({ taskId: 'a', agent: { name: 'zoe' }, severity: 'info' }),
    mk({ taskId: 'b', agent: { name: 'ada' }, severity: 'critical' }),
    mk({ taskId: 'c', agent: { name: 'ada' }, severity: 'info' }),
  ];
  const sorted = sortTasks(tasks, 'agent', NOW);
  // ada グループが先、その中で critical の b が先 → b, c, a
  assert.deepEqual(sorted.map((t) => t.taskId), ['b', 'c', 'a']);
});

test('sortTasks returns a new array and never mutates input', () => {
  const tasks = [
    mk({ taskId: 'a', severity: 'critical' }),
    mk({ taskId: 'b' }),
  ];
  const before = tasks.map((t) => t.taskId);
  const sorted = sortTasks(tasks, 'urgent', NOW);
  assert.notEqual(sorted, tasks);
  assert.deepEqual(tasks.map((t) => t.taskId), before);
  assert.deepEqual(sorted.map((t) => t.taskId), ['a', 'b']);
});

test('malformed input returns a finite number and never throws', () => {
  assert.ok(Number.isFinite(priorityScore(null, NOW)));
  assert.ok(Number.isFinite(priorityScore(undefined, NOW)));
  assert.ok(Number.isFinite(priorityScore({}, NaN)));
  assert.ok(
    Number.isFinite(
      priorityScore(
        {
          expiresAt: 'garbage',
          createdAt: '',
          severity: 'bogus',
          confidence: 'x',
          impact: null,
        },
        NOW,
      ),
    ),
  );
  assert.doesNotThrow(() => sortTasks([null, {}, 'x', 42], 'urgent', NOW));
  assert.ok(Number.isFinite(compareTasks(null, {}, 'urgent', NOW)));
});