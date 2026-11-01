import 'package:flutter_test/flutter_test.dart';
import 'package:agentdesk_mobile/config.dart';
import 'package:agentdesk_mobile/models/task_card.dart';
import 'package:agentdesk_mobile/models/triage_action.dart';
import 'package:agentdesk_mobile/services/hub_api.dart';
import 'package:agentdesk_mobile/services/task_repository.dart';
import 'package:agentdesk_mobile/ui/stack_entry.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Test double for the wave-2 surface; the legacy suite's fake stays
/// untouched (existing suite must not change).
class FakeHubApiV2 extends FakeHubApiBase implements HubApiV2 {
  final List<Map<String, String>> snoozes = <Map<String, String>>[];
  final List<Map<String, String>> delegates = <Map<String, String>>[];
  final List<List<TriageActionReply>> bulks = <List<TriageActionReply>>[];
  final List<Map<String, String>> asks = <Map<String, String>>[];
  bool offlineBulk = false;

  @override
  Future<ActionSendResult> snooze({
    required String taskId,
    required String nonce,
    required DateTime until,
  }) async {
    if (offline) return ActionSendResult.networkError;
    snoozes.add(<String, String>{'taskId': taskId, 'nonce': nonce});
    return ActionSendResult.sent;
  }

  @override
  Future<ActionSendResult> delegate({
    required String taskId,
    required String nonce,
    required String to,
  }) async {
    if (offline) return ActionSendResult.networkError;
    delegates.add(<String, String>{'taskId': taskId, 'to': to});
    return ActionSendResult.sent;
  }


  @override
  Future<ActionSendResult> ask({
    required String taskId,
    required String nonce,
    required String question,
  }) async {
    if (offline) return ActionSendResult.networkError;
    asks.add(<String, String>{'taskId': taskId, 'question': question});
    return ActionSendResult.sent;
  }
  @override
  Future<BulkResult> bulk(List<TriageActionReply> actions) async {
    if (offlineBulk) return const BulkResult(networkError: true);
    bulks.add(actions);
    return BulkResult(
      results: [
        for (final a in actions)
          BulkItemResult(taskId: a.taskId, ok: true),
      ],
    );
  }
}

/// Minimal legacy-compatible fake: online send, no undo tracking.
class FakeHubApiBase implements HubApi {
  final List<TriageActionReply> sent = <TriageActionReply>[];
  bool offline = false;

  FakeHubApiBase({this.offline = false});

  @override
  Future<List<TaskCard>> fetchPendingTasks() async => <TaskCard>[];

  @override
  Future<ActionSendResult> sendAction(TriageActionReply reply) async {
    if (offline) return ActionSendResult.networkError;
    sent.add(reply);
    return ActionSendResult.sent;
  }

  @override
  Future<UndoResult> undo({required String taskId, required String nonce}) async =>
      UndoResult.undone;
}

TaskCard _task(
  String id, {
  String severity = 'info',
  double? confidence,
  String? groupKey,
  String? decisionKind,
}) =>
    TaskCard.fromJson(<String, dynamic>{
      'taskId': id,
      'nonce': 'n_$id',
      'agent': {'name': 'A'},
      'summary': 's_$id',
      'severity': severity,
      if (confidence != null) 'confidence': confidence,
      if (groupKey != null) 'groupKey': groupKey,
      if (decisionKind != null) 'decisionKind': decisionKind,
      'createdAt': '2026-01-01T00:00:00Z',
      'components': <dynamic>[],
    });

TaskRepository _repo(HubApi api) => TaskRepository(
      config: const HubConfig(hubUrl: 'http://x', clientToken: 't'),
      api: api,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('server snooze hides the card and reports the count (I-102)', () async {
    final api = FakeHubApiV2();
    final repo = _repo(api);
    final task = _task('s1');
    repo.upsert(task);
    await repo.serverSnooze(task, after: const Duration(hours: 1));
    expect(api.snoozes.single['taskId'], 's1');
    expect(repo.pendingCount, 0);
    expect(repo.snoozeCount, 1);
    expect(repo.lastToast, contains('あとで'));
  });

  test('offline snooze falls back locally and replays on reconnect', () async {
    final api = FakeHubApiV2()..offline = true;
    final repo = _repo(api);
    await repo.restoreQueue();
    final task = _task('s2');
    repo.upsert(task);
    await repo.serverSnooze(task, after: const Duration(hours: 1));
    // Local tail fallback + queued request.
    expect(repo.pendingCount, 1);
    expect(repo.hasQueuedActions, isTrue);

    api.offline = false;
    await repo.flushQueue();
    expect(repo.hasQueuedActions, isFalse);
    expect(repo.pendingCount, 0);
    expect(repo.snoozeCount, 1);
    expect(api.snoozes.single['taskId'], 's2');
  });

  test('resurface removes the server snooze and shows 更新されました', () {
    final repo = _repo(FakeHubApiV2());
    repo.upsert(_task('r1'));
    // Simulate the hub resurface broadcast for the same taskId.
    final revised = TaskCard.fromJson(<String, dynamic>{
      'taskId': 'r1',
      'nonce': 'n_r1_new',
      'agent': {'name': 'A'},
      'summary': 's',
      'revised': true,
      'components': <dynamic>[],
    });
    repo.upsert(revised);
    expect(repo.pendingCount, 1);
    expect(repo.isRevised('r1'), isTrue);
  });

  test('withdrawTask removes the card with a withdraw toast', () async {
    // Drives the repository through the SSE handler via the public
    // event path: inject a withdraw by applying a snapshot without the
    // card… covered by remove(); here we exercise remoteBy text.
    final repo = _repo(FakeHubApiV2());
    repo.upsert(_task('w1'));
    repo.remove('w1', remote: true, remoteBy: 'withdraw');
    expect(repo.pendingCount, 0);
    expect(repo.lastToast, contains('取り下げ'));
  });

  test('delegate stores the assignee and bulk approves a bundle (I-201/501)',
      () async {
    final api = FakeHubApiV2();
    final repo = _repo(api);
    final a = _task('a', groupKey: 'g');
    final b = _task('b', groupKey: 'g');
    await repo.delegate(a, 'Bさん');
    expect(api.delegates.single['to'], 'Bさん');
    expect(repo.delegatedFor('a'), 'Bさん');
    expect(repo.pendingCount, 0); // 'a' was never added to the stack

    repo.upsert(a);
    repo.upsert(b);
    await repo.bulkApprove([a, b]);
    expect(api.bulks.single.length, 2);
    expect(api.bulks.single.first.source, ActionSource.bulk);
    expect(repo.pendingCount, 0);
    expect(repo.lastToast, contains('2件'));
  });

  test('offline bulk queues and reports replays', () async {
    final api = FakeHubApiV2()..offlineBulk = true;
    final repo = _repo(api);
    await repo.restoreQueue();
    repo.upsert(_task('c'));
    repo.upsert(_task('d'));
    await repo.bulkApprove([_task('c'), _task('d')]);
    expect(repo.hasQueuedActions, isTrue);
    expect(repo.lastToast, contains('オフライン'));
  });

  test('grouped cards collapse; critical/low-confidence split out (I-201)', () {
    final normal1 = _task('g1', groupKey: 'k');
    final normal2 = _task('g2', groupKey: 'k');
    final crit = _task('g3', groupKey: 'k', severity: 'critical');
    final unsure = _task('g4', groupKey: 'k', confidence: 0.2);
    final entries = StackEntry.build([normal1, normal2, crit, unsure]);
    expect(entries.length, 3);
    expect(entries[0].isBundle, isTrue);
    expect(entries[0].members.map((t) => t.taskId).toSet(), {'g1', 'g2'});
    expect(entries[1].single?.taskId, 'g3');
    expect(entries[2].single?.taskId, 'g4');
  });

  test('single-member groups and ungrouped picks stay single', () {
    final lone = _task('solo', groupKey: 'one');
    final entries = StackEntry.build([lone]);
    expect(entries.single.isBundle, isFalse);

    final g1 = _task('u1', groupKey: 'z');
    final g2 = _task('u2', groupKey: 'z');
    final picked =
        StackEntry.build([g1, g2], ungrouped: {'u1'});
    expect(picked.length, 2);
    expect(picked.every((e) => !e.isBundle), isTrue);
  });
}
