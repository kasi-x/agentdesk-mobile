import 'package:flutter_test/flutter_test.dart';
import 'package:agentdesk_mobile/models/task_card.dart';
import 'package:agentdesk_mobile/services/priority.dart';

TaskCard _task(
  String id, {
  String? createdAt,
  String? expiresAt,
  String severity = 'info',
  double confidence = 1.0,
  num? costAmount,
  String? agentName,
}) =>
    TaskCard.fromJson(<String, dynamic>{
      'taskId': id,
      'nonce': 'n_$id',
      'agent': {'name': agentName ?? 'A'},
      'severity': severity,
      'summary': 's',
      if (createdAt != null) 'createdAt': createdAt,
      if (expiresAt != null) 'expiresAt': expiresAt,
      'confidence': confidence,
      if (costAmount != null)
        'impact': {
          'cost': {'amount': costAmount, 'currency': 'USD'},
        },
      'components': <dynamic>[],
    });

void main() {
  final now = DateTime.utc(2026, 10, 6, 12);

  group('priorityScore', () {
    test('past-deadline critical beats fresh info', () {
      final critical = _task(
        'c',
        severity: 'critical',
        expiresAt: '2026-10-06T00:00:00Z',
        createdAt: '2026-10-06T11:00:00Z',
      );
      final info = _task('i', createdAt: '2026-10-06T11:59:00Z');
      expect(
        priorityScore(critical, now),
        greaterThan(priorityScore(info, now)),
      );
    });

    test('deadline urgency increases as deadline approaches', () {
      final far = _task('far',
          expiresAt: '2026-10-07T12:00:00Z',
          createdAt: '2026-10-06T12:00:00Z');
      final near = _task('near',
          expiresAt: '2026-10-06T12:30:00Z',
          createdAt: '2026-10-06T12:00:00Z');
      final passed = _task('past',
          expiresAt: '2026-10-05T00:00:00Z',
          createdAt: '2026-10-06T12:00:00Z');
      expect(priorityScore(far, now), 0.0, reason: '24h+ away contributes 0');
      expect(priorityScore(near, now), closeTo(40 * (1 - 0.5 / 24), 0.001));
      expect(priorityScore(passed, now), 40.0, reason: 'passed -> full 40');
    });

    test('each factor contributes its weight and is monotonic', () {
      final base = _task('base', createdAt: '2026-10-06T12:00:00Z');
      expect(priorityScore(base, now), 0.0);

      expect(
        priorityScore(
            _task('w', severity: 'warning', createdAt: '2026-10-06T12:00:00Z'),
            now),
        15.0,
      );
      expect(
        priorityScore(
            _task('cr', severity: 'critical', createdAt: '2026-10-06T12:00:00Z'),
            now),
        25.0,
      );

      final small = priorityScore(
          _task('cs', costAmount: 100, createdAt: '2026-10-06T12:00:00Z'), now);
      final big = priorityScore(
          _task('cb', costAmount: 10000, createdAt: '2026-10-06T12:00:00Z'),
          now);
      expect(big, greaterThan(small));
      final huge = priorityScore(
          _task('ch', costAmount: 99999999, createdAt: '2026-10-06T12:00:00Z'),
          now);
      expect(huge, closeTo(15.0, 0.001), reason: 'saturates near \$99,999');

      final low = priorityScore(
          _task('l', confidence: 0.2, createdAt: '2026-10-06T12:00:00Z'), now);
      final high = priorityScore(
          _task('h', confidence: 0.9, createdAt: '2026-10-06T12:00:00Z'), now);
      expect(low, greaterThan(high));

      final recent =
          priorityScore(_task('r', createdAt: '2026-10-06T11:00:00Z'), now);
      final old =
          priorityScore(_task('o', createdAt: '2026-10-04T12:00:00Z'), now);
      expect(old, greaterThan(recent));
      expect(old, closeTo(15.0, 0.001), reason: 'saturates at 24h');
    });

    test('missing or malformed fields contribute 0 and never throw', () {
      final broken = TaskCard.fromJson(<String, dynamic>{
        'taskId': 'x',
        'nonce': 'n',
        'agent': {'name': 'A'},
        'severity': 'info',
        'confidence': -5, // out of 0..1 -> ignored
        'summary': 's',
        'components': <dynamic>[],
        'expiresAt': 'not-a-date', // unparseable -> null
        'createdAt': '2026-10-06T12:00:00Z',
      });
      expect(priorityScore(broken, now), 0.0);
      expect(broken.expiresAt, isNull);
    });
  });

  group('compareTasks / sortTasks', () {
    test('deterministic tiebreak: createdAt DESC then taskId ASC', () {
      // All >=24h old, so the wait factor is saturated and scores tie;
      // the tiebreak is createdAt DESC.
      final old1 = _task('a', createdAt: '2026-10-04T00:00:00Z');
      final old2 = _task('b', createdAt: '2026-10-04T06:00:00Z');
      final old3 = _task('c', createdAt: '2026-10-01T00:00:00Z');
      final sorted = sortTasks([old1, old2, old3], StackOrder.urgent, now);
      expect(sorted.map((t) => t.taskId).toList(), ['b', 'a', 'c']);

      // Same createdAt -> taskId ASC.
      final x = _task('b', createdAt: '2026-10-04T00:00:00Z');
      final y = _task('a', createdAt: '2026-10-04T00:00:00Z');
      final tied = sortTasks([x, y], StackOrder.urgent, now);
      expect(tied.map((t) => t.taskId).toList(), ['a', 'b']);
    });

    test('newest mode orders strictly by createdAt then taskId', () {
      final old = _task('a', createdAt: '2026-10-01T00:00:00Z');
      final mid = _task('c', createdAt: '2026-10-05T00:00:00Z');
      final new1 = _task('b', createdAt: '2026-10-06T00:00:00Z');
      final new2 = _task('a', createdAt: '2026-10-06T00:00:00Z');
      final sorted = sortTasks([old, mid, new1, new2], StackOrder.newest, now);
      expect(sorted.map((t) => t.taskId).toList(), ['a', 'b', 'c', 'a']);
    });

    test('urgent mode orders by score descending', () {
      final low = _task('low', createdAt: '2026-10-06T11:59:00Z');
      final high = _task(
        'high',
        severity: 'critical',
        createdAt: '2026-10-06T09:00:00Z',
      );
      final sorted = sortTasks([low, high], StackOrder.urgent, now);
      expect(sorted.map((t) => t.taskId).toList(), ['high', 'low']);
    });

    test('agent mode groups by agent name then score', () {
      final annaLow =
          _task('a1', agentName: 'Anna', createdAt: '2026-10-06T11:00:00Z');
      final annaHigh = _task('a2',
          agentName: 'Anna',
          severity: 'critical',
          createdAt: '2026-10-06T10:00:00Z');
      final bob =
          _task('b1', agentName: 'bob', createdAt: '2026-10-06T12:00:00Z');
      final sorted = sortTasks([annaLow, bob, annaHigh], StackOrder.agent, now);
      expect(sorted.map((t) => t.taskId).toList(), ['a2', 'a1', 'b1']);
    });

    test('sortTasks returns a new list and leaves the input untouched', () {
      final original = <TaskCard>[
        _task('a', createdAt: '2026-10-01T00:00:00Z'),
        _task('b', createdAt: '2026-10-06T00:00:00Z'),
      ];
      final snapshot = original.map((t) => t.taskId).toList();
      final sorted = sortTasks(original, StackOrder.newest, now);
      expect(original.map((t) => t.taskId).toList(), snapshot);
      expect(sorted, isNot(same(original)));
    });
  });
}
