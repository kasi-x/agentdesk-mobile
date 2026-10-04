import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_card_swiper/flutter_card_swiper.dart';
import 'package:provider/provider.dart';

import '../models/task_card.dart';
import '../models/triage_action.dart';
import '../services/task_repository.dart';
import 'inspect_sheet.dart';
import 'settings_screen.dart';
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
    repo.start();
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {}); // refresh elapsed-time labels
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _showToast(String message) {
    if (!mounted) return;
    final repo = context.read<TaskRepository>();
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    // The hub holds triage replies for UNDO_GRACE_MS (I-104): offer reversal.
    if (message == '処理しました' && repo.lastUndoneTaskId != null) {
      messenger.showSnackBar(
        SnackBar(
          content: const Text('処理しました'),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: '元に戻す',
            onPressed: () => unawaited(repo.undoLast()),
          ),
        ),
      );
    } else {
      messenger.showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
    }
  }

  /// Optimistic: the card leaves the stack right now; the decision is
  /// delivered async and queued when offline (FR-2.1/2.2/2.3).
  void _triage(
    TaskCard task, {
    required String actionName,
    Map<String, dynamic>? data,
    required String source,
  }) {
    final risk = riskLevel(task);
    if (risk == RiskLevel.critical) {
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
      bottomNavigationBar: tasks.isEmpty
          ? null
          : _ActionBar(
              task: tasks.first,
              onApprove: () {
                final task = tasks.first;
                final binding = task.onSwipeRight;
                _triage(
                  task,
                  actionName: binding?.actionName ?? 'approve',
                  data: binding?.payload,
                  source: ActionSource.swipeGesture,
                );
              },
              onReject: () {
                final task = tasks.first;
                final binding = task.onSwipeLeft;
                _triage(
                  task,
                  actionName: binding?.actionName ?? 'reject',
                  data: binding?.payload,
                  source: ActionSource.swipeGesture,
                );
              },
              onSnooze: () =>
                  context.read<TaskRepository>().snooze(tasks.first.taskId),
            ),
    );
  }

  Widget _buildStack(List<TaskCard> tasks) {
    // I-102: heavier cards need a longer drag (default 50px). Critical cards
    // disable swipe-approve entirely — the action bar's hold-to-confirm
    // (I-103/I-134) is the only approve path.
    final topRisk = tasks.isEmpty ? RiskLevel.low : riskLevel(tasks.first);
    return CardSwiper(
      controller: _controller,
      cardsCount: tasks.length,
      isLoop: false,
      threshold: switch (topRisk) {
        RiskLevel.critical => 10000, // effectively swipe-locked
        RiskLevel.high => 120,
        RiskLevel.low => 50,
      },
      numberOfCardsDisplayed: tasks.length >= 3 ? 3 : tasks.length,
      allowedSwipeDirection: AllowedSwipeDirection.only(
        // Critical + irreversible: no swipe-approve (long-press instead).
        right: topRisk != RiskLevel.critical,
        left: true,
        up: false, // inspect is tap-only; an up-swipe cannot be cancelled
        down: true,
      ),
      backCardOffset: const Offset(0, -24),
      onSwipe: _onSwipe,
      cardBuilder: (context, index, percentThresholdX, percentThresholdY) {
        final task = tasks[index];
        return TaskCardView(
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
        );
      },
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
    if (direction == CardSwiperDirection.right) {
      final binding = task.onSwipeRight;
      _triage(
        task,
        actionName: binding?.actionName ?? 'approve',
        data: binding?.payload,
        source: ActionSource.swipeGesture,
      );
    } else if (direction == CardSwiperDirection.left) {
      final binding = task.onSwipeLeft;
      _triage(
        task,
        actionName: binding?.actionName ?? 'reject',
        data: binding?.payload,
        source: ActionSource.swipeGesture,
      );
    } else if (direction == CardSwiperDirection.bottom) {
      HapticFeedback.selectionClick();
      repo.snooze(task.taskId);
    } else {
      return false;
    }
    return true;
  }
}

/// Thumb-reach action bar (I-134): ✕ / 後で / ✓. On critical-risk cards
/// the ✓ becomes a hold-to-confirm ring (I-103) — release early to cancel.
class _ActionBar extends StatefulWidget {
  final TaskCard task;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onSnooze;

  const _ActionBar({
    required this.task,
    required this.onApprove,
    required this.onReject,
    required this.onSnooze,
  });

  @override
  State<_ActionBar> createState() => _ActionBarState();
}

class _ActionBarState extends State<_ActionBar> {
  double _hold = 0;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startHold() {
    _timer?.cancel();
    const steps = 20;
    var tick = 0;
    _timer = Timer.periodic(const Duration(milliseconds: 30), (t) {
      tick++;
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _hold = tick / steps);
      if (tick >= steps) {
        t.cancel();
        HapticFeedback.heavyImpact();
        widget.onApprove();
      }
    });
  }

  void _cancelHold() {
    _timer?.cancel();
    if (mounted) setState(() => _hold = 0);
  }

  @override
  Widget build(BuildContext context) {
    final critical = riskLevel(widget.task) == RiskLevel.critical;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.close, size: 18),
                label: const Text('却下'),
                onPressed: () {
                  HapticFeedback.mediumImpact();
                  widget.onReject();
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.schedule, size: 18),
                label: const Text('後で'),
                onPressed: () {
                  HapticFeedback.selectionClick();
                  widget.onSnooze();
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: critical
                  ? GestureDetector(
                      onLongPressStart: (_) => _startHold(),
                      onLongPressEnd: (_) => _cancelHold(),
                      onLongPressCancel: _cancelHold,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          FilledButton.icon(
                            icon: const Icon(Icons.fingerprint, size: 18),
                            label: const Text('長押し承認'),
                            onPressed: () {},
                          ),
                          Positioned.fill(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: FractionallySizedBox(
                                alignment: Alignment.centerLeft,
                                widthFactor: _hold,
                                child: Container(
                                  color: Colors.white.withOpacity(0.3),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : FilledButton.icon(
                      icon: const Icon(Icons.check, size: 18),
                      label: const Text('承認'),
                      onPressed: () {
                        HapticFeedback.mediumImpact();
                        widget.onApprove();
                      },
                    ),
            ),
          ],
        ),
      ),
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
        color: const Color(0xFF5B8DEF).withOpacity(0.18),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFF5B8DEF).withOpacity(0.5)),
      ),
      child: Text(
        '$count pending',
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: Color(0xFF9FC0FF),
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
            color: Colors.white.withOpacity(0.15),
          ),
          const SizedBox(height: 16),
          const Text(
            'All clear',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            reconnecting ? 'ハブに再接続中…' : 'エージェントの判断待ちはありません',
            style: TextStyle(fontSize: 13, color: Colors.white.withOpacity(0.4)),
          ),
        ],
      ),
    );
  }
}
