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

  test('parses expiry fields and round-trips them (I-203)', () {
    final task = TaskCard.fromJson(<String, dynamic>{
      ...reference,
      'expiresAt': '2026-10-05T18:00:00Z',
      'onExpire': 'approve',
    });
    expect(task.expiresAt, DateTime.utc(2026, 10, 5, 18));
    expect(task.onExpire, 'approve');

    final restored = TaskCard.fromJson(task.toJson());
    expect(restored.expiresAt, task.expiresAt);
    expect(restored.onExpire, 'approve');
  });

  test('missing or malformed expiry fields stay null (I-203)', () {
    final task = TaskCard.fromJson(reference);
    expect(task.expiresAt, isNull);
    expect(task.onExpire, isNull);
    final broken = TaskCard.fromJson(<String, dynamic>{
      ...reference,
      'expiresAt': 12345,
      'onExpire': 9,
    });
    expect(broken.expiresAt, isNull);
    expect(broken.onExpire, isNull);
  });
}
