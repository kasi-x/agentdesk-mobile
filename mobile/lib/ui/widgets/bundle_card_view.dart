import 'package:flutter/material.dart';

import '../../models/task_card.dart';
import '../colors.dart';

/// Group bundle card (I-201): several cards sharing a `groupKey` render
/// as one card — 「N件まとめ」 header, the first member's summary, and an
/// expandable per-item list. Swiping right (or a two-finger pinch)
/// approves every member via `POST /actions/bulk`; expanding lets each
/// member be handled individually.
class BundleCardView extends StatefulWidget {
  final List<TaskCard> tasks;
  final String Function(DateTime) timeAgo;
  final int swipePercentX;
  final int swipePercentY;

  /// Tapping a member leaves the bundle so that card can be swiped
  /// individually (and it comes to the top of the stack).
  final void Function(TaskCard task) onPickItem;
  final VoidCallback onInspect;

  const BundleCardView({
    super.key,
    required this.tasks,
    required this.timeAgo,
    required this.onPickItem,
    required this.onInspect,
    this.swipePercentX = 0,
    this.swipePercentY = 0,
  });

  @override
  State<BundleCardView> createState() => _BundleCardViewState();
}

class _BundleCardViewState extends State<BundleCardView> {
  bool _expanded = false;

  List<TaskCard> get _tasks => widget.tasks;
  TaskCard get _first => _tasks.first;

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
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _header(),
                      const SizedBox(height: 10),
                      Text(
                        _first.summary,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.3,
                          height: 1.3,
                          color: PopColors.text,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'すべてまとめて承認できます（右スワイプ）',
                        style: TextStyle(
                          fontSize: 12,
                          color: PopColors.text3,
                        ),
                      ),
                      const SizedBox(height: 4),
                      _itemList(),
                      const Spacer(),
                      _approveHint(),
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
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          decoration: BoxDecoration(
            color: PopColors.blue,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            '${_tasks.length}件まとめ',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: PopColors.text,
            ),
          ),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            _first.agent.name,
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
            color: PopColors.severityDot(_first.severity),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 9),
        Text(
          widget.timeAgo(_first.createdAt),
          style: const TextStyle(fontSize: 13, color: PopColors.text3),
        ),
      ],
    );
  }

  /// Per-item mini list: tap a member to take it out of the bundle so it
  /// can be triaged on its own.
  Widget _itemList() {
    return Container(
      decoration: BoxDecoration(
        color: PopColors.surface2,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              child: Row(
                children: [
                  Text(
                    _expanded ? 'まとめる' : '中身を見る (${_tasks.length})',
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: PopColors.blue),
                  ),
                  const Spacer(),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
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
            child: _expanded
                ? Column(
                    children: [
                      for (final task in _tasks)
                        InkWell(
                          onTap: () => widget.onPickItem(task),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
                            child: Row(
                              children: [
                                Container(
                                  width: 7,
                                  height: 7,
                                  decoration: BoxDecoration(
                                    color:
                                        PopColors.severityDot(task.severity),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    task.summary,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 13, color: PopColors.text),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const Icon(Icons.chevron_right,
                                    size: 16, color: PopColors.text3),
                              ],
                            ),
                          ),
                        ),
                    ],
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  Widget _approveHint() {
    return Row(
      children: [
        const Icon(Icons.check_circle_outline,
            size: 15, color: PopColors.green),
        const SizedBox(width: 6),
        Text(
          '右スワイプで ${_tasks.length}件をまとめて承認',
          style: const TextStyle(fontSize: 12, color: PopColors.text2),
        ),
      ],
    );
  }

  Widget _swipeOverlay() {
    final x = widget.swipePercentX;
    final y = widget.swipePercentY;
    if (x == 0 && y == 0) return const SizedBox.shrink();
    final opacity = (x.abs() / 100).clamp(0.0, 1.0);
    if (x <= 0) return const SizedBox.shrink();
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: const Color(0xFF1D3A2A).withValues(alpha: opacity * 0.85),
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle_outline,
              color: PopColors.green, size: 44),
          const SizedBox(height: 6),
          Text(
            'BULK APPROVE ×${_tasks.length}',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: PopColors.green,
              fontSize: 16,
              fontWeight: FontWeight.w800,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }
}
