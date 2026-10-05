import 'dart:convert';

import 'package:flutter/material.dart';

import '../../models/task_card.dart';
import '../colors.dart';
import 'diff_box.dart';

/// Maps protocol components to native widgets (FR-1.2). Unknown types
/// fall back to a generic text card — never a crash (FR-1.3). Payloads
/// are pure data rendered as text; nothing is ever evaluated (NFR-2.1).
///
/// Components render in ink on the colored card; content-bearing blocks
/// (external quotes) become white pills like on the web.
class ComponentRenderer extends StatelessWidget {
  final CardComponent component;

  /// A quick-action chip with an explicit `actionName` was tapped.
  final void Function(ActionBinding binding)? onAction;

  /// A chip without an action wants the inspect sheet.
  final VoidCallback? onInspect;

  const ComponentRenderer({
    super.key,
    required this.component,
    this.onAction,
    this.onInspect,
  });

  @override
  Widget build(BuildContext context) {
    switch (component.component) {
      case 'Text':
        return _text(context);
      case 'DiffBox':
        return DiffBox(properties: component.properties);
      case 'Chips':
        return _chips(context);
      default:
        return _fallback(context);
    }
  }

  Widget _text(BuildContext context) {
    final text = '${component.properties['text'] ?? ''}';
    final variant = component.properties['variant'] as String?;
    final style = switch (variant) {
      'title' => Theme.of(context).textTheme.titleMedium
          ?.copyWith(color: PopColors.ink, fontWeight: FontWeight.w800),
      'caption' => Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: PopColors.inkSoft),
      _ => Theme.of(context)
          .textTheme
          .bodyMedium
          ?.copyWith(color: PopColors.ink),
    };
    // External-origin text (mail bodies, PR comments) renders in the
    // white pill quote-block style so it cannot impersonate system UI
    // (NFR-2.2).
    if (component.properties['source'] == 'external') {
      return Container(
        padding: const EdgeInsets.fromLTRB(11, 8, 11, 8),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
                color: PopColors.ink.withValues(alpha: 0.35), width: 3),
          ),
          color: PopColors.pill,
          borderRadius: const BorderRadius.horizontal(
            left: Radius.circular(6),
            right: Radius.circular(12),
          ),
        ),
        child: Text(
          text,
          style: style?.copyWith(
            fontStyle: FontStyle.italic,
            color: const Color(0xFF4A4E42),
          ),
        ),
      );
    }
    return Text(text, style: style);
  }

  Widget _chips(BuildContext context) {
    final options = component.properties['options'];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final option in (options is List ? options : const <dynamic>[]))
          if (option is Map)
            ActionChip(
              label: Text(
                '${option['label'] ?? 'option'}',
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.white),
              ),
              backgroundColor: PopColors.darkPill,
              side: BorderSide.none,
              shape: const StadiumBorder(),
              visualDensity: VisualDensity.compact,
              onPressed: () =>
                  _onChip(Map<String, dynamic>.from(option)),
            ),
      ],
    );
  }

  void _onChip(Map<String, dynamic> option) {
    final actionName = option['actionName'] as String?;
    if (actionName == null || actionName.isEmpty) {
      onInspect?.call();
      return;
    }
    final payload = option['payload'] is Map
        ? Map<String, dynamic>.from(option['payload'] as Map)
        : const <String, dynamic>{};
    onAction?.call(ActionBinding(actionName: actionName, payload: payload));
  }

  Widget _fallback(BuildContext context) {
    final pretty = const JsonEncoder.withIndent('  ')
        .convert(component.properties);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: PopColors.ink.withValues(alpha: 0.3),
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Unsupported component',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 12,
              color: PopColors.inkSoft,
            ),
          ),
          Text(
            component.component,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: PopColors.ink,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            pretty,
            style: const TextStyle(
              fontSize: 11,
              color: PopColors.inkSoft,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}
