import 'package:flutter/material.dart';

/// DiffBox catalog component — before/after with red/green highlight,
/// graspable in 0.5s (spec §3.2). `properties`: title, before, after,
/// highlight (info | warning | critical), optional `rows` (list of
/// `{label?, before?, after?}` rendered after the main pair), optional
/// `inline` (unified-diff style text with `+`/`-`/space prefixes — plain
/// text lines, colored, never markup). Everything renders as text (NFR-2.1).
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

  List<Map<String, String>> get _rows {
    final raw = properties['rows'];
    if (raw is! List) return const [];
    return [
      for (final r in raw)
        if (r is Map)
          {
            if (r['label'] != null) 'label': '${r['label']}',
            'before': '${r['before'] ?? ''}',
            'after': '${r['after'] ?? ''}',
          },
    ];
  }

  String? get _inline {
    final raw = properties['inline'];
    if (raw is! String || raw.isEmpty) return null;
    return raw;
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
        color: Colors.white.withValues(alpha: 0.04),
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
          _Pair(before: before, after: after),
          for (final row in _rows) ...[
            const SizedBox(height: 8),
            _Pair(
              before: row['before'] ?? '',
              after: row['after'] ?? '',
              label: row['label'],
            ),
          ],
          if (_inline != null) ...[
            const SizedBox(height: 8),
            _Inline(text: _inline!),
          ],
        ],
      ),
    );
  }
}

class _Pair extends StatelessWidget {
  final String before;
  final String after;
  final String? label;

  const _Pair({required this.before, required this.after, this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null && label!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              label!,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: Colors.white70),
            ),
          ),
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
    );
  }
}

/// Unified-diff style block: `+` lines green, `-` lines red, everything
/// else dim. Pure text rows — no markup parsing (NFR-2.1).
class _Inline extends StatelessWidget {
  final String text;

  const _Inline({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in text.split('\n'))
            Text(
              line.isEmpty ? ' ' : line,
              style: TextStyle(
                fontFamily: 'monospace',
                fontFamilyFallback: const ['Menlo', 'monospace'],
                fontSize: 12,
                height: 1.5,
                color: line.startsWith('+')
                    ? const Color(0xFF7BE494)
                    : line.startsWith('-')
                        ? const Color(0xFFFF7A7A)
                        : Colors.white54,
              ),
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
