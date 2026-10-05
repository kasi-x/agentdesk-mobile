import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/task_card.dart';
import '../colors.dart';

/// Inline value editor for the component named by `task.editable`
/// (I-114), rendered directly under that component on the card front.
/// Number kind → stepper or slider; datetime kind → ±time buttons stepping
/// `step` minutes (default 15). Approving sends
/// `data.edited={componentId,value}`; rejected/ignored edits never leave
/// the device.
class ValueEditor extends StatelessWidget {
  final EditableHint hint;
  final Map<String, dynamic> properties;

  /// Current edited value, or null while the user has not touched it.
  final Object? value;

  final void Function(Object value) onChanged;

  const ValueEditor({
    super.key,
    required this.hint,
    required this.properties,
    this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return switch (hint.kind) {
      'datetime' => _datetimeEditor(),
      _ => _numberEditor(),
    };
  }

  double get _currentNumber {
    final v = value;
    if (v is num) return _clamp(v.toDouble());
    if (v is String) {
      final parsed = double.tryParse(v);
      if (parsed != null) return _clamp(parsed);
    }
    return _clamp(initialNumber(hint, properties));
  }

  double _clamp(double v) {
    final lo = hint.min?.toDouble();
    final hi = hint.max?.toDouble();
    if (lo != null && v < lo) return lo;
    if (hi != null && v > hi) return hi;
    return v;
  }

  Widget _numberEditor() {
    final rawStep = (hint.step ?? 1).toDouble().abs();
    final step = rawStep == 0 ? 1.0 : rawStep;
    final min = hint.min?.toDouble();
    final max = hint.max?.toDouble();
    final current = _currentNumber;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
      decoration: BoxDecoration(
        color: PopColors.fill2,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.tune, size: 14, color: PopColors.text2),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  '値を調整して承認',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: PopColors.text2),
                ),
              ),
              Text(
                _formatNumber(current),
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: PopColors.text),
              ),
            ],
          ),
          if (min != null && max != null && max > min) ...[
            const SizedBox(height: 4),
            Slider(
              value: current.clamp(min, max),
              min: min,
              max: max,
              divisions: ((max - min) / step).round().clamp(1, 200),
              label: _formatNumber(current),
              onChanged: (v) {
                HapticFeedback.selectionClick();
                onChanged(_snap(v, step));
              },
            ),
          ] else ...[
            const SizedBox(height: 8),
            Row(
              children: [
                _stepButton(Icons.remove, () {
                  HapticFeedback.selectionClick();
                  onChanged(_currentNumber - step);
                }),
                const SizedBox(width: 12),
                _stepButton(Icons.add, () {
                  HapticFeedback.selectionClick();
                  onChanged(_currentNumber + step);
                }),
                const SizedBox(width: 12),
                Text(
                  '±${_formatNumber(step)}',
                  style: const TextStyle(fontSize: 11, color: PopColors.text3),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  double _snap(double v, double step) =>
      _clamp((v / step).roundToDouble() * step);

  Widget _stepButton(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: PopColors.surface2,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: PopColors.separator),
        ),
        child: Icon(icon, size: 20, color: PopColors.text),
      ),
    );
  }

  String get _currentIso {
    final v = value;
    if (v is String && DateTime.tryParse(v) != null) return v;
    return initialDatetime(hint, properties);
  }

  Widget _datetimeEditor() {
    final stepMin = (hint.step?.round() ?? 15).abs().clamp(1, 24 * 60);
    final current = DateTime.tryParse(_currentIso)?.toLocal() ?? DateTime.now();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
      decoration: BoxDecoration(
        color: PopColors.fill2,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.schedule, size: 14, color: PopColors.text2),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  '時間を変更して承認',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: PopColors.text2),
                ),
              ),
              Text(
                _formatDatetime(current),
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: PopColors.text),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _stepButton(Icons.remove, () => _shift(current, -stepMin)),
              const SizedBox(width: 12),
              _stepButton(Icons.add, () => _shift(current, stepMin)),
              const SizedBox(width: 12),
              Text(
                '±$stepMin分',
                style: const TextStyle(fontSize: 11, color: PopColors.text3),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _shift(DateTime current, int minutes) {
    HapticFeedback.selectionClick();
    onChanged(current.add(Duration(minutes: minutes)).toUtc().toIso8601String());
  }

  /// Number the editor starts from: an explicit `value`/`default`, then
  /// the proposed `after`, else the hint's `min` (or 0).
  static double initialNumber(EditableHint hint, Map<String, dynamic> props) {
    double? candidate;
    for (final key in const ['value', 'default', 'after', 'amount']) {
      candidate = _asDouble(props[key]);
      if (candidate != null) break;
    }
    candidate ??= hint.min ?? 0;
    if (hint.min != null && candidate < hint.min!) return hint.min!;
    if (hint.max != null && candidate > hint.max!) return hint.max!;
    return candidate;
  }

  /// Datetime the editor starts from: the proposed `after`, then
  /// `value`/`default`, else now. Always an ISO string.
  static String initialDatetime(EditableHint hint, Map<String, dynamic> props) {
    for (final key in const ['after', 'value', 'default']) {
      final raw = props[key];
      if (raw is String && DateTime.tryParse(raw) != null) return raw;
    }
    return DateTime.now().toUtc().toIso8601String();
  }

  static double? _asDouble(Object? raw) {
    if (raw is num) return raw.toDouble();
    if (raw is String) return double.tryParse(raw);
    return null;
  }

  static String _formatNumber(double v) =>
      v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(2);

  static String _formatDatetime(DateTime at) =>
      '${at.month}/${at.day} ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
}
