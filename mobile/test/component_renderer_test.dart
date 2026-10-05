import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agentdesk_mobile/models/task_card.dart';
import 'package:agentdesk_mobile/ui/widgets/component_renderer.dart';

Widget _wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

void main() {
  testWidgets('renders DiffBox time chips (value-aware, spec §3.2)',
      (tester) async {
    await tester.pumpWidget(_wrap(
      const ComponentRenderer(
        component: CardComponent(
          id: 'd',
          component: 'DiffBox',
          properties: {'before': '14:00', 'after': '16:30', 'highlight': 'warning'},
        ),
      ),
    ));
    expect(find.text('14:00'), findsOneWidget);
    expect(find.text('16:30'), findsOneWidget);
    // clock chips instead of BEFORE/AFTER labels (value-aware diff)
    expect(find.byIcon(Icons.access_time), findsNWidgets(2));
    expect(find.text('BEFORE'), findsNothing);
  });

  testWidgets('DiffBox renders datetime calendar row, rows and inline diff',
      (tester) async {
    await tester.pumpWidget(_wrap(
      const ComponentRenderer(
        component: CardComponent(
          id: 'd2',
          component: 'DiffBox',
          properties: {
            'title': '金額',
            'before': '2026-10-05 14:00',
            'after': '2026-10-05 16:30',
            'rows': [
              {'label': '対象', 'before': 'UserA', 'after': 'UserB'},
            ],
            'inline': ' context\n-old line\n+new line',
          },
        ),
      ),
    ));
    expect(find.byIcon(Icons.event), findsOneWidget);
    expect(find.text('10月5日(月)'), findsOneWidget);
    expect(find.text('+2時間30分'), findsNWidgets(2)); // chips + bracket
    // day timeline: ghost slot + slid-in slot, both boundaries ticked
    expect(find.textContaining('14:00 – 15:00'), findsOneWidget);
    expect(find.textContaining('16:30 – 17:30'), findsOneWidget);
    expect(find.text('14:00'), findsNWidgets(2)); // chip + timeline tick
    expect(find.text('対象'), findsOneWidget);
    expect(find.text('UserA'), findsOneWidget);
    expect(find.text('→ UserB'), findsOneWidget);
    expect(find.text('+new line'), findsOneWidget);
    expect(find.text('-old line'), findsOneWidget);
  });

  testWidgets('unknown component falls back to a text card (FR-1.3)',
      (tester) async {
    await tester.pumpWidget(_wrap(
      const ComponentRenderer(
        component: CardComponent(
          id: 'x',
          component: 'BrandNewWidget',
          properties: {'foo': 'bar'},
        ),
      ),
    ));
    expect(find.textContaining('BrandNewWidget'), findsOneWidget);
    expect(find.textContaining('"foo": "bar"'), findsOneWidget);
  });

  testWidgets('external-origin text renders (NFR-2.2 quote block)',
      (tester) async {
    await tester.pumpWidget(_wrap(
      const ComponentRenderer(
        component: CardComponent(
          id: 't',
          component: 'Text',
          properties: {'text': 'from mail body', 'source': 'external'},
        ),
      ),
    ));
    expect(find.text('from mail body'), findsOneWidget);
  });

  testWidgets('chips without actionName request inspect; with actionName fire it',
      (tester) async {
    ActionBinding? fired;
    var inspectRequested = false;
    await tester.pumpWidget(_wrap(
      ComponentRenderer(
        component: const CardComponent(
          id: 'chips',
          component: 'Chips',
          properties: {
            'options': [
              {'label': 'このまま承認', 'actionName': 'approve'},
              {'label': '別の日程を提案'},
            ],
          },
        ),
        onAction: (binding) => fired = binding,
        onInspect: () => inspectRequested = true,
      ),
    ));
    await tester.tap(find.text('このまま承認'));
    expect(fired?.actionName, 'approve');
    await tester.tap(find.text('別の日程を提案'));
    expect(inspectRequested, isTrue);
  });
}
