import 'package:flutter_test/flutter_test.dart';
import 'package:agentdesk_mobile/config.dart';
import 'package:agentdesk_mobile/models/task_card.dart';
import 'package:agentdesk_mobile/models/triage_action.dart';
import 'package:agentdesk_mobile/services/hub_api.dart';
import 'package:agentdesk_mobile/services/task_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeHubApi implements HubApi {
  final List<TriageActionReply> sent = <TriageActionReply>[];

  @override
  Future<List<TaskCard>> fetchPendingTasks() async => <TaskCard>[];

  @override
  Future<ActionSendResult> sendAction(TriageActionReply reply) async {
    sent.add(reply);
    return ActionSendResult.sent;
  }

  @override
  Future<UndoResult> undo({required String taskId, required String nonce}) async =>
      UndoResult.undone;
}

TaskCard _chooseCard() => TaskCard.fromJson(<String, dynamic>{
      'taskId': 'choose_1',
      'nonce': 'n_choose_1',
      'agent': {'name': 'A'},
      'summary': 'どっちにする？',
      'decisionKind': 'choose',
      'choices': [
        {'id': 'a', 'label': '案A'},
        {'id': 'b', 'label': '案B'},
      ],
      'actions': {
        'onSwipeUp': {'actionName': 'approve', 'label': 'Aにする'},
        'onSwipeDown': {'actionName': 'approve', 'label': 'Bにする'},
        'onSwipeLeft': {'actionName': 'reject', 'label': '却下'},
      },
      'createdAt': '2026-01-01T00:00:00Z',
      'components': <dynamic>[],
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('choose up/down send the choice id as data.choice (I-111)', () async {
    final api = FakeHubApi();
    final repo = TaskRepository(
      config: const HubConfig(hubUrl: 'http://x', clientToken: 't'),
      api: api,
    );
    final task = _chooseCard();
    repo.upsert(task);
    expect(task.decisionKind, 'choose');
    expect(task.choices.map((c) => c.id).toList(), ['a', 'b']);

    await repo.triage(
      task,
      actionName: task.onSwipeUp?.actionName ?? 'approve',
      data: <String, dynamic>{'choice': task.choices[0].id},
      source: ActionSource.swipeGesture,
    );
    expect(api.sent.single.data['choice'], 'a');
    expect(repo.pendingCount, 0);
  });

  test('row selection and edited values ride approve replies (I-112/114)',
      () async {
    final api = FakeHubApi();
    final repo = TaskRepository(
      config: const HubConfig(hubUrl: 'http://x', clientToken: 't'),
      api: api,
    );
    final task = TaskCard.fromJson(<String, dynamic>{
      'taskId': 'edit_1',
      'nonce': 'n_edit_1',
      'agent': {'name': 'A'},
      'summary': '調整あり',
      'createdAt': '2026-01-01T00:00:00Z',
      'components': <dynamic>[
        {
          'id': 'diff1',
          'component': 'DiffBox',
          'properties': {
            'title': '明細',
            'before': '¥100',
            'after': '¥120',
            'selectable': true,
            'rows': [
              {'id': 'row_a', 'before': '¥10', 'after': '¥12'},
              {'id': 'row_b', 'before': '¥20', 'after': '¥22'},
            ],
          },
        },
      ],
      'actions': {
        'onSwipeRight': {'actionName': 'approve'},
      },
    });
    repo.upsert(task);
    repo.setRowSelection('edit_1', ['row_b']);
    repo.setEditedValue('edit_1', 'diff1', 123.0);
    await repo.triage(
      task,
      actionName: 'approve',
      source: ActionSource.swipeGesture,
    );
    expect(api.sent.single.data['acceptedRows'], ['row_b']);
    expect(api.sent.single.data['edited'],
        {'componentId': 'diff1', 'value': 123.0});
    // consumed after triage
    expect(repo.rowSelection('edit_1'), isEmpty);
  });

  test('pause state lands in the repository (wave-2 pauseState)', () {
    final repo = TaskRepository(
      config: const HubConfig(hubUrl: 'http://x', clientToken: 't'),
      api: FakeHubApi(),
    );
    expect(repo.paused, isFalse);
    repo.applySnapshotEnvelope(tasks: const <TaskCard>[], paused: true);
    expect(repo.paused, isTrue);
  });
}
