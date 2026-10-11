import 'dart:math';

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

  /// Percent of the swipe threshold at which the second stage begins
  /// (I-101); 0 disables the second-stage overlay label.
  final int secondStageThreshold;

  /// Row ids already selected in row-select DiffBoxes (I-112).
  final Set<String> selectedRowIds;

  /// Fires when a selectable DiffBox row is tapped.
  final void Function(String rowId)? onRowToggle;

  /// Current edited value for the inline editor (I-114), if touched.
  final Object? editedValue;

  /// Fires when the inline editor changes.
  final void Function(Object value)? onEditedValue;

  /// Assignee recorded by the hub or a delegate echo (I-501).
  final String? delegatedTo;

  /// Approvals already recorded by earlier devices (I-602); shown as
  /// 「承認 a/b」 when `task.requiredApprovals > 1`.
  final int approvalCount;

  /// The agent callback delivery failed terminally (I-604).
  final bool deliveryFailed;

  /// Rubber-stamp detection tripped (I-401): confirm before approving.
  final bool rubberStamp;

  /// Animated 「更新されました」 on agent updates (I-204).
  final bool revised;

  const TaskCardView({
    super.key,
    required this.task,
    required this.timeAgo,
    required this.onQuickAction,
    required this.onInspect,
    this.swipePercentX = 0,
    this.swipePercentY = 0,
    this.secondStageThreshold = 0,
    this.selectedRowIds = const <String>{},
    this.onRowToggle,
    this.editedValue,
    this.onEditedValue,
    this.delegatedTo,
    this.approvalCount = 0,
    this.deliveryFailed = false,
    this.rubberStamp = false,
    this.revised = false,
  });

  @override
  State<TaskCardView> createState() => _TaskCardViewState();
}

class _TaskCardViewState extends State<TaskCardView> {
  bool _expanded = false;
  bool _flipped = false;

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

  bool get _deadlineUrgent {
    if (task.expiresAt == null) return false;
    final remaining = task.expiresAt!.difference(DateTime.now());
    return remaining.inSeconds <= 0 || remaining <= const Duration(minutes: 5);
  }

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
      child: GestureDetector(
        // Double-tap flips the card over (I-107); single tap still opens
        // the inspect sheet via the InkWell inside [_frontFace].
        onDoubleTap: () => setState(() => _flipped = !_flipped),
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: _flipped ? 1 : 0),
          duration: const Duration(milliseconds: 380),
          curve: Curves.easeInOutCubic,
          builder: (context, t, _) {
            final angle = t * pi;
            final back = angle > pi / 2;
            return Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..setEntry(3, 2, 0.0012)
                ..rotateY(angle),
              child: back
                  ? Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.identity()..rotateY(pi),
                      child: _backFace(),
                    )
                  : _frontFace(),
            );
          },
        ),
      ),
    );
  }

  BoxDecoration get _cardDecoration => BoxDecoration(
        color: PopColors.surface,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 30,
            offset: const Offset(0, 10),
          ),
        ],
      );

  Widget _frontFace() {
    return Container(
      decoration: _cardDecoration,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: widget.onInspect,
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _header(),
                    if (widget.revised) ...[
                      const SizedBox(height: 8),
                      _banner('更新されました', PopColors.green, animate: true),
                    ],
                    if (widget.rubberStamp) ...[
                      const SizedBox(height: 8),
                      _banner(
                        '連続承認検知 — 確認してから承認してください',
                        PopColors.orange,
                      ),
                    ],
                    const SizedBox(height: 8),
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
                    if (task.impact?.reversible != null) ...[
                      const SizedBox(height: 4),
                      _reversiblePill(),
                    ],
                    const SizedBox(height: 8),
                    for (final component in _frontComponents) ...[
                      ComponentRenderer(
                        component: component,
                        onAction: widget.onQuickAction,
                        onInspect: widget.onInspect,
                        selectedRowIds: widget.selectedRowIds,
                        onRowToggle: widget.onRowToggle,
                        editable: task.editable,
                        editedValue: widget.editedValue,
                        onEditedValue: widget.onEditedValue,
                      ),
                      const SizedBox(height: 8),
                    ],
                    _metaLine(),
                    _approvalFooter(),
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
    );
  }

  /// Back face of the card (I-107): 検証 — 根拠 / 誰が / 参加者 / 出典
  /// quote-block. Pure context, no decision controls; double-tap returns.
  Widget _backFace() {
    return Container(
      decoration: _cardDecoration,
      child: Material(
        color: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.flip_to_front,
                      size: 16, color: PopColors.text3),
                  SizedBox(width: 6),
                  Text(
                    '裏面 — 根拠と出典',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: PopColors.text2,
                    ),
                  ),
                  Spacer(),
                  Text('ダブルタップで戻す',
                      style:
                          TextStyle(fontSize: 11, color: PopColors.text3)),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: _hasDetails
                    ? SingleChildScrollView(
                        child: _DetailsPanel(
                          task: task,
                          movedTexts: _movedTexts,
                          deadlineUrgent: _deadlineUrgent,
                        ),
                      )
                    : const Center(
                        child: Text(
                          '裏面の情報はありません',
                          style: TextStyle(
                              fontSize: 13, color: PopColors.text3),
                        ),
                      ),
              ),
            ],
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
                  task.agent.name.isNotEmpty
                      ? task.agent.name.characters.first
                      : '?',
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
        if (widget.delegatedTo != null)
          Container(
            margin: const EdgeInsets.only(right: 8),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: PopColors.fill2,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '→${widget.delegatedTo}',
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: PopColors.text2),
            ),
          ),
        if (widget.deliveryFailed)
          const Padding(
            padding: EdgeInsets.only(right: 6),
            child: Tooltip(
              message: 'エージェントへの返送に失敗しました',
              child: Icon(Icons.warning_amber_rounded,
                  size: 16, color: PopColors.orange),
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

  /// Multi-approver footer (I-602): 「承認 a/b」 while earlier devices
  /// have recorded approvals below the required quorum.
  Widget _approvalFooter() {
    if (task.requiredApprovals <= 1) return const SizedBox.shrink();
    if (widget.approvalCount <= 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        '承認 ${widget.approvalCount}/${task.requiredApprovals}',
        style: const TextStyle(
          fontSize: 13,
          fontFeatures: [FontFeature.tabularFigures()],
          fontWeight: FontWeight.w700,
          color: PopColors.blue,
        ),
      ),
    );
  }
  /// Tiny reversibility pill for the front face only (never the back):
  /// 「取り消し可」 when reversible, 「取り消し不可」 only when explicitly
  /// false. Null (unknown) renders nothing — never guess.
  Widget _reversiblePill() {
    final reversible = task.impact?.reversible;
    if (reversible == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: reversible
            ? PopColors.fill2
            : PopColors.red.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        reversible ? '取り消し可' : '取り消し不可',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: reversible ? PopColors.text2 : PopColors.red,
        ),
      ),
    );
  }

  /// Small notice band on the front (wave-2): revised / rubber-stamp.
  Widget _banner(String text, Color color, {bool animate = false}) {
    final band = Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        text,
        style: TextStyle(
            fontSize: 12, fontWeight: FontWeight.w800, color: color),
      ),
    );
    if (!animate) return band;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutCubic,
      builder: (context, t, _) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: band,
      ),
    );
  }

  /// Meta: ONLY the urgent countdown (<=5m / past). 信頼度 is gone
  /// (user decision); the full deadline lives in 詳細 — one place, never two.
  Widget _metaLine() {
    if (task.expiresAt == null) return const SizedBox.shrink();
    final remaining = task.expiresAt!.difference(DateTime.now());
    final urgent =
        remaining.inSeconds <= 0 || remaining <= const Duration(minutes: 5);
    if (!urgent) return const SizedBox.shrink();
    final when = remaining.inSeconds <= 0
        ? '期限切れ'
        : '残り ${_formatRemaining(remaining)}';
    return Text(
      when,
      style: const TextStyle(
        fontSize: 13,
        fontFeatures: [FontFeature.tabularFigures()],
        color: PopColors.red,
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
                    child: _DetailsPanel(
                          task: task,
                          movedTexts: _movedTexts,
                          onInspect: widget.onInspect,
                          deadlineUrgent: _deadlineUrgent,
                        ),
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
      final secondStage = widget.secondStageThreshold > 0 &&
          x.abs() >= widget.secondStageThreshold;
      final label = approve
          ? (secondStage
              ? '承認+自動化を提案'
              : (task.onSwipeRight?.label ?? 'APPROVE'))
          : (secondStage
              ? '却下+同種をミュート'
              : (task.onSwipeLeft?.label ?? 'REJECT'));
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
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: approve ? PopColors.green : PopColors.red,
                fontSize: secondStage ? 16 : 18,
                fontWeight: FontWeight.w800,
                letterSpacing: secondStage ? 0.5 : 2,
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
  final VoidCallback? onInspect;
  final bool deadlineUrgent;

  const _DetailsPanel({
    required this.task,
    this.movedTexts = const [],
    this.onInspect,
    this.deadlineUrgent = false,
  });

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
    final form = task.inspectForm;
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
            _rowWide(Icons.bolt, '結果',
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('承認すると ${impact!.summary}',
                      style: const TextStyle(
                          fontSize: 14, color: PopColors.text)),
                  if (impact.reversible == false)
                    const Text('この操作は取り消せません',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: PopColors.red)),
                ],
              ),
            ),
          if (narrative.isNotEmpty || ctx?.reasoning != null)
            _rowWide(Icons.lightbulb_outline, 'なぜ',
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
            _rowWide(Icons.mail_outline, '引用',
                ComponentRenderer(component: c)),
          if (ctx?.requesterName != null)
            _rowInline(Icons.person_outline, '誰が', Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 4,
              children: [
                Text(ctx!.requesterName!,
                    style: const TextStyle(
                        fontSize: 14, color: PopColors.text)),
                if (ctx.requesterOnBehalfOf != null)
                  Text('· ${ctx.requesterOnBehalfOf} の依頼',
                      style: const TextStyle(
                          fontSize: 13, color: PopColors.text2)),
              ],
            )),
          if (ctx != null && ctx.participants.isNotEmpty)
            _rowInline(Icons.group_outlined, '参加者', Wrap(
              spacing: 6,
              runSpacing: 6,
              alignment: WrapAlignment.end,
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
            )),
          if (ctx?.sourceLabel != null)
            _rowInline(Icons.link, '出典', Text(
                ctx!.sourceLabel! + (ctx.sourceUrl != null ? ' ↗' : ''),
                style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: PopColors.blue))),
          if (impact?.costAmount != null && impact!.costCurrency != null)
            _rowInline(Icons.payments_outlined, '金額', Text(
                '${impact.costCurrency} ${_amount(impact.costAmount!)}',
                style: const TextStyle(
                    fontSize: 14,
                    fontFeatures: [FontFeature.tabularFigures()],
                    color: PopColors.text))),
          if (task.confidenceReasons.isNotEmpty)
            _rowInline(Icons.warning_amber_outlined, '注意点', Wrap(
              spacing: 6,
              runSpacing: 6,
              alignment: WrapAlignment.end,
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
            )),
          // 期限: shown here ONLY while the front shows no urgent
          // countdown — the deadline lives in exactly one place.
          if (task.expiresAt != null && !deadlineUrgent)
            _rowInline(Icons.schedule, '期限', Text(
                '${_formatDeadline(task.expiresAt!)} — ${_verb(task.onExpire)}',
                style: const TextStyle(
                    fontSize: 14,
                    fontFeatures: [FontFeature.tabularFigures()],
                    color: PopColors.text))),
          if (form.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 8),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('修正して承認'),
                  onPressed: onInspect,
                ),
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

  Widget _rowWide(IconData icon, String label, Widget value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _head(icon, label),
          const SizedBox(height: 5),
          value,
        ],
      ),
    );
  }

  Widget _rowInline(IconData icon, String label, Widget value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          _head(icon, label),
          const Spacer(),
          Flexible(child: value),
        ],
      ),
    );
  }

  Widget _head(IconData icon, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: PopColors.text3),
        const SizedBox(width: 7),
        Text(
          label,
          style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: PopColors.text2),
        ),
      ],
    );
  }
}
