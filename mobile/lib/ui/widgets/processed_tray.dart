import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/task_repository.dart';
import '../colors.dart';

/// Processed tray (I-120): a collapsed bottom-edge strip showing today's
/// finished count; tap expands a date-grouped bottom sheet. Drag the
/// sheet down (or tap the scrim) to collapse it again.
///
/// Action glyphs: ✓ approve / ✕ reject / ⏾ snooze / ⧉ everything else
/// (other-device, auto, expire, withdraw). The row's source label is one
/// of user/snooze/auto/expire/withdraw/other (I-512).
class ProcessedTray extends StatelessWidget {
  const ProcessedTray({super.key});

  @override
  Widget build(BuildContext context) {
    final watched = context.watch<TaskRepository>();
    return GestureDetector(
      onVerticalDragEnd: (details) {
        // Strip itself is already collapsed; a downward fling is a no-op
        // kept for discoverability symmetry with the sheet drag.
        if ((details.primaryVelocity ?? 0) > 0) {
          HapticFeedback.selectionClick();
        }
      },
      onTap: () {
        HapticFeedback.selectionClick();
        showProcessedTray(context);
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: const BoxDecoration(
          color: PopColors.surface,
          border: Border(top: BorderSide(color: PopColors.borderSoft)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.drag_handle,
                size: 14, color: PopColors.text3),
            const SizedBox(width: 8),
            _MiniIcons(entries: watched.processed.take(5).toList()),
            const SizedBox(width: 8),
            Text(
              '今日 ${watched.processedTodayCount}件',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: PopColors.text2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Opens the expanded tray sheet directly.
Future<void> showProcessedTray(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => const ProcessedTraySheet(),
  );
}

/// Expanded bottom sheet: date-grouped rows (action icon, summary, time,
/// source label). Drag down or tap outside to collapse (sheet behavior).
class ProcessedTraySheet extends StatelessWidget {
  const ProcessedTraySheet({super.key});

  @override
  Widget build(BuildContext context) {
    final entries = context.watch<TaskRepository>().processed;
    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.92,
        builder: (context, controller) {
          if (entries.isEmpty) {
            return ListView(
              controller: controller,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
              children: const [
                Center(child: Icon(Icons.drag_handle, size: 16)),
                SizedBox(height: 12),
                Text(
                  'まだ処理したカードはありません',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: Colors.white54),
                ),
              ],
            );
          }
          final groups = _groupByDay(entries);
          return ListView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
            children: [
              const Center(child: Icon(Icons.drag_handle, size: 16)),
              const SizedBox(height: 4),
              for (final group in groups) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 4),
                  child: Text(
                    _dayLabel(group.first.at),
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: PopColors.text2,
                    ),
                  ),
                ),
                for (final entry in group)
                  _TrayRow(entry: entry),
              ],
            ],
          );
        },
      ),
    );
  }
}

List<List<ProcessedEntry>> _groupByDay(List<ProcessedEntry> entries) {
  final groups = <List<ProcessedEntry>>[];
  for (final entry in entries) {
    final at = entry.at;
    if (groups.isEmpty) {
      groups.add([entry]);
      continue;
    }
    final head = groups.last.first.at;
    if (head.year == at.year && head.month == at.month && head.day == at.day) {
      groups.last.add(entry);
    } else {
      groups.add([entry]);
    }
  }
  return groups;
}

String _dayLabel(DateTime at) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(at.year, at.month, at.day);
  final diff = today.difference(day).inDays;
  final date = '${at.month}/${at.day}';
  if (diff == 0) return '今日 $date';
  if (diff == 1) return '昨日 $date';
  return date;
}

/// Maps a tray action to its glyph color + label.
IconData actionIcon(String actionName) {
  switch (actionName) {
    case 'approve':
      return Icons.check;
    case 'reject':
      return Icons.close;
    case 'snooze':
      return Icons.snooze;
    default:
      return Icons.call_split;
  }
}

Color actionColor(String actionName) {
  switch (actionName) {
    case 'approve':
      return PopColors.green;
    case 'reject':
      return PopColors.red;
    case 'snooze':
      return PopColors.orange;
    default:
      return PopColors.text2;
  }
}

class _MiniIcons extends StatelessWidget {
  final List<ProcessedEntry> entries;

  const _MiniIcons({required this.entries});

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const Icon(Icons.inbox_outlined,
          size: 14, color: PopColors.text3);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final entry in entries)
          Padding(
            padding: const EdgeInsets.only(right: 2),
            child: Icon(
              actionIcon(entry.actionName),
              size: 13,
              color: actionColor(entry.actionName),
            ),
          ),
      ],
    );
  }
}

class _TrayRow extends StatelessWidget {
  final ProcessedEntry entry;

  const _TrayRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    final time =
        '${entry.at.hour.toString().padLeft(2, '0')}:${entry.at.minute.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(actionIcon(entry.actionName),
              size: 16, color: actionColor(entry.actionName)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.summary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
                Text(
                  '${entry.agentName} · $time · ${_sourceLabel(entry.source)}',
                  style: const TextStyle(
                      fontSize: 11, color: PopColors.text3),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _sourceLabel(String source) {
  switch (source) {
    case 'user':
      return 'user';
    case 'snooze':
      return 'snooze';
    case 'auto':
      return 'auto';
    case 'expire':
      return 'expire';
    case 'withdraw':
      return 'withdraw';
    default:
      return 'other';
  }
}
