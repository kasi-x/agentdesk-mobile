import 'package:flutter_test/flutter_test.dart';
import 'package:agentdesk_mobile/models/task_card.dart';

void main() {
  const reference = <String, dynamic>{
    'type': 'createTaskCard',
    'taskId': 'task_98234',
    'nonce': 'tok_sec_abc123',
    'agent': {'name': 'Calendar & Meeting Agent'},
    'confidence': 0.94,
    'summary': 'ミーティングの日程変更リクエスト',
    'components': [
      {
        'id': 'root_card',
        'component': 'TriageCard',
        'children': ['diff_view', 'reasoning_text'],
      },
      {
        'id': 'diff_view',
        'component': 'DiffBox',
        'properties': {
          'title': '定例ミーティング時間',
          'before': '2026-10-05 14:00',
          'after': '2026-10-05 16:30',
          'highlight': 'warning',
        },
      },
      {
        'id': 'reasoning_text',
        'component': 'Text',
        'properties': {'text': '参加者3名中2名が14:00に重複予定…', 'variant': 'caption'},
      },
    ],
    'actions': {
      'onSwipeRight': {
        'actionName': 'approve',
        'payload': {'decision': 'ACCEPT', 'newTime': '2026-10-05 16:30'},
      },
      'onSwipeLeft': {'actionName': 'reject', 'payload': {'decision': 'DECLINE'}},
      'inspectForm': [
        {
          'id': 'time_picker',
          'component': 'TimePicker',
          'properties': {'label': '別の時間を指定', 'default': '16:30'},
        },
      ],
    },
  };

  test('parses the reference payload (docs/protocol.md)', () {
    final task = TaskCard.fromJson(reference);
    expect(task.taskId, 'task_98234');
    expect(task.nonce, 'tok_sec_abc123');
    expect(task.confidence, 0.94);
    expect(
      task.bodyComponents.map((c) => c.id).toList(),
      ['diff_view', 'reasoning_text'],
    );
    expect(task.onSwipeRight?.actionName, 'approve');
    expect(task.onSwipeRight?.payload['newTime'], '2026-10-05 16:30');
    expect(task.inspectForm.single.component, 'TimePicker');
    expect(task.impact.isEmpty, isTrue);
    expect(riskLevel(task), RiskLevel.low);
  });

  test('survives schema breakage: unknown component, missing fields (FR-1.3)', () {
    final task = TaskCard.fromJson(<String, dynamic>{
      'components': [
        {'id': 'x', 'component': 'BrandNewWidget', 'properties': {'foo': 1}},
      ],
    });
    expect(task.taskId, isNotEmpty);
    expect(task.nonce, isEmpty);
    expect(task.summary, '(no summary)');
    expect(task.confidence, 0.5);
    expect(task.bodyComponents.single.component, 'BrandNewWidget');
    expect(task.inspectForm, isEmpty);
  });

  test('bodyComponents appends components missing from root children', () {
    final task = TaskCard.fromJson(<String, dynamic>{
      'components': [
        {'id': 'root', 'component': 'TriageCard', 'children': ['a']},
        {'id': 'a', 'component': 'Text', 'properties': {'text': 'a'}},
        {'id': 'b', 'component': 'DiffBox', 'properties': {}},
      ],
    });
    expect(task.bodyComponents.map((c) => c.id).toList(), ['a', 'b']);
  });

  test('toJson round-trips identity and actions', () {
    final task = TaskCard.fromJson(reference);
    final restored = TaskCard.fromJson(task.toJson());
    expect(restored.taskId, task.taskId);
    expect(restored.nonce, task.nonce);
    expect(restored.onSwipeRight?.actionName, 'approve');
    expect(restored.inspectForm.single.id, 'time_picker');
  });

  test('parses impact and swipe labels (I-202, I-130)', () {
    final task = TaskCard.fromJson(<String, dynamic>{
      ...reference,
      'impact': {
        'summary': 'UserA に返金します',
        'reversible': false,
        'cost': {'amount': 120, 'currency': 'USD'},
        'scope': 'Stripe',
      },
      'actions': {
        'onSwipeRight': {'actionName': 'approve', 'label': '返金する \$120'},
      },
    });
    expect(task.impact.summary, 'UserA に返金します');
    expect(task.impact.reversible, isFalse);
    expect(task.impact.amount, 120);
    expect(task.impact.currency, 'USD');
    expect(task.impact.scope, 'Stripe');
    expect(task.impact.isEmpty, isFalse);
    expect(task.onSwipeRight?.label, '返金する \$120');
    final restored = TaskCard.fromJson(task.toJson());
    expect(restored.impact.summary, 'UserA に返金します');
    expect(restored.onSwipeRight?.label, '返金する \$120');
  });

  test('impact defaults to empty and hides (old cards unchanged)', () {
    final task = TaskCard.fromJson(reference);
    expect(task.impact.isEmpty, isTrue);
    expect(task.onSwipeRight?.label, isNull);
    expect(task.toJson().containsKey('impact'), isFalse);
  });

  test('riskLevel tiers by severity, reversibility, and cost (I-102)', () {
    TaskCard card(Map<String, dynamic> overlay) =>
        TaskCard.fromJson(<String, dynamic>{...reference, ...overlay});
    expect(
      riskLevel(card(<String, dynamic>{
        'severity': 'critical',
        'impact': {'reversible': false},
      })),
      RiskLevel.critical,
    );
    expect(
      riskLevel(card(<String, dynamic>{
        'severity': 'warning',
        'impact': {
          'reversible': false,
          'cost': {'amount': 500, 'currency': 'USD'},
        },
      })),
      RiskLevel.high,
    );
    expect(
      riskLevel(card(<String, dynamic>{
        'severity': 'info',
        'impact': {
          'summary': 'x',
          'cost': {'amount': 5, 'currency': 'USD'},
        },
      })),
      RiskLevel.low,
    );
  });
}
