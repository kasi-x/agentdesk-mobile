import 'package:flutter/material.dart';

import '../colors.dart';

/// Second gesture vocabulary (I-108): while a card is held, four corner
/// drop targets appear. The corner assignment is fixed for now
/// (user-remapping is a later item).
enum DropAction {
  /// 右上: snooze locally until roughly an hour later.
  snoozeHour,

  /// 右下: snooze locally until tomorrow morning.
  snoozeMorning,

  /// 左下: open the inspect sheet to ask a question.
  ask,

  /// 左上: hand the card to a colleague (not wired yet).
  delegate,
}

/// Dimmed overlay with the four corner targets. The parent tracks the
/// pointer and reports which [DropAction] (if any) is hovered; the
/// overlay itself is hit-test transparent so the parent's raw [Listener]
/// keeps receiving move/up events.
class DropZoneOverlay extends StatelessWidget {
  final DropAction? hovered;

  const DropZoneOverlay({super.key, this.hovered});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.55),
      child: Stack(
        children: [
          const Center(
            child: Text(
              'カードを掴んだまま四隅へ\n指を離して実行',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: PopColors.text2,
              ),
            ),
          ),
          Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: _Zone(
                icon: Icons.forward_to_inbox,
                label: '同僚に回す',
                active: hovered == DropAction.delegate,
              ),
            ),
          ),
          Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: _Zone(
                icon: Icons.schedule,
                label: '1時間後',
                active: hovered == DropAction.snoozeHour,
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: _Zone(
                icon: Icons.help_outline,
                label: '質問する',
                active: hovered == DropAction.ask,
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomRight,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: _Zone(
                icon: Icons.wb_twilight,
                label: '明日朝',
                active: hovered == DropAction.snoozeMorning,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Zone extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;

  const _Zone({required this.icon, required this.label, required this.active});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      width: 116,
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        color: active ? PopColors.blue : PopColors.surface2,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: active ? PopColors.blue : PopColors.separator,
          width: 1.5,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 26, color: active ? Colors.white : PopColors.text2),
          const SizedBox(height: 7),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: active ? Colors.white : PopColors.text2,
            ),
          ),
        ],
      ),
    );
  }
}
