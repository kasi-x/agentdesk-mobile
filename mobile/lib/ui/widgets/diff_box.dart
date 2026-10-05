import 'package:flutter/material.dart';

import '../colors.dart';

/// DiffBox catalog component — before/after that reads as what it IS:
/// datetimes render as a calendar row (📅 date + clock chips + delta),
/// money as amount chips; anything unparseable falls back to plain text
/// diff lines. White pill on the colored card (spec §3.2).
/// `properties`: title, before, after, highlight (info | warning |
/// critical), optional `rows` (`{label?, before?, after?}`), optional
/// `inline` (unified-diff text). Everything renders as text (NFR-2.1).
class DiffBox extends StatelessWidget {
  final Map<String, dynamic> properties;

  const DiffBox({super.key, required this.properties});

  Color get _highlightColor {
    switch (properties['highlight']) {
      case 'critical':
        return const Color(0xFFE0352B);
      case 'warning':
        return const Color(0xFFF0A726);
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
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: PopColors.pill,
        borderRadius: BorderRadius.circular(16),
        border: Border(left: BorderSide(color: _highlightColor, width: 4)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null && title.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
              decoration: const BoxDecoration(
                color: Color(0x121B1E16),
                border: Border(
                  bottom: BorderSide(color: Color(0x141B1E16)),
                ),
              ),
              child: Text(
                title,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: const Color(0xFF565B4D),
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.3,
                    ),
              ),
            ),
          _ValuePair(before: '${properties['before'] ?? ''}', after: '${properties['after'] ?? ''}'),
          for (final row in _rows) ...[
            const SizedBox(height: 2),
            _ValuePair(
              before: row['before'] ?? '',
              after: row['after'] ?? '',
              label: row['label'],
            ),
          ],
          if (_inline != null) ...[
            const SizedBox(height: 4),
            _Inline(text: _inline!),
          ],
        ],
      ),
    );
  }
}

/* ---------------- value parsing (mirror of web/app.js parseValue) --- */

enum _ValueKind { datetime, time, money }

class _ParsedValue {
  final _ValueKind kind;
  final String date; // 10月5日(月)
  final String dateKey;
  final String time;
  final String symbol;
  final double amount;

  _ParsedValue._(this.kind,
      {this.date = '', this.dateKey = '', this.time = '', this.symbol = '', this.amount = 0});
}

_ParsedValue? _parseValue(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return null;
  var m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})[ T](\d{1,2}):(\d{2})(?::\d{2})?$').firstMatch(s);
  if (m != null) {
    const weekdays = ['月', '火', '水', '木', '金', '土', '日'];
    final d = DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
    return _ParsedValue._(_ValueKind.datetime,
        date: '${int.parse(m.group(2)!)}月${int.parse(m.group(3)!)}日(${weekdays[d.weekday - 1]})',
        dateKey: '${m.group(1)}-${m.group(2)}-${m.group(3)}',
        time: '${int.parse(m.group(4)!).toString().padLeft(2, '0')}:${m.group(5)}');
  }
  m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(s);
  if (m != null) {
    return _ParsedValue._(_ValueKind.time,
        time: '${int.parse(m.group(1)!).toString().padLeft(2, '0')}:${m.group(2)}');
  }
  m = RegExp(r'^([^0-9\s]+)\s*([\d,]+(?:\.\d+)?)$').firstMatch(s);
  if (m != null && RegExp(r'^(?:[$¥€£]|usd|jpy|eur)', caseSensitive: false).hasMatch(m.group(1)!)) {
    return _ParsedValue._(_ValueKind.money,
        symbol: m.group(1)!, amount: double.parse(m.group(2)!.replaceAll(',', '')));
  }
  return null;
}

int _minutesOf(String time) {
  final parts = time.split(':');
  return int.parse(parts[0]) * 60 + int.parse(parts[1]);
}

String? _deltaLabel(_ParsedValue bv, _ParsedValue av) {
  if (bv.kind == _ValueKind.datetime &&
      av.kind == _ValueKind.datetime &&
      bv.dateKey == av.dateKey) {
    final diff = _minutesOf(av.time) - _minutesOf(bv.time);
    final sign = diff >= 0 ? '+' : '−';
    final abs = diff.abs();
    final h = abs ~/ 60;
    final mm = abs % 60;
    return sign + (h > 0 ? '$h時間${mm > 0 ? '$mm分' : ''}' : '$mm分');
  }
  if (bv.kind == _ValueKind.money && av.kind == _ValueKind.money && bv.symbol == av.symbol) {
    final diff = av.amount - bv.amount;
    final sign = diff >= 0 ? '+' : '−';
    final abs = diff.abs().toStringAsFixed(diff.abs() == diff.abs().roundToDouble() ? 0 : 2);
    return '$sign${bv.symbol}$abs';
  }
  return null;
}

class _ValuePair extends StatelessWidget {
  final String before;
  final String after;
  final String? label;

  const _ValuePair({required this.before, required this.after, this.label});

  @override
  Widget build(BuildContext context) {
    final bv = _parseValue(before);
    final av = _parseValue(after);
    final meaningful = bv != null && av != null && bv.kind == av.kind;
    return Padding(
      padding: const EdgeInsets.fromLTRB(13, 10, 13, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label != null && label!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                label!,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF565B4D),
                  letterSpacing: 0.4,
                ),
              ),
            ),
          if (meaningful)
            _ValueChips(bv: bv, av: av)
          else ...[
            Text(
              before,
              style: const TextStyle(
                fontSize: 13,
                color: PopColors.diffBefore,
                decoration: TextDecoration.lineThrough,
                decorationColor: Color(0x8CC2321F),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '→ $after',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: PopColors.diffAfter,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ValueChips extends StatelessWidget {
  final _ParsedValue bv;
  final _ParsedValue av;

  const _ValueChips({required this.bv, required this.av});

  @override
  Widget build(BuildContext context) {
    final delta = _deltaLabel(bv, av) ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (bv.kind == _ValueKind.datetime) ...[
          Row(
            children: [
              const Icon(Icons.event, size: 15, color: PopColors.ink),
              const SizedBox(width: 6),
              Text(
                bv.date,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: PopColors.ink),
              ),
            ],
          ),
          const SizedBox(height: 7),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _chip(
              background: const Color(0x141B1E16),
              foreground: PopColors.inkSoft,
              text: bv.kind == _ValueKind.money
                  ? '${bv.symbol}${_amount(bv.amount)}'
                  : bv.time,
              strike: true,
            ),
            const Icon(Icons.arrow_forward, size: 15, color: Color(0xFF6B6F60)),
            _chip(
              background: PopColors.ink,
              foreground: Colors.white,
              text: av.kind == _ValueKind.money
                  ? '${av.symbol}${_amount(av.amount)}'
                  : av.time,
              strike: false,
            ),
            if (delta.isNotEmpty)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0x1A1B1E16),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  delta,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: PopColors.ink,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  static String _amount(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(2);

  Widget _chip({
    required Color background,
    required Color foreground,
    required String text,
    required bool strike,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (bv.kind != _ValueKind.money)
            Icon(Icons.access_time, size: 14, color: foreground),
          if (bv.kind != _ValueKind.money) const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              fontSize: 15,
              fontFeatures: const [FontFeature.tabularFigures()],
              fontWeight: strike ? FontWeight.w500 : FontWeight.w700,
              color: foreground,
              decoration:
                  strike ? TextDecoration.lineThrough : TextDecoration.none,
              decorationThickness: 1.5,
            ),
          ),
        ],
      ),
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
      margin: const EdgeInsets.fromLTRB(13, 0, 13, 13),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFF14170F),
        borderRadius: BorderRadius.circular(10),
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
                    ? const Color(0xFF3DDC84)
                    : line.startsWith('-')
                        ? const Color(0xFFFF6B6B)
                        : const Color(0xFF8A9080),
              ),
            ),
        ],
      ),
    );
  }
}
