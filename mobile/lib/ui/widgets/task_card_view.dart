import 'package:flutter/material.dart';

import '../../models/task_card.dart';
import '../colors.dart';
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
    final (cardTop, cardBottom) = PopColors.severityCard(task.severity);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Container(
        decoration: BoxDecoration(
          // The card surface itself carries severity (color-pop).
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [cardTop, cardBottom],
          ),
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.42),
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
                      if (task.expiresAt != null) ...[
                        _countdownStrip(),
                        const SizedBox(height: 10),
                      ],
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

  /// Deadline countdown strip (I-203). Neutral = translucent dark pill;
  /// soon (≤30m) = white pill with dark amber; urgent (≤5m / past) =
  /// white pill with red. The hub executes the default behavior; the
  /// strip only tells the user what will happen.
  Widget _countdownStrip() {
    final remaining = task.expiresAt!.difference(DateTime.now());
    final bool past = remaining.inSeconds <= 0;
    final bool urgent = past || remaining <= const Duration(minutes: 5);
    final bool soon = !urgent && remaining <= const Duration(minutes: 30);
    final Color textColor = urgent
        ? PopColors.diffBefore
        : soon
            ? const Color(0xFF8A6A00)
            : Colors.white.withValues(alpha: 0.92);
    final Color bgColor = urgent || soon
        ? PopColors.pill
        : const Color(0x520F110C); // translucent dark pill
    final String when;
    if (past) {
      when = '期限切れ';
    } else {
      when = '残り ${_formatRemaining(remaining)}';
    }
    final verb = switch (task.onExpire) {
      'approve' => '期限で自動承認',
      'reject' => '期限で自動却下',
      'escalate' => '期限で緊急化',
      _ => '期限で破棄',
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        children: [
          Icon(Icons.hourglass_bottom, size: 13, color: textColor),
          const SizedBox(width: 6),
          Text(
            past ? '$when · まもなく自動処理' : '$when · $verb',
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w700, color: textColor),
          ),
        ],
      ),
    );
  }

  static String _formatRemaining(Duration remaining) {
    if (remaining.inHours >= 1) {
      return '${remaining.inHours}時間${remaining.inMinutes % 60}分';
    }
    if (remaining.inMinutes >= 10) {
      return '${remaining.inMinutes}分';
    }
    if (remaining.inMinutes >= 1) {
      return '${remaining.inMinutes}分${remaining.inSeconds % 60}秒';
    }
    return '${remaining.inSeconds}秒';
  }

  Widget _header(BuildContext context) {
    return Row(
      children: [
        CircleAvatar(
          radius: 16,
          backgroundColor: PopColors.darkPill,
          backgroundImage: task.agent.avatarUrl != null
              ? NetworkImage(task.agent.avatarUrl!)
              : null,
          child: task.agent.avatarUrl != null
              ? null
              : Text(
                  task.agent.name.isNotEmpty ? task.agent.name[0] : '?',
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: Colors.white),
                ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            task.agent.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 14,
                color: PopColors.ink,
                letterSpacing: -0.2),
          ),
        ),
        Text(
          timeAgo(task.createdAt),
          style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: PopColors.inkSoft),
        ),
        const SizedBox(width: 8),
        _severityBadge(),
      ],
    );
  }

  /// 「承認すると…」+ 可逆性バッジ (I-202)。Ink text on the colored card.
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
            style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: PopColors.ink),
          ),
        ),
      );
    } else {
      parts.add(const Spacer());
    }
    if (impact.reversible == false) {
      parts.add(_impactBadge('取り消し不可', const Color(0xFFFFC9C2)));
    } else if (impact.reversible == true) {
      parts.add(_impactBadge('取り消し可', const Color(0xFFD9F2B4)));
    }
    if (impact.costAmount != null && impact.costCurrency != null) {
      parts.add(_impactBadge(
        '${impact.costCurrency} ${impact.costAmount}',
        const Color(0xFFFFE08A),
      ));
    }
    return Row(children: parts);
  }

  Widget _impactBadge(String text, Color color) {
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: PopColors.darkPill,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
            fontSize: 10, fontWeight: FontWeight.w800, color: color),
      ),
    );
  }

  Widget _severityBadge() {
    final String label = switch (task.severity) {
      'critical' => 'CRITICAL',
      'warning' => 'WARNING',
      _ => 'INFO',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: PopColors.darkPill,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w800,
          color: Colors.white,
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
              .withValues(alpha: opacity * 0.55),
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
          color: const Color(0xFF3D5A99).withValues(alpha: opacity * 0.55),
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
        Icon(Icons.swipe_left, size: 14, color: PopColors.inkSoft),
        SizedBox(width: 4),
        Text('Reject',
            style: TextStyle(fontSize: 11, color: PopColors.inkSoft)),
        Spacer(),
        Icon(Icons.touch_app, size: 14, color: PopColors.inkSoft),
        SizedBox(width: 4),
        Text('Inspect',
            style: TextStyle(fontSize: 11, color: PopColors.inkSoft)),
        Spacer(),
        Text('Approve',
            style: TextStyle(fontSize: 11, color: PopColors.inkSoft)),
        SizedBox(width: 4),
        Icon(Icons.swipe_right, size: 14, color: PopColors.inkSoft),
      ],
    );
  }
}
