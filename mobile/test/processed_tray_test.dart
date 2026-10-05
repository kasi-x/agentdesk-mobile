import 'package:flutter_test/flutter_test.dart';
import 'package:agentdesk_mobile/config.dart';
import 'package:agentdesk_mobile/models/task_card.dart';
import 'package:agentdesk_mobile/models/triage_action.dart';
import 'package:agentdesk_mobile/services/hub_api.dart';
import 'package:agentdesk_mobile/services/task_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Processed-tray recording (I-120/I-512). Repo-level only: no widget pump
/// needed — the tray widgets read [TaskRepository.processed].
class TrayFakeApi implements HubApi {
  final bool failWithNetwork;
  UndoResult undoResult = UndoResult.undone;

  TrayFakeApi({this.failWithNetwork = false});

  @override
  Future<List<TaskCard>> fetchPendingTasks() async => <TaskCard>[];

  @override
  Future<ActionSendResult> sendAction(TriageActionReply reply) async =>
      failWithNetwork
          ? ActionSendResult.networkError
          : ActionSendResult.sent;

  @override
  Future<UndoResult> undo(
          {required String taskId, required String nonce}) async =>
      undoResult;
}

TaskCard _task(String id, {String agent = 'A', String summary = 's'}) =>
    TaskCard.fromJson(<String, dynamic>{
      'taskId': id,
      'nonce': 'n_$id',
      'agent': {'name': agent},
      'summary': summary,
      'components': <dynamic>[],
    });

TaskRepository _repo(HubApi api) => TaskRepository(
      config: const HubConfig(hubUrl: 'http://x', clientToken: 't'),
      api: api,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('local triage records a user tray entry with task metadata',
      () async {
    final repo = _repo(TrayFakeApi());
    await repo.restoreQueue();
    final task = _task('t1', agent: 'Cal', summary: 'do thing');
    repo.upsert(task);

    await repo.triage(
      task,
      actionName: 'approve',
      source: ActionSource.swipeGesture,
    );

    expect(repo.processed, hasLength(1));
    final entry = repo.processed.single;
    expect(entry.taskId, 't1');
    expect(entry.summary, 'do thing');
    expect(entry.actionName, 'approve');
    expect(entry.source, 'user');
    expect(entry.agentName, 'Cal');
    expect(repo.processedTodayCount, 1);
  });

  test('local snooze-class triage records a snooze source entry', () async {
    final repo = _repo(TrayFakeApi());
    await repo.restoreQueue();
    final task = _task('s1');
    repo.upsert(task);

    await repo.triage(
      task,
      actionName: 'snooze',
      source: ActionSource.snooze,
    );

    expect(repo.processed.single.source, 'snooze');
  });

  test('remote dismiss classifies by marker: withdraw / expire / other',
      () async {
    final repo = _repo(TrayFakeApi());
    repo.upsert(_task('w'));
    repo.upsert(_task('e'));
    repo.upsert(_task('o'));

    repo.remove('w', remote: true, remoteBy: 'withdraw');
    repo.remove('e', remote: true, remoteBy: 'on_expire');
    repo.remove('o', remote: true, remoteBy: 'swipe_gesture');

    final byId = {for (final e in repo.processed) e.taskId: e};
    expect(byId['w']!.source, 'withdraw');
    expect(byId['w']!.actionName, 'withdraw');
    expect(byId['e']!.source, 'expire');
    expect(byId['e']!.actionName, 'expire');
    expect(byId['o']!.source, 'other');
    expect(byId['o']!.actionName, 'other');
  });

  test('auto_rule dismiss records an auto approve entry', () async {
    final repo = _repo(TrayFakeApi());
    repo.upsert(_task('a1'));

    repo.remove('a1', remote: true, remoteBy: 'auto_rule');

    expect(repo.processed.single.source, 'auto');
    expect(repo.processed.single.actionName, 'approve');
  });

  test('own-decision echo does not double-record the tray entry', () async {
    final repo = _repo(TrayFakeApi());
    await repo.restoreQueue();
    final task = _task('mine');
    repo.upsert(task);
    await repo.triage(
      task,
      actionName: 'approve',
      source: ActionSource.swipeGesture,
    );
    expect(repo.processed, hasLength(1));

    // Hub echo of our own decision (swallowed, no toast, no tray dup).
    repo.remove('mine', remote: true, remoteBy: ActionSource.swipeGesture);
    expect(repo.processed, hasLength(1));
  });

  test('undo removes the taskId latest tray entry', () async {
    final api = TrayFakeApi();
    final repo = _repo(api);
    await repo.restoreQueue();
    final task = _task('u1');
    repo.upsert(task);
    await repo.triage(
      task,
      actionName: 'approve',
      source: ActionSource.webUi,
    );
    expect(repo.processed, hasLength(1));

    await repo.undo('u1');
    expect(repo.processed, isEmpty);
  });

  test('history caps at 100 and persists across restore', () async {
    final repo = _repo(TrayFakeApi());
    await repo.restoreQueue();
    for (var i = 0; i < 105; i++) {
      repo.recordProcessed(ProcessedEntry(
        taskId: 't$i',
        summary: 's$i',
        actionName: 'approve',
        source: 'user',
        at: DateTime.now(),
        agentName: 'A',
      ));
    }
    expect(repo.processed, hasLength(100));
    // Newest first: t104 head, t5 tail (t0..t4 evicted).
    expect(repo.processed.first.taskId, 't104');
    expect(repo.processed.last.taskId, 't5');

    final repo2 = _repo(TrayFakeApi());
    await repo2.restoreQueue();
    expect(repo2.processed, hasLength(100));
    expect(repo2.processed.first.taskId, 't104');
  });
}
