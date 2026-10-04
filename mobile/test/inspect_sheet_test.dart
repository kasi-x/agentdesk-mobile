import 'package:agentdesk_mobile/models/task_card.dart';
import 'package:agentdesk_mobile/ui/inspect_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

TaskCard sampleTask() => TaskCard(
      taskId: 'task_test_1',
      nonce: 'tok_test',
      agent: const AgentInfo(name: 'Test Agent'),
      confidence: 0.8,
      confidenceReasons: const [],
      severity: 'info',
      summary: 'テストタスク',
      surfaceId: null,
      createdAt: DateTime(2026, 10, 4),
      replyUrl: null,
      components: const [],
      onSwipeRight: const ActionBinding(
        actionName: 'approve',
        payload: {'decision': 'ACCEPT', 'kept': 'payload-wins-unless-overridden'},
      ),
      onSwipeLeft: null,
      inspectForm: [
        const CardComponent(
          id: 'time',
          component: 'TimePicker',
          properties: {'label': '別の時間を指定', 'default': '16:30'},
        ),
        const CardComponent(
          id: 'amount',
          component: 'Slider',
          properties: {'label': '金額', 'min': 0, 'max': 1000, 'default': 120},
        ),
        const CardComponent(
          id: 'choice',
          component: 'Segmented',
          properties: {
            'label': '対応',
            'options': ['承認', '却下'],
          },
        ),
        const CardComponent(
          id: 'note',
          component: 'TextField',
          properties: {'label': 'メモ'},
        ),
        const CardComponent(
          id: 'mystery',
          component: 'WeirdWidget',
          properties: {'label': '不明な型'},
        ),
      ],
    );

void main() {
  testWidgets('inspect sheet submits genui values merged over payload',
      (tester) async {
    Map<String, dynamic>? submitted;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showInspectSheet(
              context,
              sampleTask(),
              (data) => submitted = data,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Sheet rendered: summary + fallback row for the unknown type.
    expect(find.text('テストタスク'), findsWidgets);
    await tester.scrollUntilVisible(
      find.textContaining('Unsupported form component'),
      200,
    );
    expect(find.textContaining('Unsupported form component'), findsOneWidget);

    // The submit button may be below the fold; drag the sheet list instead
    // of scrollUntilVisible (the label text matches outside the sheet too).
    await tester.drag(find.byType(ListView).first, const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.tap(find.text('修正して承認').last);
    await tester.pumpAndSettle();

    expect(submitted, isNotNull);
    // Swipe-right payload preserved underneath…
    expect(submitted!['decision'], 'ACCEPT');
    expect(submitted!['kept'], 'payload-wins-unless-overridden');
    // …with seeded genui form values on top.
    expect(submitted!['time'], '16:30');
    expect(submitted!['amount'], 120.0);
    expect(submitted!['choice'], '承認');
    // Empty text field must not clobber anything.
    expect(submitted!.containsKey('note'), isFalse);
    expect(submitted!.containsKey('mystery'), isFalse);
  });
}
