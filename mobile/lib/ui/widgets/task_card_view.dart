import 'package:flutter/material.dart';

import '../../models/task_card.dart';
import '../../models/triage_action.dart';
import 'component_renderer.dart';
import 'confidence_indicator.dart';

/// One triage card: header → confidence → diff/body → chips (spec §3.2).
/// [swipePercentX]/[swipePercentY] are signed percentages toward the
/// swipe threshold, used to paint the directional overlay.
class TaskCardView extends StatelessWidget {
  final TaskCard task;
  final String Function(DateTime) timeAgo;
  final void Function(ActionBinding binding) onQuickAction;
  final VoidCallback onInspect;
  final int swipePercentX;
  final int swipePercentY;

  const TaskCardView({
    super.key,
    required this.task,
    required this.timeAgo,
    required this.onQuickAction,
    required this.onInspect,
    this.swipePercentX = 0,
    this.swipePercentY = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1A1F29),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: _edgeColor, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.45),
              blurRadius: 24,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: onInspect,
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _header(context),
                      if (task.impact != null) ...[
                        const SizedBox(height: 8),
                        _impactRow(),
                      ],
                      const SizedBox(height: 14),
                      ConfidenceIndicator(
                        confidence: task.confidence,
                        reasons: task.confidenceReasons,
                      ),
                      const SizedBox(height: 14),
                      for (final component in task.bodyComponents) ...[
                        ComponentRenderer(
                          component: component,
                          onAction: onQuickAction,
                          onInspect: onInspect,
                        ),
                        const SizedBox(height: 12),
                      ],
                      const Spacer(),
                      _footerHints(),
                    ],
                  ),
                ),
                Positioned.fill(child: IgnorePointer(child: _swipeOverlay())),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color get _edgeColor {
    switch (task.severity) {
      case 'critical':
        return const Color(0xFFFF5C5C).withOpacity(0.45);
      case 'warning':
        return const Color(0xFFFFB020).withOpacity(0.45);
      default:
        return Colors.white.withOpacity(0.08);
    }
  }

  Widget _header(BuildContext context) {
    return Row(
      children: [
        CircleAvatar(
          radius: 16,
          backgroundColor: const Color(0xFF5B8DEF).withOpacity(0.25),
          backgroundImage: task.agent.avatarUrl != null
              ? NetworkImage(task.agent.avatarUrl!)
              : null,
          child: task.agent.avatarUrl != null
              ? null
              : Text(
                  task.agent.name.isNotEmpty ? task.agent.name[0] : '?',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w800),
                ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            task.agent.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
          ),
        ),
        Text(
          timeAgo(task.createdAt),
          style: const TextStyle(fontSize: 11, color: Colors.white38),
        ),
        const SizedBox(width: 8),
        _severityBadge(),
      ],
    );
  }

  /// 「承認すると…」+ 可逆性バッジ (I-202)。
  Widget _impactRow() {
    final impact = task.impact!;
    final parts = <Widget>[];
    if (impact.summary != null) {
      parts.add(
        Expanded(
          child: Text(
            '承認すると ${impact.summary}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
        ),
      );
    } else {
      parts.add(const Spacer());
    }
    if (impact.reversible == false) {
      parts.add(_impactBadge('取り消し不可', const Color(0xFFFF5C5C)));
    } else if (impact.reversible == true) {
      parts.add(_impactBadge('取り消し可', const Color(0xFF4CAF7D)));
    }
    if (impact.costAmount != null && impact.costCurrency != null) {
      parts.add(_impactBadge(
        '${impact.costCurrency} ${impact.costAmount}',
        const Color(0xFFFFB020),
      ));
    }
    return Row(children: parts);
  }

  Widget _impactBadge(String text, Color color) {
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.18),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(0.5), width: 0.8),
      ),
      child: Text(
        text,
        style: TextStyle(
            fontSize: 10, fontWeight: FontWeight.w700, color: color),
      ),
    );
  }

  Widget _severityBadge() {
    final (Color color, String label) = switch (task.severity) {
      'critical' => (const Color(0xFFFF5C5C), 'CRITICAL'),
      'warning' => (const Color(0xFFFFB020), 'WARNING'),
      _ => (const Color(0xFF5B8DEF), 'INFO'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w800,
          color: color,
          letterSpacing: 0.8,
        ),
      ),
    );
  }

  Widget _swipeOverlay() {
    final x = swipePercentX;
    final y = swipePercentY;
    if (x == 0 && y == 0) return const SizedBox.shrink();

    Widget layer;
    if (x.abs() >= y.abs() && x != 0) {
      final opacity = (x.abs() / 100).clamp(0.0, 1.0);
      final approve = x > 0;
      layer = Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          color: (approve ? const Color(0xFF2E7D50) : const Color(0xFFB34040))
              .withOpacity(opacity * 0.55),
        ),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              approve ? Icons.check_circle_outline : Icons.cancel_outlined,
              color: Colors.white,
              size: 44,
            ),
            const SizedBox(height: 6),
            Text(
              approve
                  ? (task.onSwipeRight?.label ?? 'APPROVE')
                  : (task.onSwipeLeft?.label ?? 'REJECT'),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w900,
                letterSpacing: 2,
              ),
            ),
          ],
        ),
      );
    } else {
      final opacity = (y.abs() / 100).clamp(0.0, 1.0);
      layer = Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          color: const Color(0xFF3D5A99).withOpacity(opacity * 0.55),
        ),
        alignment: Alignment.center,
        child: const Text(
          'SNOOZE',
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w900,
            letterSpacing: 2,
          ),
        ),
      );
    }
    return layer;
  }

  Widget _footerHints() {
    return const Row(
      children: [
        Icon(Icons.swipe_left, size: 14, color: Colors.white30),
        SizedBox(width: 4),
        Text('Reject', style: TextStyle(fontSize: 11, color: Colors.white30)),
        Spacer(),
        Icon(Icons.touch_app, size: 14, color: Colors.white30),
        SizedBox(width: 4),
        Text('Inspect', style: TextStyle(fontSize: 11, color: Colors.white30)),
        Spacer(),
        Text('Approve', style: TextStyle(fontSize: 11, color: Colors.white30)),
        SizedBox(width: 4),
        Icon(Icons.swipe_right, size: 14, color: Colors.white30),
      ],
    );
  }
}
