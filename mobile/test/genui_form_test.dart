import 'package:agentdesk_mobile/models/task_card.dart';
import 'package:agentdesk_mobile/ui/genui_form.dart';
import 'package:flutter_test/flutter_test.dart';

CardComponent comp(String id, String type,
        [Map<String, dynamic>? properties]) =>
    CardComponent(id: id, component: type, properties: properties ?? {});

List<CardComponent> sampleForm() => [
      comp('time', 'TimePicker', {'label': '別の時間を指定', 'default': '16:30'}),
      comp('date', 'DatePicker', {'label': '日付', 'default': '2026-10-05'}),
      comp('amount', 'Slider',
          {'label': '金額', 'min': 0, 'max': 1000, 'default': 120}),
      comp('choice', 'Segmented', {
        'label': '対応',
        'options': ['承認', '却下', '保留'],
      }),
      comp('note', 'TextField', {'label': 'メモ', 'multiline': true}),
      comp('mystery', 'WeirdWidget', {'label': '不明な型'}),
    ];

void main() {
  group('GenUiFormAdapter', () {
    test('handles the 5 protocol form types, not unknown ones', () {
      final adapter = GenUiFormAdapter();
      addTearDown(adapter.dispose);
      expect(adapter.handles(comp('a', 'TimePicker', {'default': '09:00'})),
          isTrue);
      expect(adapter.handles(comp('a', 'DatePicker')), isTrue);
      expect(adapter.handles(comp('a', 'Slider', {'min': 0, 'max': 1})),
          isTrue);
      expect(
          adapter.handles(comp('a', 'Segmented', {
            'options': ['x']
          })),
          isTrue);
      expect(adapter.handles(comp('a', 'TextField')), isTrue);
      expect(adapter.handles(comp('a', 'WeirdWidget')), isFalse);
      expect(adapter.handles(comp('a', 'Text', {'text': 'x'})), isFalse);
    });

    test('rejects malformed properties (fallback safety)', () {
      final adapter = GenUiFormAdapter();
      addTearDown(adapter.dispose);
      expect(adapter.handles(comp('a', 'Slider', {'min': 5, 'max': 5})),
          isFalse);
      expect(adapter.handles(comp('a', 'Slider', {'min': 9, 'max': 1})),
          isFalse);
      expect(adapter.handles(comp('a', 'Segmented', {'options': []})),
          isFalse);
      expect(adapter.handles(comp('a', 'Segmented', {})), isFalse);
      expect(adapter.handles(comp('a', 'TimePicker', {'default': 'nope'})),
          isFalse);
    });

    test('buildForm collects seeded defaults; unknown type omitted', () {
      final adapter = GenUiFormAdapter();
      addTearDown(adapter.dispose);
      adapter.buildForm(sampleForm());
      expect(adapter.failedIds, isEmpty);
      final values = adapter.collectValues();
      expect(values['time'], '16:30');
      expect(values['date'], '2026-10-05');
      expect(values['amount'], 120.0);
      expect(values['choice'], '承認');
      // Empty text field reports nothing so the swipe-right payload wins.
      expect(values.containsKey('note'), isFalse);
      expect(values.containsKey('mystery'), isFalse);
    });

    test('malformed component fails individually, rest still work', () {
      final adapter = GenUiFormAdapter();
      addTearDown(adapter.dispose);
      adapter.buildForm([
        comp('good', 'Slider', {'min': 0, 'max': 10, 'default': 3}),
        comp('bad', 'Slider', {'min': 10, 'max': 1}),
      ]);
      expect(adapter.handles(comp('bad', 'Slider', {'min': 10, 'max': 1})),
          isFalse);
      final values = adapter.collectValues();
      expect(values['good'], 3.0);
      expect(values.containsKey('bad'), isFalse);
    });

    test('dispose is idempotent; post-dispose collect is empty', () {
      final adapter = GenUiFormAdapter();
      adapter.buildForm(sampleForm());
      adapter.dispose();
      adapter.dispose();
      expect(adapter.collectValues(), isEmpty);
      expect(adapter.handles(comp('a', 'TextField')), isFalse);
    });
  });
}
