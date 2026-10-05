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

  test('parses the context block (裏面) and round-trips it', () {
    final task = TaskCard.fromJson(<String, dynamic>{
      ...reference,
      'context': {
        'requester': {'name': 'Bさん', 'onBehalfOf': 'リード'},
        'participants': [
          {'name': 'Aさん', 'status': 'busy 14:00'},
          'junk',
        ],
        'reasoning': '重複のため',
        'source': {'label': 'Gmail', 'url': 'javascript:alert(1)'},
      },
    });
    expect(task.context?.requesterName, 'Bさん');
    expect(task.context?.requesterOnBehalfOf, 'リード');
    expect(task.context?.participants.single.name, 'Aさん');
    expect(task.context?.reasoning, '重複のため');
    // javascript: URLs are dropped, label survives
    expect(task.context?.sourceLabel, 'Gmail');
    expect(task.context?.sourceUrl, isNull);

    final restored = TaskCard.fromJson(task.toJson());
    expect(restored.context?.requesterName, 'Bさん');
    expect(restored.context?.sourceUrl, isNull);
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

  test('defaults protocolVersion to 1 when absent and keeps explicit (I-606)', () {
    expect(TaskCard.fromJson(reference).protocolVersion, 1);
    expect(
      TaskCard.fromJson({...reference, 'protocolVersion': 1}).protocolVersion,
      1,
    );
    // malformed versions fall back to 1 instead of crashing
    expect(
      TaskCard.fromJson({...reference, 'protocolVersion': 'one'}).protocolVersion,
      1,
    );
  });

  test('parses grouping, decisionKind, editable and priority (I-201/I-206)', () {
    final task = TaskCard.fromJson(<String, dynamic>{
      ...reference,
      'groupKey': 'inbox_spam',
      'decisionKind': 'fill',
      'priority': 93.4,
      'revised': true,
      'editable': {
        'componentId': 'amount',
        'kind': 'number',
        'min': 0,
        'max': 120,
        'step': 5,
      },
    });
    expect(task.groupKey, 'inbox_spam');
    expect(task.decisionKind, 'fill');
    expect(task.priority, 93.4);
    expect(task.revised, isTrue);
    expect(task.editable?.componentId, 'amount');
    expect(task.editable?.kind, 'number');
    expect(task.editable?.max, 120);

    final restored = TaskCard.fromJson(task.toJson());
    expect(restored.groupKey, 'inbox_spam');
    expect(restored.decisionKind, 'fill');
    expect(restored.priority, 93.4);
    expect(restored.revised, isTrue);
    expect(restored.editable?.step, 5);
  });

  test('defaults decisionKind to approve and tolerates malformed additions', () {
    final task = TaskCard.fromJson(reference);
    expect(task.decisionKind, 'approve');
    expect(task.groupKey, isNull);
    expect(task.editable, isNull);
    expect(task.priority, isNull);
    expect(task.revised, isFalse);

    final broken = TaskCard.fromJson(<String, dynamic>{
      ...reference,
      'groupKey': 7,
      'decisionKind': '',
      'editable': 'nope',
      'priority': 'high',
      'revised': 'yes',
    });
    expect(broken.groupKey, isNull);
    expect(broken.decisionKind, 'approve');
    expect(broken.editable, isNull);
    expect(broken.priority, isNull);
    expect(broken.revised, isFalse);
  });

  test('parses swipe up/down, requiredApprovals, choices and delegatedTo (I-111/I-501/I-502)', () {
    final task = TaskCard.fromJson(<String, dynamic>{
      ...reference,
      'decisionKind': 'choose',
      'requiredApprovals': 2,
      'choices': [
        {'id': 'a', 'label': 'A'},
        {'id': 'b', 'label': 'B'},
        {'id': '', 'label': 'dropped'},
        'junk',
      ],
      'delegatedTo': 'alice',
      'actions': {
        ...reference['actions'] as Map<String, dynamic>,
        'onSwipeUp': {'actionName': 'pick_first'},
        'onSwipeDown': {'actionName': 'pick_second', 'label': 'Bにする'},
      },
    });
    expect(task.onSwipeUp?.actionName, 'pick_first');
    expect(task.onSwipeDown?.actionName, 'pick_second');
    expect(task.onSwipeDown?.label, 'Bにする');
    expect(task.requiredApprovals, 2);
    expect(task.choices.map((c) => c.id).toList(), ['a', 'b']);
    expect(task.delegatedTo, 'alice');

    final restored = TaskCard.fromJson(task.toJson());
    expect(restored.onSwipeUp?.actionName, 'pick_first');
    expect(restored.onSwipeDown?.actionName, 'pick_second');
    expect(restored.requiredApprovals, 2);
    expect(restored.choices.map((c) => c.label).toList(), ['A', 'B']);
    expect(restored.delegatedTo, 'alice');
  });

  test('defaults wave-2 fields and tolerates malformed ones', () {
    final task = TaskCard.fromJson(reference);
    expect(task.onSwipeUp, isNull);
    expect(task.onSwipeDown, isNull);
    expect(task.requiredApprovals, 1);
    expect(task.choices, isEmpty);
    expect(task.delegatedTo, isNull);

    final broken = TaskCard.fromJson(<String, dynamic>{
      ...reference,
      'requiredApprovals': 0,
      'choices': 'nope',
      'delegatedTo': 7,
    });
    expect(broken.requiredApprovals, 1);
    expect(broken.choices, isEmpty);
    expect(broken.delegatedTo, isNull);
  });
}
