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
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
  }

  /// Optimistic: the card leaves the stack right now; the decision is
  /// delivered async and queued when offline (FR-2.1/2.2/2.3).
  void _triage(
    TaskCard task, {
    required String actionName,
    Map<String, dynamic>? data,
    required String source,
  }) {
    HapticFeedback.mediumImpact();
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

  Widget _buildStack(List<TaskCard> tasks) {
    return CardSwiper(
      controller: _controller,
      cardsCount: tasks.length,
      isLoop: false,
      numberOfCardsDisplayed: tasks.length >= 3 ? 3 : tasks.length,
      allowedSwipeDirection: const AllowedSwipeDirection.only(
        right: true,
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

  void _onSwipe(
    int previousIndex,
    int? currentIndex,
    CardSwiperDirection direction,
  ) {
    final repo = context.read<TaskRepository>();
    final tasks = repo.stack;
    if (previousIndex < 0 || previousIndex >= tasks.length) return;
    final task = tasks[previousIndex];
    switch (direction) {
      case CardSwiperDirection.right:
        final binding = task.onSwipeRight;
        _triage(
          task,
          actionName: binding?.actionName ?? 'approve',
          data: binding?.payload,
          source: ActionSource.swipeGesture,
        );
        break;
      case CardSwiperDirection.left:
        final binding = task.onSwipeLeft;
        _triage(
          task,
          actionName: binding?.actionName ?? 'reject',
          data: binding?.payload,
          source: ActionSource.swipeGesture,
        );
        break;
      case CardSwiperDirection.down:
        repo.snooze(task.taskId);
        break;
      default:
        break;
    }
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
