import 'dart:convert';

import 'package:flutter/material.dart';

import '../../models/task_card.dart';
import 'diff_box.dart';

/// Maps protocol components to native widgets (FR-1.2). Unknown types
/// fall back to a generic text card — never a crash (FR-1.3). Payloads
/// are pure data rendered as text; nothing is ever evaluated (NFR-2.1).
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
      'title' => Theme.of(context).textTheme.titleMedium,
      'caption' =>
        Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white60),
      _ => Theme.of(context).textTheme.bodyMedium,
    };
    // External-origin text (mail bodies, PR comments) renders in the
    // quote-block style so it cannot impersonate system UI (NFR-2.2).
    if (component.properties['source'] == 'external') {
      return Container(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
        decoration: BoxDecoration(
          border: const Border(left: BorderSide(color: Colors.white24, width: 3)),
          color: Colors.white.withValues(alpha: 0.03),
        ),
        child: Text(
          text,
          style: style?.copyWith(fontStyle: FontStyle.italic),
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
                style: const TextStyle(fontSize: 12),
              ),
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
        color: Colors.orange.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Unsupported component',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 12,
              color: Colors.orangeAccent,
            ),
          ),
          Text(
            component.component,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.orangeAccent,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            pretty,
            style: const TextStyle(
              fontSize: 11,
              color: Colors.white54,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}
