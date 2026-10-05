import 'package:flutter/material.dart';

import 'colors.dart';
import 'package:genui/genui.dart' show Surface;

import '../models/task_card.dart';
import 'genui_form.dart';
import 'widgets/component_renderer.dart';

/// Inspect & Modify (spec §3.3): bottom sheet with the card body plus a
/// dynamically rendered form from `actions.inspectForm`. Submitting
/// merges the form values over the swipe-right payload and sends them
/// as the approve decision.
Future<void> showInspectSheet(
  BuildContext context,
  TaskCard task,
  void Function(Map<String, dynamic> data) onApprove,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: PopColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => _InspectSheet(task: task, onApprove: onApprove),
  );
}

class _InspectSheet extends StatefulWidget {
  final TaskCard task;
  final void Function(Map<String, dynamic> data) onApprove;

  const _InspectSheet({required this.task, required this.onApprove});

  @override
  State<_InspectSheet> createState() => _InspectSheetState();
}

class _InspectSheetState extends State<_InspectSheet> {
  final Map<String, dynamic> _values = <String, dynamic>{};
  final Map<String, TextEditingController> _textControllers =
      <String, TextEditingController>{};
  late final GenUiFormAdapter _genui;

  @override
  void initState() {
    super.initState();
    _genui = GenUiFormAdapter();
    _genui.buildForm(widget.task.inspectForm);
  }

  @override
  void dispose() {
    _genui.dispose();
    for (final controller in _textControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  TextEditingController _controllerFor(CardComponent c) {
    return _textControllers.putIfAbsent(c.id, () {
      final initial = _values[c.id] as String? ?? '${c.properties['default'] ?? ''}';
      return TextEditingController(text: initial);
    });
  }

  void _submit() {
    for (final c in widget.task.inspectForm) {
      if (c.component == 'TextField') {
        final controller = _textControllers[c.id];
        final text = controller?.text.trim() ?? '';
        if (text.isNotEmpty) _values[c.id] = text;
      }
    }
    // genui-rendered fields contribute their data-model values; hand-rolled
    // state is already in `_values`. Form values win over the payload.
    _values.addAll(_genui.collectValues());
    final base = widget.task.onSwipeRight?.payload ?? const <String, dynamic>{};
    final data = <String, dynamic>{...base, ..._values};
    Navigator.of(context).pop();
    widget.onApprove(data);
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.55,
        minChildSize: 0.35,
        maxChildSize: 0.9,
        builder: (context, scrollController) => Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 10),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                children: [
                  Text(
                    task.summary,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  for (final component in task.bodyComponents)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: ComponentRenderer(
                        component: component,
                        onInspect: () {},
                      ),
                    ),
                  if (task.inspectForm.isNotEmpty) ...[
                    const Divider(height: 28),
                    Text(
                      '微調整',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                            color: Colors.white54,
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    for (final component in task.inspectForm)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: _formSlot(component),
                      ),
                  ],
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    icon: const Icon(Icons.check),
                    label: const Text('修正して承認'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                    ),
                    onPressed: _submit,
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('閉じる'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------
  // Form catalog v0 (docs/protocol.md)

  /// Renders a form component through genui when possible; anything the
  /// adapter does not handle (unknown types, malformed properties, failed
  /// surfaces) falls back to the hand-rolled widget below (FR-1.3).
  Widget _formSlot(CardComponent c) {
    if (_genui.handles(c) && !_genui.failedIds.contains(c.id)) {
      return Surface(surfaceContext: _genui.contextFor(c.id));
    }
    return _formComponent(c);
  }

  Widget _formComponent(CardComponent c) {
    switch (c.component) {
      case 'TimePicker':
        return _timePicker(c);
      case 'DatePicker':
        return _datePicker(c);
      case 'Slider':
        return _slider(c);
      case 'Segmented':
        return _segmented(c);
      case 'TextField':
        return _textField(c);
      default:
        return _unsupportedForm(c);
    }
  }

  Widget _timePicker(CardComponent c) {
    final initial = _parseTime('${c.properties['default'] ?? ''}');
    return _FormTile(
      label: '${c.properties['label'] ?? c.id}',
      trailing: (_values[c.id] as String?) ?? _formatTime(initial),
      onTap: () async {
        final picked = await showTimePicker(context: context, initialTime: initial);
        if (picked != null) {
          setState(() => _values[c.id] = _formatTime(picked));
        }
      },
    );
  }

  Widget _datePicker(CardComponent c) {
    final initialRaw = '${c.properties['default'] ?? ''}';
    final initial = DateTime.tryParse(initialRaw) ?? DateTime.now();
    return _FormTile(
      label: '${c.properties['label'] ?? c.id}',
      trailing: (_values[c.id] as String?) ??
          (initialRaw.isNotEmpty ? initialRaw.substring(0, initialRaw.length.clamp(0, 10)) : '未選択'),
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: initial,
          firstDate: initial.subtract(const Duration(days: 365)),
          lastDate: initial.add(const Duration(days: 365)),
        );
        if (picked != null) {
          setState(() => _values[c.id] = picked.toIso8601String().substring(0, 10));
        }
      },
    );
  }

  Widget _slider(CardComponent c) {
    final min = (c.properties['min'] as num?)?.toDouble() ?? 0;
    final max = (c.properties['max'] as num?)?.toDouble() ?? 100;
    final def = ((c.properties['default'] as num?)?.toDouble() ?? min)
        .clamp(min, max);
    final divisions = c.properties['divisions'] as int?;
    final value = ((c.properties['value'] as num?)?.toDouble() ?? def).clamp(min, max);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '${c.properties['label'] ?? c.id}',
              style: const TextStyle(fontSize: 13, color: Colors.white70),
            ),
            Text(
              (_values[c.id]?.toString() ?? value.toString()),
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white),
            ),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          onChanged: (v) => setState(() => _values[c.id] = v),
        ),
      ],
    );
  }

  Widget _segmented(CardComponent c) {
    final options =
        (c.properties['options'] as List? ?? <dynamic>[]).map((e) => '$e').toList();
    final selected = _values[c.id] as String? ??
        (c.properties['default'] != null
            ? '${c.properties['default']}'
            : (options.isNotEmpty ? options.first : ''));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${c.properties['label'] ?? c.id}',
          style: const TextStyle(fontSize: 13, color: Colors.white70),
        ),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: [
            for (final option in options) ButtonSegment(value: option, label: Text(option)),
          ],
          selected: options.contains(selected) ? <String>{selected} : <String>{},
          onSelectionChanged: (selection) {
            if (selection.isNotEmpty) {
              setState(() => _values[c.id] = selection.first);
            }
          },
        ),
      ],
    );
  }

  Widget _textField(CardComponent c) {
    return TextField(
      controller: _controllerFor(c),
      maxLines: c.properties['multiline'] == true ? 4 : 1,
      decoration: InputDecoration(
        labelText: '${c.properties['label'] ?? c.id}',
        border: const OutlineInputBorder(),
      ),
    );
  }

  Widget _unsupportedForm(CardComponent c) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
      ),
      child: Text(
        'Unsupported form component: ${c.component}',
        style: const TextStyle(fontSize: 12, color: Colors.orangeAccent),
      ),
    );
  }
}

TimeOfDay _parseTime(String raw) {
  final match = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(raw.trim());
  if (match == null) return const TimeOfDay(hour: 12, minute: 0);
  return TimeOfDay(
    hour: int.parse(match.group(1)!),
    minute: int.parse(match.group(2)!),
  );
}

String _formatTime(TimeOfDay t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

class _FormTile extends StatelessWidget {
  final String label;
  final String trailing;
  final VoidCallback onTap;

  const _FormTile({required this.label, required this.trailing, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: PopColors.borderColor),
          color: PopColors.surface2,
        ),
        child: Row(
          children: [
            Expanded(child: Text(label, style: const TextStyle(fontSize: 13, color: Colors.white70))),
            Text(
              trailing,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.expand_more, size: 18, color: Colors.white38),
          ],
        ),
      ),
    );
  }
}
