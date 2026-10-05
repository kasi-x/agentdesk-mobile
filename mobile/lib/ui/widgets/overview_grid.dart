import 'package:flutter/material.dart';

import '../../models/task_card.dart';
import '../colors.dart';

/// Overview grid (I-105): pinch-in on the stack replaces it with small
/// tiles plus per-agent / per-severity counts. Tapping a tile brings
/// that card back to the top; pinch-out (or the close button) returns to
/// the stack.
class OverviewGrid extends StatelessWidget {
  final List<TaskCard> tasks;
  final void Function(TaskCard task) onPick;
  final VoidCallback onClose;

  const OverviewGrid({
    super.key,
    required this.tasks,
    required this.onPick,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final byAgent = <String, int>{};
    final bySeverity = <String, int>{};
    for (final task in tasks) {
      byAgent[task.agent.name] = (byAgent[task.agent.name] ?? 0) + 1;
      bySeverity[task.severity] = (bySeverity[task.severity] ?? 0) + 1;
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onScaleUpdate: (details) {
        if (details.scale > 1.1) onClose();
      },
      child: Container(
        color: PopColors.bg,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 12, 4),
                child: Row(
                  children: [
                    Text(
                      '俯瞰 · ${tasks.length}',
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.w800),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: '山札に戻る',
                      onPressed: onClose,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final entry in byAgent.entries)
                      _SummaryChip(
                          icon: Icons.smart_toy_outlined,
                          label: '${entry.key} ×${entry.value}'),
                    for (final entry in bySeverity.entries)
                      _SummaryChip(
                          dot: PopColors.severityDot(entry.key),
                          label: '${_severityLabel(entry.key)} ×${entry.value}'),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 1.35,
                  ),
                  itemCount: tasks.length,
                  itemBuilder: (context, index) =>
                      _Tile(task: tasks[index], onTap: () => onPick(tasks[index])),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _severityLabel(String severity) => switch (severity) {
        'critical' => '重大',
        'warning' => '注意',
        _ => '通常',
      };
}

class _SummaryChip extends StatelessWidget {
  final IconData? icon;
  final Color? dot;
  final String label;

  const _SummaryChip({this.icon, this.dot, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        color: PopColors.fill2,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null)
            Icon(icon, size: 14, color: PopColors.text2)
          else if (dot != null)
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
          const SizedBox(width: 6),
          Text(label,
              style: const TextStyle(fontSize: 12, color: PopColors.text2)),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  final TaskCard task;
  final VoidCallback onTap;

  const _Tile({required this.task, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: PopColors.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: PopColors.severityDot(task.severity),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    task.agent.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: PopColors.text2),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Text(
                task.summary,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13, height: 1.3, color: PopColors.text),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
