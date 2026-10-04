import 'package:flutter/material.dart';

/// Confidence ≥0.9 → green ("swipe right without reading"), <0.6 → red.
/// Low confidence additionally shows the reason tags (spec §3.2).
class ConfidenceIndicator extends StatelessWidget {
  final double confidence;
  final List<String> reasons;

  const ConfidenceIndicator({
    super.key,
    required this.confidence,
    this.reasons = const <String>[],
  });

  Color get _color {
    if (confidence >= 0.9) return const Color(0xFF7BE494);
    if (confidence >= 0.75) return const Color(0xFFB7E36B);
    if (confidence >= 0.6) return const Color(0xFFFFB020);
    return const Color(0xFFFF5C5C);
  }

  String get _label {
    if (confidence >= 0.9) return '無思考で右スワイプ可';
    if (confidence >= 0.75) return '確認推奨';
    if (confidence >= 0.6) return '要確認';
    return '要注意';
  }

  @override
  Widget build(BuildContext context) {
    final percent = (confidence * 100).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              'Confidence',
              style: TextStyle(fontSize: 10, color: Colors.white38, letterSpacing: 1),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: confidence.clamp(0.0, 1.0),
                  minHeight: 4,
                  backgroundColor: Colors.white12,
                  valueColor: AlwaysStoppedAnimation<Color>(_color),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '$percent%',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: _color,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: _color.withOpacity(0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                _label,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: _color,
                ),
              ),
            ),
          ],
        ),
        if (confidence < 0.75 && reasons.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final reason in reasons)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    reason,
                    style: const TextStyle(fontSize: 11, color: Colors.white70),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
