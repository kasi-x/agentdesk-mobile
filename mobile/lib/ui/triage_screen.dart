import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_card_swiper/flutter_card_swiper.dart';
import 'package:provider/provider.dart';

import '../models/task_card.dart';
import '../models/triage_action.dart';
import '../services/task_repository.dart';
import 'inspect_sheet.dart';
import 'colors.dart';
import 'settings_screen.dart';
import 'widgets/hold_confirm.dart';
import 'widgets/task_card_view.dart';

class TriageScreen extends StatefulWidget {
  const TriageScreen({super.key});

  @override
  State<TriageScreen> createState() => _TriageScreenState();
}

class _TriageScreenState extends State<TriageScreen> {
  final CardSwiperController _controller = CardSwiperController();
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    final repo = context.read<TaskRepository>();
    repo.onToast = _showToast;
    repo.onConflict = _conflictHaptic;
    repo.start();
    _ticker = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) setState(() {}); // refresh elapsed + countdown labels (I-203)
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _showToast(String message, {String? undoableTaskId}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: Duration(
              seconds: undoableTaskId != null ? 5 : 3),
          action: undoableTaskId == null
              ? null
              : SnackBarAction(
                  label: '元に戻す',
                  onPressed: () =>
                      context.read<TaskRepository>().undo(undoableTaskId),
                ),
        ),
      );
  }

  /// Two short taps — the "rejected, too late" signal for a 409 (I-131).
  void _conflictHaptic() {
    HapticFeedback.selectionClick();
    Future<void>.delayed(const Duration(milliseconds: 90),
        HapticFeedback.selectionClick);
  }

  /// Optimistic: the card leaves the stack right now; the decision is
  /// delivered async and queued when offline (FR-2.1/2.2/2.3).
  void _triage(
    TaskCard task, {
    required String actionName,
    Map<String, dynamic>? data,
    required String source,
  }) {
    if (task.severity == 'critical') {
      HapticFeedback.heavyImpact();
    } else {
      HapticFeedback.mediumImpact();
    }
    context
        .read<TaskRepository>()
        .triage(task, actionName: actionName, data: data, source: source);
  }

  void _inspect(TaskCard task) {
    HapticFeedback.selectionClick();
    showInspectSheet(context, task, (data) {
      final binding = task.onSwipeRight;
      _triage(
        task,
        actionName: binding?.actionName ?? 'approve',
        data: data,
        source: ActionSource.inspectForm,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<TaskRepository>();
    final tasks = repo.stack;
    return Scaffold(
      appBar: AppBar(
        title: const Text('AgentDesk',
            style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          const SizedBox(width: 4),
          _PendingBadge(count: tasks.length),
          ValueListenableBuilder<bool>(
            valueListenable: repo.connected,
            builder: (_, connected, __) => Padding(
              padding: const EdgeInsets.only(left: 10),
              child: Tooltip(
                message: connected ? '接続中' : '再接続中…',
                child: Icon(
                  Icons.circle,
                  size: 10,
                  color: connected
                      ? const Color(0xFF7BE494)
                      : const Color(0xFFFFB020),
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () =>
                Navigator.of(context).push(SettingsScreen.route()),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: tasks.isEmpty
          ? _EmptyState(reconnecting: !repo.connected.value)
          : _buildStack(tasks),
    );
  }

  /// Swipe "weight" follows the top card's risk (I-102): high-risk cards
  /// need a longer drag; locked cards (critical + irreversible) can't be
  /// right-swiped at all and require the hold-to-confirm ring (I-103).
  Widget _buildStack(List<TaskCard> tasks) {
    final top = tasks.first;
    final risk = riskLevel(top);
    final locked = risk == RiskLevel.locked;
    return Stack(
      children: [
        CardSwiper(
          controller: _controller,
          cardsCount: tasks.length,
          isLoop: false,
          numberOfCardsDisplayed: tasks.length >= 3 ? 3 : tasks.length,
          threshold: risk == RiskLevel.high ? 90 : 50,
          allowedSwipeDirection: AllowedSwipeDirection.only(
            right: !locked,
            left: true,
            up: false, // inspect is tap-only; an up-swipe cannot be cancelled
            down: true,
          ),
          backCardOffset: const Offset(0, -24),
          onSwipe: _onSwipe,
          cardBuilder: (context, index, percentThresholdX, percentThresholdY) {
            final task = tasks[index];
            return _ThresholdHaptic(
              percentThresholdX: percentThresholdX,
              percentThresholdY: percentThresholdY,
              child: TaskCardView(
                task: task,
                timeAgo: timeAgo,
                swipePercentX: percentThresholdX,
                swipePercentY: percentThresholdY,
                onQuickAction: (binding) => _triage(
                  task,
                  actionName: binding.actionName,
                  data: binding.payload,
                  source: ActionSource.quickChip,
                ),
                onInspect: () => _inspect(task),
              ),
            );
          },
        ),
        // Bottom action bar (I-134): same movements as the gestures via
        // CardSwiperController.swipe(); on locked cards the ✓ slot becomes
        // the hold-to-confirm ring (I-103).
        Positioned(
          left: 0,
          right: 0,
          bottom: 10,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _BarAction(
                icon: Icons.close,
                label: top.onSwipeLeft?.label ?? '拒否',
                onTap: () =>
                    _controller.swipe(CardSwiperDirection.left),
              ),
              _BarAction(
                icon: Icons.snooze,
                label: 'あとで',
                onTap: () =>
                    _controller.swipe(CardSwiperDirection.bottom),
              ),
              if (locked)
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    HoldConfirmButton(
                      label: top.onSwipeRight?.label ?? 'Approve',
                      onConfirmed: () => _triage(
                        top,
                        actionName:
                            top.onSwipeRight?.actionName ?? 'approve',
                        data: top.onSwipeRight?.payload,
                        source: ActionSource.holdConfirm,
                      ),
                    ),
                    const Text(
                      '長押しで承認',
                      style:
                          TextStyle(fontSize: 10, color: Colors.white38),
                    ),
                  ],
                )
              else
                _BarAction(
                  icon: Icons.check,
                  label: top.onSwipeRight?.label ?? '承認',
                  onTap: () =>
                      _controller.swipe(CardSwiperDirection.right),
                ),
            ],
          ),
        ),
      ],
    );
  }

  FutureOr<bool> _onSwipe(
    int previousIndex,
    int? currentIndex,
    CardSwiperDirection direction,
  ) {
    final repo = context.read<TaskRepository>();
    final tasks = repo.stack;
    if (previousIndex < 0 || previousIndex >= tasks.length) return false;
    final task = tasks[previousIndex];
    // Locked cards (critical + irreversible) cannot be approved by
    // swipe — belt-and-braces guard in case the direction filter misses.
    if (direction == CardSwiperDirection.right &&
        riskLevel(task) == RiskLevel.locked) {
      return false;
    }
    if (direction == CardSwiperDirection.right) {
      final binding = task.onSwipeRight;
      _triage(
        task,
        actionName: binding?.actionName ?? 'approve',
        data: binding?.payload,
        source: ActionSource.swipeGesture,
      );
    } else if (direction == CardSwiperDirection.left) {
      _rejectWithReasons(task);
    } else if (direction == CardSwiperDirection.bottom) {
      repo.snooze(task.taskId);
    } else {
      return false;
    }
    return true;
  }

  /// Reject path (I-118): when the agent supplied `rejectReasons`, a
  /// short-lived chip row asks why before the decision leaves. Ignoring
  /// it (timeout or dismiss) still confirms without a reason.
  Future<void> _rejectWithReasons(TaskCard task) async {
    final binding = task.onSwipeLeft;
    var data = binding?.payload;
    if (task.rejectReasons.isNotEmpty && mounted) {
      final reasonId = await showModalBottomSheet<String>(
        context: context,
        builder: (context) => _RejectReasonSheet(reasons: task.rejectReasons),
      );
      if (reasonId != null) {
        data = <String, dynamic>{
          if (data != null) ...data,
          'reason': reasonId,
        };
      }
    }
    _triage(
      task,
      actionName: binding?.actionName ?? 'reject',
      data: data,
      source: ActionSource.swipeGesture,
    );
  }

}
String timeAgo(DateTime time) {
  final diff = DateTime.now().difference(time);
  if (diff.inSeconds < 60) return 'now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m';
  if (diff.inHours < 24) return '${diff.inHours}h';
  return '${diff.inDays}d';
}

class _PendingBadge extends StatelessWidget {
  final int count;

  const _PendingBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: PopColors.blue,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$count pending',
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          color: PopColors.text,
        ),
      ),
    );
  }
}

/// Round button in the bottom action bar (I-134). Tap triggers the same
/// swipe animation the gesture would via [CardSwiperController].
class _BarAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _BarAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          icon: Icon(icon),
          iconSize: 30,
          color: Colors.white70,
          tooltip: label,
        ),
        Text(
          label,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 10, color: Colors.white38),
        ),
      ],
    );
  }
}

/// Fires one `selectionClick` the moment the drag crosses the swipe
/// threshold (I-131). `percentThreshold*` are 0-100+ values handed down
/// by CardSwiper; the click re-arms only after the card falls back below
/// a lower bound so a jittery finger cannot spam the click.
class _ThresholdHaptic extends StatefulWidget {
  final int percentThresholdX;
  final int percentThresholdY;
  final Widget child;

  const _ThresholdHaptic({
    required this.percentThresholdX,
    required this.percentThresholdY,
    required this.child,
  });

  @override
  State<_ThresholdHaptic> createState() => _ThresholdHapticState();
}

class _ThresholdHapticState extends State<_ThresholdHaptic> {
  bool _armed = true;

  @override
  void didUpdateWidget(_ThresholdHaptic oldWidget) {
    super.didUpdateWidget(oldWidget);
    final percent = max(
      widget.percentThresholdX.abs(),
      widget.percentThresholdY.abs(),
    );
    if (_armed && percent >= 100) {
      _armed = false;
      HapticFeedback.selectionClick();
    } else if (!_armed && percent < 40) {
      _armed = true;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Chip row of agent-supplied reject reasons (I-118). Tapping a chip
/// completes with its id; dismissing or the 4s timer completes with null
/// (reject without a reason).
class _RejectReasonSheet extends StatefulWidget {
  final List<RejectReason> reasons;

  const _RejectReasonSheet({required this.reasons});

  @override
  State<_RejectReasonSheet> createState() => _RejectReasonSheetState();
}

class _RejectReasonSheetState extends State<_RejectReasonSheet> {
  bool _done = false;

  @override
  void initState() {
    super.initState();
    Timer(const Duration(seconds: 4), () {
      if (!_done && mounted) Navigator.of(context).pop();
    });
  }

  void _pick(String? id) {
    if (_done) return;
    _done = true;
    Navigator.of(context).pop(id);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '却下の理由 (任意)',
              style: TextStyle(fontSize: 13, color: Colors.white70),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final reason in widget.reasons)
                  ActionChip(
                    label: Text(reason.label),
                    onPressed: () => _pick(reason.id),
                  ),
                ActionChip(
                  label: const Text('理由なしで却下'),
                  onPressed: () => _pick(null),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool reconnecting;

  const _EmptyState({required this.reconnecting});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.task_alt,
            size: 56,
            color: Colors.white.withValues(alpha: 0.15),
          ),
          const SizedBox(height: 16),
          const Text(
            'All clear',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            reconnecting ? 'ハブに再接続中…' : 'エージェントの判断待ちはありません',
            style: TextStyle(fontSize: 13, color: Colors.white.withValues(alpha: 0.4)),
          ),
        ],
      ),
    );
  }
}
