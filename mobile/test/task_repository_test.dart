import 'package:flutter_test/flutter_test.dart';
import 'package:agentdesk_mobile/config.dart';
import 'package:agentdesk_mobile/models/task_card.dart';
import 'package:agentdesk_mobile/models/triage_action.dart';
import 'package:agentdesk_mobile/services/hub_api.dart';
import 'package:agentdesk_mobile/services/task_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeHubApi implements HubApi {
  final List<TriageActionReply> sent = <TriageActionReply>[];
  final bool failWithNetwork;

  FakeHubApi({this.failWithNetwork = false});

  @override
  Future<List<TaskCard>> fetchPendingTasks() async => <TaskCard>[];

  @override
  Future<ActionSendResult> sendAction(TriageActionReply reply) async {
    if (failWithNetwork) return ActionSendResult.networkError;
    sent.add(reply);
    return ActionSendResult.sent;
  }

  UndoResult undoResult = UndoResult.undone;
  final List<String> undos = <String>[];

  @override
  Future<UndoResult> undo({required String taskId, required String nonce}) async {
    undos.add(taskId);
    return undoResult;
  }
}

TaskCard _task(String id, {String? createdAt}) => TaskCard.fromJson(
      <String, dynamic>{
        'taskId': id,
        'nonce': 'n_$id',
        'agent': {'name': 'A'},
        'summary': 's',
        if (createdAt != null) 'createdAt': createdAt,
        'components': <dynamic>[],
      },
    );

TaskRepository _repo(HubApi api) {
  final repo = TaskRepository(
    config: const HubConfig(hubUrl: 'http://x', clientToken: 't'),
    api: api,
  );
  return repo;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('triage removes the card optimistically and delivers the reply (FR-2.1)',
      () async {
    final api = FakeHubApi();
    final repo = _repo(api);
    await repo.restoreQueue();
    final task = _task('a');
    repo.upsert(task);
    expect(repo.pendingCount, 1);

    await repo.triage(
      task,
      actionName: 'approve',
      source: ActionSource.swipeGesture,
    );
    expect(repo.pendingCount, 0);
    expect(api.sent.single.taskId, 'a');
    expect(api.sent.single.nonce, 'n_a');
    expect(api.sent.single.source, ActionSource.swipeGesture);
  });

  test('network failure persists the reply; a fresh session flushes it (FR-2.3)',
      () async {
    final offline = _repo(FakeHubApi(failWithNetwork: true));
    await offline.restoreQueue();
    final task = _task('q1');
    offline.upsert(task);
    await offline.triage(
      task,
      actionName: 'approve',
      source: ActionSource.swipeGesture,
    );
    expect(offline.hasQueuedActions, isTrue);
    expect(offline.pendingCount, 0);

    // "app restart": new repository picks the queue up from storage
    final healthy = FakeHubApi();
    final repo2 = _repo(healthy);
    await repo2.restoreQueue();
    expect(repo2.hasQueuedActions, isTrue);
    await repo2.flushQueue();
    expect(healthy.sent.single.taskId, 'q1');
    expect(repo2.hasQueuedActions, isFalse);
  });

  test('snapshot reconciliation keeps snoozed cards at the tail', () {
    final repo = _repo(FakeHubApi());
    repo.upsert(_task('a'));
    repo.upsert(_task('b'));
    repo.snooze('a');
    repo.applySnapshot([
      _task('a', createdAt: '2026-01-01T00:00:00Z'),
      _task('b', createdAt: '2026-01-02T00:00:00Z'),
    ]);
    expect(repo.stack.map((t) => t.taskId).toList(), ['b', 'a']);
  });

  test('snapshot excludes tasks waiting in the offline queue', () async {
    final offline = _repo(FakeHubApi(failWithNetwork: true));
    await offline.restoreQueue();
    final task = _task('queued');
    offline.upsert(task);
    await offline.triage(task, actionName: 'approve', source: ActionSource.webUi);

    offline.applySnapshot([_task('queued'), _task('fresh')]);
    expect(
      offline.stack.map((t) => t.taskId).toList(),
      ['fresh'],
    );
  });

  test('remote dismissal removes the card and leaves a toast (FR-3.2)', () {
    final repo = _repo(FakeHubApi());
    repo.upsert(_task('r1'));
    expect(repo.pendingCount, 1);
    repo.remove('r1', remote: true);
    expect(repo.pendingCount, 0);
    expect(repo.lastToast, contains('別のデバイスで処理されました'));
  });

  test('undo after a sent triage calls the hub undo endpoint (I-104)',
      () async {
    final api = FakeHubApi();
    final repo = _repo(api);
    await repo.restoreQueue();
    final task = _task('u1');
    repo.upsert(task);
    await repo.triage(task, actionName: 'approve', source: ActionSource.webUi);
    expect(repo.pendingCount, 0);

    await repo.undo('u1');
    expect(api.undos, ['u1']);
    expect(repo.lastToast, '元に戻しました');
    // The card itself is restored by the SSE re-broadcast / next snapshot,
    // not by the repository fabricating one.
    expect(repo.pendingCount, 0);
  });

  test('undo a queued offline triage restores the card locally (I-104)',
      () async {
    final api = FakeHubApi(failWithNetwork: true);
    final repo = _repo(api);
    await repo.restoreQueue();
    final task = _task('u2');
    repo.upsert(task);
    await repo.triage(task, actionName: 'approve', source: ActionSource.webUi);
    expect(repo.hasQueuedActions, isTrue);
    expect(repo.pendingCount, 0);

    await repo.undo('u2');
    expect(repo.hasQueuedActions, isFalse);
    expect(api.undos, isEmpty); // never reached the hub
    expect(repo.pendingCount, 1);
    expect(repo.stack.single.taskId, 'u2');
  });

  test('undo for an unknown task reports failure and keeps state', () async {
    final repo = _repo(FakeHubApi());
    await repo.undo('never-triaged');
    expect(repo.lastToast, contains('元に戻せません'));
  });

  test('re-broadcast (escalate) replaces the held card in place (I-203)', () {
    final repo = _repo(FakeHubApi());
    repo.upsert(_task('e1'));
    repo.upsert(_task('e2'));
    final escalated = TaskCard.fromJson(<String, dynamic>{
      'taskId': 'e2',
      'nonce': 'n_e2_rotated',
      'agent': {'name': 'A'},
      'summary': 's',
      'severity': 'critical',
      'components': <dynamic>[],
    });
    repo.upsert(escalated);
    expect(repo.pendingCount, 2);
    expect(repo.stack.first.taskId, 'e2'); // position kept (top)
    expect(repo.stack.first.nonce, 'n_e2_rotated');
    expect(repo.stack.first.severity, 'critical');
    expect(repo.stack[1].taskId, 'e1');
  });

  test('remote dismissal by on_expire says the hub auto-processed (I-203)',
      () {
    final repo = _repo(FakeHubApi());
    repo.upsert(_task('x1'));
    repo.remove('x1', remote: true, remoteBy: 'on_expire');
    expect(repo.pendingCount, 0);
    expect(repo.lastToast, contains('期限のため自動処理されました'));
  });
}
