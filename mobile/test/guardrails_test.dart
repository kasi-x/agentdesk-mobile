import 'package:agentdesk_mobile/config.dart';
import 'package:agentdesk_mobile/models/task_card.dart';
import 'package:agentdesk_mobile/models/triage_action.dart';
import 'package:agentdesk_mobile/services/hub_api.dart';
import 'package:agentdesk_mobile/services/task_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:agentdesk_mobile/ui/guardrails_screen.dart';
import 'package:agentdesk_mobile/ui/widgets/component_renderer.dart';

class _RulesFake extends FakeRulesBase {
  _RulesFake(this.rules, {this.supportsSimulate = true});

  List<AutoApprovalRule> rules;
  final bool supportsSimulate;
  List<AutoApprovalRule>? saved;
  int simulateCalls = 0;

  @override
  Future<List<AutoApprovalRule>?> fetchRules() async =>
      List<AutoApprovalRule>.of(rules);

  @override
  Future<bool> saveRules(List<AutoApprovalRule> next) async {
    saved = next;
    return true;
  }

  @override
  Future<SimulateResult?> simulateRules({
    Map<String, dynamic>? match,
    String? action,
  }) async {
    simulateCalls++;
    if (!supportsSimulate) return null;
    return const SimulateResult(
        sampleSize: 100, autoApprove: 20, autoReject: 5, hitl: 75);
  }

  @override
  Future<AttachmentRef?> uploadAttachment({
    required String kind,
    required String contentType,
    required String dataBase64,
  }) async {
    // Same guards as the real HttpHubApi: bad args surface as null.
    if (kind != 'audio' && kind != 'image') return null;
    if (contentType.isEmpty || dataBase64.isEmpty) return null;
    return const AttachmentRef(id: 'att_1', url: '/api/v1/attachments/att_1');
  }
}

class FakeRulesBase implements HubApi, HubRulesApi, HubGuardrailsApi {
  @override
  Future<List<TaskCard>> fetchPendingTasks() async => <TaskCard>[];

  @override
  Future<ActionSendResult> sendAction(TriageActionReply reply) async =>
      ActionSendResult.sent;

  @override
  Future<UndoResult> undo(
          {required String taskId, required String nonce}) async =>
      UndoResult.undone;

  @override
  Future<List<AutoApprovalRule>?> fetchRules() async => <AutoApprovalRule>[];

  @override
  Future<bool> saveRules(List<AutoApprovalRule> rules) async => true;

  @override
  Future<SimulateResult?> simulateRules({
    Map<String, dynamic>? match,
    String? action,
  }) async =>
      null;

  @override
  Future<AttachmentRef?> uploadAttachment({
    required String kind,
    required String contentType,
    required String dataBase64,
  }) async {
    // Mirror the real impl's guards: invalid args surface as null so
    // callers keep the field empty instead of sending a dangling ref.
    if (kind != 'audio' && kind != 'image') return null;
    if (contentType.isEmpty || dataBase64.isEmpty) return null;
    return const AttachmentRef(id: 'att_1', url: '/api/v1/attachments/att_1');
  }
}

TaskRepository _repo(HubApi api) => TaskRepository(
      config: const HubConfig(hubUrl: 'http://x', clientToken: 't'),
      api: api,
    );

TaskCard _task(String id) => TaskCard.fromJson(<String, dynamic>{
      'taskId': id,
      'nonce': 'n_$id',
      'agent': {'name': 'A'},
      'summary': 's',
      'components': <dynamic>[],
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('AutoApprovalRule contract (I-1002)', () {
    test('parses action/source/minConfidence; tolerates old hubs', () {
      final rule = AutoApprovalRule.fromJson(<String, dynamic>{
        'id': 'r1',
        'action': 'reject',
        'source': 'learned',
        'match': <String, dynamic>{
          'agent': 'Cal',
          'severity': ['info'],
          'minConfidence': 0.7,
          'maxCost': 50,
        },
        'enabled': true,
      });
      expect(rule.action, 'reject');
      expect(rule.source, 'learned');
      expect(rule.minConfidence, 0.7);

      final legacy = AutoApprovalRule.fromJson(<String, dynamic>{
        'id': 'r0',
        'match': <String, dynamic>{},
        'enabled': true,
      });
      expect(legacy.action, 'approve');
      expect(legacy.source, isNull);
      expect(legacy.minConfidence, isNull);

      final weird = AutoApprovalRule.fromJson(<String, dynamic>{
        'id': 'r2',
        'action': 'explode',
        'match': <String, dynamic>{'minConfidence': 9},
        'enabled': true,
      });
      expect(weird.action, 'approve');
      expect(weird.minConfidence, 1.0);
    });

    test('round-trips new fields through toJson', () {
      final rule = AutoApprovalRule.fromJson(<String, dynamic>{
        'id': 'r1',
        'action': 'reject',
        'source': 'learned',
        'match': <String, dynamic>{'minConfidence': 0.5},
        'enabled': false,
      });
      final json = rule.toJson();
      expect(json['action'], 'reject');
      expect(json['source'], 'learned');
      expect((json['match'] as Map)['minConfidence'], 0.5);
    });
  });

  group('learnRule threading (I-1003)', () {
    test('deep-swipe flag survives reply serialization + queue', () async {
      final api = _SendCaptureFake();
      final repo = _repo(api);
      await repo.restoreQueue();
      final task = _task('learn1');
      repo.upsert(task);
      await repo.triage(task,
          actionName: 'approve',
          source: ActionSource.twoStageSwipe,
          learnRule: true);
      expect(api.sent.single.learnRule, isTrue);
      expect(api.sent.single.toJson()['learnRule'], true);

      final plain = TriageActionReply(
        taskId: 'x',
        nonce: 'n',
        actionName: 'approve',
        timestamp: DateTime.now().toUtc(),
        source: ActionSource.swipeGesture,
      );
      expect(plain.toJson().containsKey('learnRule'), isFalse);
      expect(
          TriageActionReply.fromJson(plain.toJson()).learnRule, isFalse);
    });

    test('queued offline reply keeps learnRule across restart', () async {
      final offline = _SendCaptureFake(failWithNetwork: true);
      final repo = _repo(offline);
      await repo.restoreQueue();
      final task = _task('q-learn');
      repo.upsert(task);
      await repo.triage(task,
          actionName: 'approve',
          source: ActionSource.twoStageSwipe,
          learnRule: true);
      expect(repo.hasQueuedActions, isTrue);

      final healthy = _SendCaptureFake();
      final repo2 = TaskRepository(
        config: const HubConfig(hubUrl: 'http://x', clientToken: 't'),
        api: healthy,
      );
      await repo2.restoreQueue();
      await repo2.flushQueue();
      expect(healthy.sent.single.learnRule, isTrue);
    });
  });

  group('GuardrailsScreen (I-1002)', () {
    testWidgets('lists rules with action + learned tag + toggle + delete',
        (tester) async {
      final fake = _RulesFake([
        const AutoApprovalRule(
            id: 'r1',
            action: 'approve',
            agent: 'Cal',
            minConfidence: 0.7,
            enabled: true),
        const AutoApprovalRule(
            id: 'r2',
            action: 'reject',
            source: 'learned',
            severity: ['critical'],
            enabled: false),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<TaskRepository>.value(
            value: _repo(fake),
            child: const GuardrailsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('approve'), findsOneWidget);
      expect(find.text('reject'), findsOneWidget);
      expect(find.text('learned'), findsOneWidget);
      expect(find.textContaining('confidence ≥ 0.70'), findsOneWidget);

      // Toggle r2 on.
      final switches =
          tester.widgetList<Switch>(find.byType(Switch)).toList();
      expect(switches.length, 2);
      await tester.tap(find.byWidget(switches.last));
      await tester.pump();
      expect(fake.rules, hasLength(2)); // local-only until save

      // Save persists the whole list via PUT shape.
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(fake.saved, isNotNull);
      expect(fake.saved!.length, 2);
      expect(fake.saved!.last.enabled, isTrue);
    });

    testWidgets('editor shows minConfidence + preview bar + old-hub hides it',
        (tester) async {
      final fake = _RulesFake(const <AutoApprovalRule>[]);
      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<TaskRepository>.value(
            value: _repo(fake),
            child: const GuardrailsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      expect(find.text('信頼度の下限（minConfidence）'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      // Preview rendered from the fake simulate surface.
      expect(find.textContaining('自動承認 20'), findsOneWidget);
      expect(find.textContaining('n=100'), findsOneWidget);
    });

    testWidgets('old hub without simulate hides preview, still editable',
        (tester) async {
      final fake =
          _RulesFake(const <AutoApprovalRule>[], supportsSimulate: false);
      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<TaskRepository>.value(
            value: _repo(fake),
            child: const GuardrailsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('プレビュー'), findsNothing);
      expect(find.text('ルールを追加'), findsOneWidget);
    });
  });

  group('capture components (I-1001)', () {
    testWidgets('AudioCapture/ ImageCapture render tolerant body tiles',
        (tester) async {
      Future<void> pumpTile(String kind) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ComponentRenderer(
                component: CardComponent(
                    id: 'c', component: kind, properties: const {'label': 'L'}),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await pumpTile('AudioCapture');
      expect(find.textContaining('詳細から追加'), findsOneWidget);
      await pumpTile('ImageCapture');
      expect(find.textContaining('詳細から追加'), findsOneWidget);
      await pumpTile('AudioInput');
      expect(find.textContaining('詳細から追加'), findsOneWidget);
      await pumpTile('ImagePicker');
      expect(find.textContaining('詳細から追加'), findsOneWidget);
      // Unknown kinds keep the text fallback (FR-1.3).
      await pumpTile('Hologram');
      expect(find.textContaining('Unsupported component'), findsOneWidget);
    });

    test('uploadAttachment validates args and surfaces null on error', () async {
      final fake = _RulesFake(const <AutoApprovalRule>[]);
      expect(
          await fake.uploadAttachment(
              kind: 'video', contentType: 'video/mp4', dataBase64: 'xx'),
          isNull);
      expect(
          await fake.uploadAttachment(
              kind: 'audio', contentType: '', dataBase64: 'xx'),
          isNull);
      expect(
          await fake.uploadAttachment(
              kind: 'image',
              contentType: 'image/jpeg',
              dataBase64: 'aGVsbG8='),
          isNotNull);
    });
  });
}

class _SendCaptureFake extends FakeRulesBase {
  _SendCaptureFake({this.failWithNetwork = false});

  final bool failWithNetwork;
  final List<TriageActionReply> sent = <TriageActionReply>[];

  @override
  Future<ActionSendResult> sendAction(TriageActionReply reply) async {
    if (failWithNetwork) return ActionSendResult.networkError;
    sent.add(reply);
    return ActionSendResult.sent;
  }
}
