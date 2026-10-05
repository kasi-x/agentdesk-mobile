import 'package:flutter/material.dart';

import '../colors.dart';

/// Confidence indicator on the colored card: ink label + ink fill over a
/// translucent dark track. The percentage and the low-confidence reason
/// tags carry the level (color itself is reserved for severity).
class ConfidenceIndicator extends StatelessWidget {
  final double confidence;
  final List<String> reasons;

  const ConfidenceIndicator({
    super.key,
    required this.confidence,
    this.reasons = const <String>[],
  });

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
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w800,
                color: PopColors.inkSoft,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: confidence.clamp(0.0, 1.0),
                  minHeight: 5,
                  backgroundColor: const Color(0x2A0F110C),
                  valueColor:
                      const AlwaysStoppedAnimation<Color>(PopColors.ink),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '$percent%',
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: PopColors.ink),
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
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0x290F110C),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    reason,
                    style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: PopColors.ink),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
