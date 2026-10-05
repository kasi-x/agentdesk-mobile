import 'package:flutter/material.dart';


import '../../models/task_card.dart';
import '../colors.dart';
import 'component_renderer.dart';

/// One triage card — calm-iOS minimal: only what the decision needs is
/// on the front (summary headline, 承認すると… line, value-aware diff,
/// quiet meta). Everything else (理由/誰が/参加者/出典) expands via the
/// 詳細を見る toggle. [swipePercentX]/[swipePercentY] paint the overlay.
class TaskCardView extends StatefulWidget {
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
  State<TaskCardView> createState() => _TaskCardViewState();
}

class _TaskCardViewState extends State<TaskCardView> {
  bool _expanded = false;

  TaskCard get task => widget.task;

  /// Caption / external texts are 裏面 material — they render in the
  /// details panel, not on the front (information reduction, P1/P8).
  late final List<CardComponent> _movedTexts = task.bodyComponents
      .where((c) =>
          c.component == 'Text' &&
          (c.properties['variant'] == 'caption' ||
              c.properties['source'] == 'external'))
      .toList();
  late final List<CardComponent> _frontComponents = task.bodyComponents
      .where((c) => !_movedTexts.contains(c))
      .toList();

  bool get _hasDetails {
    final ctx = task.context;
    final impact = task.impact;
    final hasContext = ctx != null &&
        (ctx.reasoning != null ||
            ctx.requesterName != null ||
            ctx.participants.isNotEmpty ||
            ctx.sourceLabel != null);
    return hasContext ||
        _movedTexts.isNotEmpty ||
        (impact?.summary != null) ||
        (impact?.costAmount != null) ||
        (task.confidence < 0.9 && task.confidenceReasons.isNotEmpty) ||
        task.expiresAt != null;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Container(
        decoration: BoxDecoration(
          color: PopColors.surface,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 30,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: widget.onInspect,
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _header(),
                      const SizedBox(height: 10),
                      Text(
                        task.summary,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.4,
                          height: 1.3,
                          color: PopColors.text,
                        ),
                      ),
                      if (task.impact?.summary != null) ...[
                        const SizedBox(height: 4),
                        _impactLine(),
                      ],
                      const SizedBox(height: 10),
                      for (final component in _frontComponents) ...[
                        ComponentRenderer(
                          component: component,
                          onAction: widget.onQuickAction,
                          onInspect: widget.onInspect,
                        ),
                        const SizedBox(height: 10),
                      ],
                      _metaLine(),
                      if (_hasDetails) ...[
                        const SizedBox(height: 4),
                        _detailsSection(),
                      ],
                    ],
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(child: _swipeOverlay()),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Row(
      children: [
        CircleAvatar(
          radius: 14,
          backgroundColor: PopColors.fill,
          backgroundImage: task.agent.avatarUrl != null
              ? NetworkImage(task.agent.avatarUrl!)
              : null,
          child: task.agent.avatarUrl != null
              ? null
              : Text(
                  task.agent.name.isNotEmpty ? task.agent.name[0] : '?',
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: PopColors.text),
                ),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            task.agent.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: PopColors.text2),
          ),
        ),
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: PopColors.severityDot(task.severity),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 9),
        Text(
          widget.timeAgo(task.createdAt),
          style: const TextStyle(fontSize: 13, color: PopColors.text3),
        ),
      ],
    );
  }

  /// 「承認すると…」+ 取り消し不可 tag — the result, stated first (P3).
  Widget _impactLine() {
    final impact = task.impact!;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (impact.reversible == false)
          Container(
            margin: const EdgeInsets.only(right: 7),
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: PopColors.red.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Text(
              '取り消し不可',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: PopColors.red),
            ),
          ),
        Text(
          '承認すると ${impact.summary}',
          style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: PopColors.text2),
        ),
      ],
    );
  }

  /// Quiet meta: 信頼度 · deadline. Urgency color only when it matters.
  Widget _metaLine() {
    if (task.confidence == 0 && task.expiresAt == null) {
      return const SizedBox.shrink();
    }
    final pct = (task.confidence * 100).round();
    final items = <Widget>[
      Text(
        '信頼度 $pct%',
        style: TextStyle(
          fontSize: 13,
          fontFeatures: const [FontFeature.tabularFigures()],
          color: task.confidence < 0.6 ? PopColors.orange : PopColors.text2,
        ),
      ),
    ];
    // deadline surfaces on the front only when it is close; the full
    // deadline lives in 詳細 (P8: the front carries the decision).
    if (task.expiresAt != null) {
      final remaining = task.expiresAt!.difference(DateTime.now());
      final urgent =
          remaining.inSeconds <= 0 || remaining <= const Duration(minutes: 5);
      final soon = !urgent && remaining <= const Duration(minutes: 30);
      if (urgent || soon) {
        final when = remaining.inSeconds <= 0
            ? '期限切れ'
            : '残り ${_formatRemaining(remaining)}';
        items.add(
          Text(
            when,
            style: TextStyle(
              fontSize: 13,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: urgent ? PopColors.red : PopColors.orange,
            ),
          ),
        );
      }
    }
    return Row(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(width: 14),
          items[i],
        ],
      ],
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

  /// 詳細を見る → expands downward (Apple: common path first, context one
  /// level deeper). 理由 / 誰が / 参加者 / 出典 / 金額 / 注意点 / 期限.
  Widget _detailsSection() {
    final open = _expanded;
    return Container(
      margin: const EdgeInsets.only(top: 2),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: PopColors.borderSoft)),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 11),
              child: Row(
                children: [
                  Text(
                    open ? '詳細を隠す' : '詳細を見る',
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: PopColors.blue),
                  ),
                  const Spacer(),
                  AnimatedRotation(
                    turns: open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    child: const Icon(Icons.expand_more,
                        size: 18, color: PopColors.blue),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: open
                ? Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _DetailsPanel(task: task, movedTexts: _movedTexts),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  Widget _swipeOverlay() {
    final x = widget.swipePercentX;
    final y = widget.swipePercentY;
    if (x == 0 && y == 0) return const SizedBox.shrink();

    Widget layer;
    if (x.abs() >= y.abs() && x != 0) {
      final opacity = (x.abs() / 100).clamp(0.0, 1.0);
      final approve = x > 0;
      layer = Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: (approve
                  ? const Color(0xFF1D3A2A)
                  : const Color(0xFF3A1D1D))
              .withValues(alpha: opacity * 0.85),
        ),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              approve ? Icons.check_circle_outline : Icons.cancel_outlined,
              color: approve ? PopColors.green : PopColors.red,
              size: 44,
            ),
            const SizedBox(height: 6),
            Text(
              approve
                  ? (task.onSwipeRight?.label ?? 'APPROVE')
                  : (task.onSwipeLeft?.label ?? 'REJECT'),
              style: TextStyle(
                color: approve ? PopColors.green : PopColors.red,
                fontSize: 18,
                fontWeight: FontWeight.w800,
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
          borderRadius: BorderRadius.circular(18),
          color: const Color(0xFF2C313A).withValues(alpha: opacity * 0.85),
        ),
        alignment: Alignment.center,
        child: const Text(
          'SNOOZE',
          style: TextStyle(
            color: PopColors.text2,
            fontSize: 18,
            fontWeight: FontWeight.w800,
            letterSpacing: 2,
          ),
        ),
      );
    }
    return layer;
  }
}

/// 詳細パネル: 理由 / 誰が / 参加者 / 出典 / 金額 / 注意点 / 期限 (P1: 裏面)。
/// Inset grouped rows, iOS list style. Links stay label-only on mobile.
class _DetailsPanel extends StatelessWidget {
  final TaskCard task;
  final List<CardComponent> movedTexts;

  const _DetailsPanel({required this.task, this.movedTexts = const []});

  @override
  Widget build(BuildContext context) {
    final ctx = task.context;
    final impact = task.impact;
    final narrative = movedTexts
        .where((c) => c.properties['source'] != 'external')
        .toList();
    final quotes = movedTexts
        .where((c) => c.properties['source'] == 'external')
        .toList();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 4),
      decoration: BoxDecoration(
        color: PopColors.surface2,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (impact?.summary != null)
            _row(
              '結果',
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('承認すると ${impact!.summary}',
                      style: const TextStyle(
                          fontSize: 14, color: PopColors.text)),
                  if (impact.reversible == false)
                    const Text('この操作は取り消せません',
                        style: TextStyle(
                            fontSize: 13, color: PopColors.text2)),
                ],
              ),
            ),
          if (narrative.isNotEmpty || ctx?.reasoning != null)
            _row(
              'なぜ',
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final c in narrative)
                    Text('${c.properties['text'] ?? ''}',
                        style: const TextStyle(
                            fontSize: 14, height: 1.5, color: PopColors.text)),
                  if (ctx?.reasoning != null)
                    Text(ctx!.reasoning!,
                        style: const TextStyle(
                            fontSize: 14, height: 1.5, color: PopColors.text)),
                ],
              ),
            ),
          for (final c in quotes)
            _row('引用', ComponentRenderer(component: c)),
          if (ctx?.requesterName != null)
            _row(
              '誰が',
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(ctx!.requesterName!,
                      style: const TextStyle(fontSize: 14, color: PopColors.text)),
                  if (ctx.requesterOnBehalfOf != null)
                    Text('${ctx.requesterOnBehalfOf} の依頼',
                        style: const TextStyle(fontSize: 13, color: PopColors.text2)),
                ],
              ),
            ),
          if (ctx != null && ctx.participants.isNotEmpty)
            _row(
              '参加者',
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final p in ctx.participants)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 11, vertical: 5),
                      decoration: BoxDecoration(
                        color: PopColors.fill2,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _statusColor(p.status),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(p.name,
                              style: const TextStyle(
                                  fontSize: 13, color: PopColors.text)),
                          if (p.status != null) ...[
                            const SizedBox(width: 4),
                            Text(p.status!,
                                style: const TextStyle(
                                    fontSize: 12, color: PopColors.text2)),
                          ],
                        ],
                      ),
                    ),
                ],
              ),
            ),
          if (ctx?.sourceLabel != null)
            _row(
              '出典',
              Text(
                ctx!.sourceLabel! + (ctx.sourceUrl != null ? ' ↗' : ''),
                style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: PopColors.blue),
              ),
            ),
          if (impact?.costAmount != null && impact!.costCurrency != null)
            _row(
              '金額',
              Text(
                '${impact.costCurrency} ${_amount(impact.costAmount!)}',
                style: const TextStyle(
                    fontSize: 14, color: PopColors.text),
              ),
            ),
          if (task.confidenceReasons.isNotEmpty)
            _row(
              '注意点',
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final r in task.confidenceReasons)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: PopColors.fill2,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(r,
                          style: const TextStyle(
                              fontSize: 12, color: PopColors.text2)),
                    ),
                ],
              ),
            ),
          if (task.expiresAt != null)
            _row(
              '期限',
              Text(
                '${_formatDeadline(task.expiresAt!)} — ${_verb(task.onExpire)}',
                style: const TextStyle(fontSize: 14, color: PopColors.text),
              ),
            ),
        ],
      ),
    );
  }

  static Color _statusColor(String? status) {
    final s = (status ?? '').toLowerCase();
    if (s.contains('free')) return PopColors.green;
    if (s.contains('busy') || (status ?? '').contains('重複')) {
      return PopColors.red;
    }
    return PopColors.text3;
  }

  static String _amount(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(2);

  static String _verb(String? onExpire) => switch (onExpire) {
        'approve' => '自動承認',
        'reject' => '自動却下',
        'escalate' => '緊急化',
        _ => '自動破棄',
      };

  static String _formatDeadline(DateTime at) {
    final local = at.toLocal();
    return '${local.month}/${local.day} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  Widget _row(String label, Widget value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
              color: PopColors.text3,
            ),
          ),
          const SizedBox(height: 4),
          value,
        ],
      ),
    );
  }
}
