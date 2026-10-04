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
                      if (!task.impact.isEmpty) ...[
                        const SizedBox(height: 10),
                        _impactRow(context),
                      ],
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

  /// "承認すると…" + reversible badge (I-202, P3/P5). Hidden when the
  /// agent sent no impact — old cards render exactly as before.
  Widget _impactRow(BuildContext context) {
    final impact = task.impact;
    final reversible = impact.reversible;
    final badgeColor = reversible == null
        ? Colors.white38
        : reversible
            ? const Color(0xFF7BE494)
            : const Color(0xFFFFB020);
    final badgeLabel =
        reversible == null ? null : reversible ? '取り消し可' : '取り消し不可';
    final parts = <String>[
      if (impact.summary != null && impact.summary!.isNotEmpty) impact.summary!,
      if (impact.amount != null) '${impact.currency ?? ''} ${impact.amount}'.trim(),
      if (impact.scope != null && impact.scope!.isNotEmpty) impact.scope!,
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              parts.isEmpty ? '承認すると実行されます' : '承認すると ${parts.join(' / ')}',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Colors.white70, height: 1.4),
            ),
          ),
          if (badgeLabel != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: badgeColor.withOpacity(0.15),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: badgeColor.withOpacity(0.4)),
              ),
              child: Text(
                badgeLabel,
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  color: badgeColor,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _swipeOverlay() {
    final x = swipePercentX;
    final y = swipePercentY;

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
