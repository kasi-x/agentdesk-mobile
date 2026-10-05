import 'package:flutter/material.dart';

import '../../models/task_card.dart';
import '../colors.dart';

/// Choose card (decisionKind == 'choose', I-111): choice A fills the top
/// half, choice B the bottom half (labels from `choices[]`). Swipe up
/// commits the first choice, swipe down the second; left/right are
/// disabled and rejection happens through the bottom-bar ✕ only.
class ChoiceCardView extends StatelessWidget {
  final TaskCard task;
  final String Function(DateTime) timeAgo;
  final int swipePercentY;

  /// `onChoose(0)` commits the top choice, `onChoose(1)` the bottom one.
  final void Function(int index) onChoose;
  final VoidCallback onInspect;

  /// Volatile badges provided by the repository.
  final String? delegatedTo;
  final int approvalCount;
  final bool rubberStamp;

  const ChoiceCardView({
    super.key,
    required this.task,
    required this.timeAgo,
    required this.onChoose,
    required this.onInspect,
    this.swipePercentY = 0,
    this.delegatedTo,
    this.approvalCount = 0,
    this.rubberStamp = false,
  });

  List<String> get _labels => <String>[
        if (task.choices.isNotEmpty) task.choices[0].label else 'A',
        if (task.choices.length > 1) task.choices[1].label else 'B',
      ];

  @override
  Widget build(BuildContext context) {
    final labels = _labels;
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
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _header(),
                    const SizedBox(height: 10),
                    if (rubberStamp) ...[
                      _banner('連続承認検知 — 確認してから選んでください', PopColors.orange),
                      const SizedBox(height: 8),
                    ],
                    GestureDetector(
                      onTap: onInspect,
                      child: Text(
                        task.summary,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.3,
                          height: 1.3,
                          color: PopColors.text,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: _choiceTile(
                        index: 0,
                        icon: Icons.arrow_upward,
                        label: labels[0],
                        active: swipePercentY > 0,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: _choiceTile(
                        index: 1,
                        icon: Icons.arrow_downward,
                        label: labels[1],
                        active: swipePercentY < 0,
                      ),
                    ),
                  ],
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(child: _swipeOverlay(labels)),
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
          child: Text(
            task.agent.name.isNotEmpty ? task.agent.name.characters.first : '?',
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
        if (delegatedTo != null)
          Container(
            margin: const EdgeInsets.only(right: 8),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: PopColors.fill2,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '→$delegatedTo',
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: PopColors.text2),
            ),
          ),
        if (task.requiredApprovals > 1)
          Container(
            margin: const EdgeInsets.only(right: 8),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: PopColors.fill2,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '承認 $approvalCount/${task.requiredApprovals}',
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: PopColors.text2),
            ),
          ),
        Text(
          timeAgo(task.createdAt),
          style: const TextStyle(fontSize: 13, color: PopColors.text3),
        ),
      ],
    );
  }

  Widget _banner(String text, Color color) {
    return Container(
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
  }

  Widget _choiceTile({
    required int index,
    required IconData icon,
    required String label,
    required bool active,
  }) {
    return GestureDetector(
      onTap: () => onChoose(index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF1D3A2A) : PopColors.surface2,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: active
                ? PopColors.green
                : PopColors.separator.withValues(alpha: 0.4),
            width: 1.5,
          ),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon,
                size: 22,
                color: active ? PopColors.green : PopColors.text2),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: active ? PopColors.green : PopColors.text,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _swipeOverlay(List<String> labels) {
    if (swipePercentY == 0) return const SizedBox.shrink();
    final first = swipePercentY > 0;
    final opacity = (swipePercentY.abs() / 100).clamp(0.0, 1.0);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: const Color(0xFF1D3A2A).withValues(alpha: opacity * 0.85),
      ),
      alignment: first ? Alignment.topCenter : Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              first ? Icons.arrow_upward : Icons.arrow_downward,
              color: PopColors.green,
              size: 40,
            ),
            const SizedBox(height: 6),
            Text(
              first ? labels[0] : labels[1],
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: PopColors.green,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
