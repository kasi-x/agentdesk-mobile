import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_card_swiper/flutter_card_swiper.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/task_card.dart';
import '../models/triage_action.dart';
import '../services/task_repository.dart';
import 'inspect_sheet.dart';
import 'colors.dart';
import 'settings_screen.dart';
import 'widgets/drop_zone_overlay.dart';
import 'widgets/hold_confirm.dart';
import 'widgets/overview_grid.dart';
import 'widgets/practice_screen.dart';
import 'widgets/reject_reason_sheet.dart';
import 'widgets/swipe_threshold_haptic.dart';
import 'widgets/task_card_view.dart';

class TriageScreen extends StatefulWidget {
  const TriageScreen({super.key});

  @override
  State<TriageScreen> createState() => _TriageScreenState();
}

class _TriageScreenState extends State<TriageScreen> {
  final CardSwiperController _controller = CardSwiperController();
  Timer? _ticker;

  /// Set while a horizontal drag sits past the second-stage threshold
  /// (I-101): 'right' | 'left' | null. Read on release by [_onSwipe].
  String? _secondStage;

  /// Pinch-in overview (I-105).
  bool _overview = false;

  /// Hold-for-drop-zones state (I-108).
  bool _dropMode = false;
  DropAction? _dropHover;
  Timer? _dropTimer;
  Offset _pointerDown = Offset.zero;
  Size _stackSize = Size.zero;

  /// Raw pointer tracking for pinch (manual, so CardSwiper's pan
  /// recognizer keeps the arena for swipes).
  final Map<int, Offset> _pointers = <int, Offset>{};
  double? _pinchBase;

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeShowPractice();
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _dropTimer?.cancel();
    super.dispose();
  }

  /// First-run onboarding (I-129): show the practice stack once, then
  /// never automatically again (replayable from Settings).
  Future<void> _maybeShowPractice() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('practice_seen') ?? false) return;
    if (!mounted) return;
    await Navigator.of(context).push(PracticeScreen.route());
    await prefs.setBool('practice_seen', true);
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
            icon: const Icon(Icons.grid_view_rounded),
            tooltip: '俯瞰',
            onPressed: tasks.isEmpty
                ? null
                : () => setState(() => _overview = true),
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
          : _overview
              ? OverviewGrid(
                  tasks: tasks,
                  onPick: (task) {
                    repo.bringToTop(task.taskId);
                    setState(() => _overview = false);
                  },
                  onClose: () => setState(() => _overview = false),
                )
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
    return LayoutBuilder(
      builder: (context, constraints) {
        _stackSize = constraints.biggest;
        // CardSwiper treats `threshold` as a pixel distance here; the
        // second stage (I-101) is ~85% of the card width.
        final thresholdPx = risk == RiskLevel.high ? 90 : 50;
        final cardWidth = constraints.maxWidth - 40;
        final secondStage =
            ((0.85 * cardWidth) / thresholdPx * 100).ceil();
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _handlePointerDown,
          onPointerMove: _handlePointerMove,
          onPointerUp: _handlePointerUp,
          onPointerCancel: _handlePointerCancel,
          child: Stack(
            children: [
              CardSwiper(
                controller: _controller,
                cardsCount: tasks.length,
                isLoop: false,
                isDisabled: _dropMode,
                numberOfCardsDisplayed:
                    tasks.length >= 3 ? 3 : tasks.length,
                threshold: thresholdPx,
                allowedSwipeDirection: AllowedSwipeDirection.only(
                  right: !locked,
                  left: true,
                  up: false, // inspect is tap-only; an up-swipe cannot be cancelled
                  down: true,
                ),
                backCardOffset: const Offset(0, -24),
                onSwipe: _onSwipe,
                cardBuilder:
                    (context, index, percentThresholdX, percentThresholdY) {
                  final task = tasks[index];
                  return SwipeThresholdHaptic(
                    percentThresholdX: percentThresholdX,
                    percentThresholdY: percentThresholdY,
                    secondThreshold: secondStage,
                    onSecondStage: (active, right) => _secondStage =
                        active ? (right ? 'right' : 'left') : null,
                    child: TaskCardView(
                      task: task,
                      timeAgo: timeAgo,
                      swipePercentX: percentThresholdX,
                      swipePercentY: percentThresholdY,
                      secondStageThreshold: secondStage,
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
              if (_dropMode)
                Positioned.fill(
                  child: IgnorePointer(
                    child: DropZoneOverlay(hovered: _dropHover),
                  ),
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
          ),
        );
      },
    );
  }

  // ------------------------------------------------------------------
  // Drop zones (I-108): hold the card ~400ms, then drag to a corner.

  bool _inCardArea(Offset p) =>
      _stackSize.height > 0 && p.dy < _stackSize.height - 100;

  void _handlePointerDown(PointerDownEvent event) {
    _pointers[event.pointer] = event.localPosition;
    if (_pointers.length >= 2) {
      // Two fingers: pinch, never drop.
      _dropTimer?.cancel();
      _dropTimer = null;
      _pinchBase = _pointerDistance();
      return;
    }
    if (_overview || !_inCardArea(event.localPosition)) return;
    _pointerDown = event.localPosition;
    _dropTimer?.cancel();
    _dropTimer = Timer(const Duration(milliseconds: 400), _armDrop);
  }

  void _handlePointerMove(PointerMoveEvent event) {
    final tracked = _pointers.containsKey(event.pointer);
    _pointers[event.pointer] = event.localPosition;

    if (_pointers.length >= 2) {
      final base = _pinchBase;
      if (base != null && base > 0 && _pointerDistance() < base * 0.7) {
        _dropTimer?.cancel();
        _dropTimer = null;
        _pointers.clear();
        _pinchBase = null;
        setState(() => _overview = true);
      }
      return;
    }

    if (_dropMode) {
      setState(() => _dropHover = _zoneFor(event.localPosition));
      return;
    }
    if (tracked && _dropTimer != null) {
      if ((event.localPosition - _pointerDown).distance > 16) {
        _dropTimer?.cancel();
        _dropTimer = null;
      }
    }
  }

  void _handlePointerUp(PointerEvent event) {
    _pointers.remove(event.pointer);
    _dropTimer?.cancel();
    _dropTimer = null;
    _pinchBase = null;
    if (!_dropMode) return;
    final zone = _dropHover;
    _exitDropMode();
    if (zone != null) _runDropAction(zone);
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    _pointers.remove(event.pointer);
    _dropTimer?.cancel();
    _dropTimer = null;
    _pinchBase = null;
    _exitDropMode();
  }

  double _pointerDistance() {
    final points = _pointers.values.toList();
    if (points.length < 2) return 0;
    return (points[0] - points[1]).distance;
  }

  void _armDrop() {
    if (!mounted) return;
    HapticFeedback.selectionClick();
    setState(() {
      _dropMode = true;
      _dropHover = _zoneFor(_pointerDown);
    });
  }

  void _exitDropMode() {
    if (!_dropMode && _dropHover == null) return;
    if (!mounted) return;
    setState(() {
      _dropMode = false;
      _dropHover = null;
    });
  }

  DropAction? _zoneFor(Offset p) {
    if (_stackSize.isEmpty) return null;
    final w = _stackSize.width;
    final h = _stackSize.height;
    final margin = _stackSize.shortestSide * 0.45;
    if ((p - const Offset(0, 0)).distance < margin) return DropAction.delegate;
    if ((p - Offset(w, 0)).distance < margin) return DropAction.snoozeHour;
    if ((p - Offset(0, h)).distance < margin) return DropAction.ask;
    if ((p - Offset(w, h)).distance < margin) return DropAction.snoozeMorning;
    return null;
  }

  void _runDropAction(DropAction action) {
    final repo = context.read<TaskRepository>();
    final tasks = repo.stack;
    if (tasks.isEmpty) return;
    final top = tasks.first;
    switch (action) {
      case DropAction.snoozeHour:
        HapticFeedback.mediumImpact();
        repo.snooze(top.taskId);
        _showToast('1時間後にもう一度（端末内スヌーズ）');
        break;
      case DropAction.snoozeMorning:
        HapticFeedback.mediumImpact();
        repo.snooze(top.taskId);
        _showToast('明日の朝にもう一度（端末内スヌーズ）');
        break;
      case DropAction.ask:
        _inspect(top);
        break;
      case DropAction.delegate:
        _showToast('同僚に回す: まだ接続されていません');
        break;
    }
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
    final secondStage = _secondStage;
    _secondStage = null;
    // Locked cards (critical + irreversible) cannot be approved by
    // swipe — belt-and-braces guard in case the direction filter misses.
    if (direction == CardSwiperDirection.right &&
        riskLevel(task) == RiskLevel.locked) {
      return false;
    }
    if (direction == CardSwiperDirection.right) {
      final binding = task.onSwipeRight;
      final propose = secondStage == 'right';
      final data = <String, dynamic>{
        ...?binding?.payload,
        if (propose) 'proposeAutomation': true,
      };
      _triage(
        task,
        actionName: binding?.actionName ?? 'approve',
        data: data,
        source:
            propose ? ActionSource.twoStageSwipe : ActionSource.swipeGesture,
      );
    } else if (direction == CardSwiperDirection.left) {
      _rejectWithReasons(task, muteSimilar: secondStage == 'left');
    } else if (direction == CardSwiperDirection.bottom) {
      repo.snooze(task.taskId);
    } else {
      return false;
    }
    return true;
  }

  /// Reject path (I-118): when the agent supplied `rejectReasons`, a
  /// short-lived chip row asks why before the decision leaves. Ignoring
  /// it (timeout or dismiss) still confirms without a reason. A left
  /// second-stage swipe (I-101) also asks to mute similar proposals.
  Future<void> _rejectWithReasons(
    TaskCard task, {
    bool muteSimilar = false,
  }) async {
    final binding = task.onSwipeLeft;
    Map<String, dynamic>? data = binding?.payload;
    if (task.rejectReasons.isNotEmpty && mounted) {
      final reasonId = await showRejectReasonSheet(context, task.rejectReasons);
      if (reasonId != null) {
        data = <String, dynamic>{
          ...?data,
          'reason': reasonId,
        };
      }
    }
    if (muteSimilar) {
      data = <String, dynamic>{
        ...?data,
        'muteSimilar': true,
      };
    }
    _triage(
      task,
      actionName: binding?.actionName ?? 'reject',
      data: data,
      source: muteSimilar
          ? ActionSource.twoStageSwipe
          : ActionSource.swipeGesture,
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
