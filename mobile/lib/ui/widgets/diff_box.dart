import 'package:flutter/material.dart';

/// DiffBox catalog component — before/after with red/green highlight,
/// graspable in 0.5s (spec §3.2). `properties`: title, before, after,
/// highlight (info | warning | critical).
class DiffBox extends StatelessWidget {
  final Map<String, dynamic> properties;

  const DiffBox({super.key, required this.properties});

  Color get _highlightColor {
    switch (properties['highlight']) {
      case 'critical':
        return const Color(0xFFFF5C5C);
      case 'warning':
        return const Color(0xFFFFB020);
      default:
        return const Color(0xFF5B8DEF);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = properties['title'] as String?;
    final before = '${properties['before'] ?? ''}';
    final after = '${properties['after'] ?? ''}';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: _highlightColor, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null && title.isNotEmpty)
            Text(
              title,
              style: Theme.of(context)
                  .textTheme
                  .labelMedium
                  ?.copyWith(color: Colors.white70),
            ),
          if (title != null && title.isNotEmpty) const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: _Side(
                    label: 'BEFORE',
                    text: before,
                    color: const Color(0xFFFF7A7A)),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.arrow_forward, size: 16, color: Colors.white38),
              const SizedBox(width: 8),
              Expanded(
                child: _Side(
                    label: 'AFTER',
                    text: after,
                    color: const Color(0xFF7BE494)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Side extends StatelessWidget {
  final String label;
  final String text;
  final Color color;

  const _Side({required this.label, required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: color,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          text,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, height: 1.3),
        ),
      ],
    );
  }
}
