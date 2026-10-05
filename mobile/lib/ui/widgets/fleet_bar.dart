import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/task_card.dart';
import '../colors.dart';

/// Fleet lanes (I-603/I-122): horizontal avatar row under the app bar —
/// one chip per agent present in the current stack. Tap toggles a filter
/// (the stack shows only that agent; tap again or すべて clears).
/// Practice / overview / reject-sheet flows are untouched: the bar only
/// filters which cards the stack renders.
class FleetBar extends StatelessWidget {
  final List<TaskCard> stack;
  final Map<String, int> pendingByAgent;
  final String? selectedAgent;
  final ValueChanged<String?> onSelect;

  const FleetBar({
    super.key,
    required this.stack,
    required this.pendingByAgent,
    required this.selectedAgent,
    required this.onSelect,
  });

  /// Agents in first-appearance order in the current stack.
  static List<String> agentsIn(List<TaskCard> stack) {
    final seen = <String>[];
    for (final task in stack) {
      if (!seen.contains(task.agent.name)) seen.add(task.agent.name);
    }
    return seen;
  }

  /// Avatar URL for [agentName], if any card carries one.
  static String? avatarFor(List<TaskCard> stack, String agentName) {
    for (final task in stack) {
      if (task.agent.name == agentName && task.agent.avatarUrl != null) {
        return task.agent.avatarUrl;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final agents = agentsIn(stack);
    if (agents.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          _FleetChip(
            label: 'すべて',
            count: stack.length,
            selected: selectedAgent == null,
            avatarUrl: null,
            agentName: null,
            onSelect: onSelect,
          ),
          for (final agent in agents)
            _FleetChip(
              label: agent,
              count: pendingByAgent[agent] ?? 0,
              selected: selectedAgent == agent,
              avatarUrl: avatarFor(stack, agent),
              agentName: agent,
              onSelect: onSelect,
            ),
        ],
      ),
    );
  }
}

class _FleetChip extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;
  final String? avatarUrl;
  final String? agentName;
  final ValueChanged<String?> onSelect;

  const _FleetChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.avatarUrl,
    required this.agentName,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        selected: selected,
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Avatar(label: label, url: avatarUrl),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(fontSize: 12)),
            const SizedBox(width: 4),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: PopColors.fill2,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '$count',
                style: const TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
        onSelected: (_) {
          HapticFeedback.selectionClick();
          // Tapping the active chip clears; tapping すべて clears too.
          if (agentName == null || selected) {
            onSelect(null);
          } else {
            onSelect(agentName);
          }
        },
      ),
    );
  }
}

/// Initial fallback with a silent network-avatar upgrade: fetch failures
/// fall back to the initial without logging or retrying (fleet polish).
class _Avatar extends StatelessWidget {
  final String label;
  final String? url;

  const _Avatar({required this.label, required this.url});

  @override
  Widget build(BuildContext context) {
    final initial = label.isEmpty ? '？' : label.characters.first;
    final fallback = CircleAvatar(
      radius: 11,
      backgroundColor: PopColors.fill2,
      child: Text(initial,
          style: const TextStyle(fontSize: 11, color: PopColors.text)),
    );
    if (url == null || url!.isEmpty) return fallback;
    return CircleAvatar(
      radius: 11,
      backgroundColor: PopColors.fill2,
      child: ClipOval(
        child: Image.network(
          url!,
          width: 22,
          height: 22,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Center(
            child: Text(initial,
                style:
                    const TextStyle(fontSize: 11, color: PopColors.text)),
          ),
        ),
      ),
    );
  }
}
