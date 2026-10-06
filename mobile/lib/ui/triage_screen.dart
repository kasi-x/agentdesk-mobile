import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_card_swiper/flutter_card_swiper.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/task_card.dart';
import '../models/triage_action.dart';
import '../services/priority.dart';
import '../services/task_repository.dart';
import 'inspect_sheet.dart';
import 'colors.dart';
import 'settings_screen.dart';
import 'stack_entry.dart';
import 'widgets/bundle_card_view.dart';
import 'widgets/choice_card_view.dart';
import 'widgets/drop_zone_overlay.dart';
import 'widgets/fleet_bar.dart';
import 'widgets/hold_confirm.dart';
import 'widgets/overview_grid.dart';
import 'widgets/practice_screen.dart';
import 'widgets/processed_tray.dart';
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

  /// Card ids pulled out of their group bundle for one-by-one triage.
  final Set<String> _ungrouped = <String>{};

  /// Fleet filter (I-603/I-122): agent name or null for すべて. Combines
  /// with group bundles — a bundle shows when ANY member matches.
  String? _fleetFilter;

  /// Rubber-stamp detection (I-401): ≥3 fast approvals of high/locked
  /// cards arms the flag; the next such card needs a doubled threshold
  /// and shows a banner. Reset by any reject/inspect.
  int _fastApprovals = 0;
  bool _stampArmed = false;
  String? _topKey;
  DateTime _topSince = DateTime.now();

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

  /// Hand the card to a colleague (I-501): name prompt → POST delegate.
  Future<void> _delegate(TaskCard task) async {
    HapticFeedback.selectionClick();
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('同僚に回す'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '相手の名前',
            hintText: 'Bさん',
          ),
          onSubmitted: (_) =>
              Navigator.of(context).pop(controller.text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('やめる'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(controller.text.trim()),
            child: const Text('回す'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty || !mounted) return;
    HapticFeedback.mediumImpact();
    await context.read<TaskRepository>().delegate(task, name.trim());
  }

  /// Choose card decision (I-111): index 0 = up, index 1 = down.
  void _choose(TaskCard task, int index) {
    if (task.choices.length <= index) return;
    final wasStamped = _stampArmed;
    _recordApproval(task);
    if (wasStamped) _resetStamp();
    final binding =
        index == 0 ? (task.onSwipeUp ?? task.onSwipeRight) : task.onSwipeDown;
    _triage(
      task,
      actionName: binding?.actionName ?? 'approve',
      data: <String, dynamic>{
        ...?binding?.payload,
        'choice': task.choices[index].id,
      },
      source: ActionSource.swipeGesture,
    );
  }

  /// Rubber-stamp accounting (I-401): fast approvals of high/locked
  /// cards accumulate; anything else, or any reject/inspect, resets.
  void _recordApproval(TaskCard task) {
    final risk = riskLevel(task);
    final hot = risk == RiskLevel.high || risk == RiskLevel.locked;
    final elapsed = DateTime.now().difference(_topSince);
    if (hot && elapsed < const Duration(seconds: 1)) {
      _fastApprovals++;
      if (_fastApprovals >= 3) _stampArmed = true;
    } else if (hot) {
      _fastApprovals = 1;
    } else {
      _resetStamp();
    }
  }

  void _resetStamp() {
    _fastApprovals = 0;
    _stampArmed = false;
  }


  void _inspect(TaskCard task) {
    HapticFeedback.selectionClick();
    _resetStamp();
    showInspectSheet(context, task, (data) {
      final binding = task.onSwipeRight;
      _triage(
        task,
        actionName: binding?.actionName ?? 'approve',
        data: data,
        source: ActionSource.inspectForm,
      );
    }, onDelegate: () => _delegate(task));
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<TaskRepository>();
    final visible = repo.visibleStack;
    final allEntries = StackEntry.build(visible, ungrouped: _ungrouped);
    // Fleet filter (I-603/I-122): a bundle stays visible when ANY member
    // matches; single cards show only on direct match. Members render
    // intact so bundle bulk actions keep their semantics.
    final entries = _fleetFilter == null
        ? allEntries
        : allEntries
            .where((e) => e.members.any((m) => m.agent.name == _fleetFilter))
            .toList();
    final matchCount = _fleetFilter == null
        ? visible.length
        : visible.where((t) => t.agent.name == _fleetFilter).length;
    _trackTop(entries);
    final pendingByAgent = <String, int>{};
    for (final task in visible) {
      pendingByAgent.update(task.agent.name, (c) => c + 1,
          ifAbsent: () => 1);
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('AgentDesk',
            style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          const SizedBox(width: 4),
          _PendingBadge(count: matchCount),
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
          _OrderMenu(repo: repo),
          IconButton(
            icon: const Icon(Icons.grid_view_rounded),
            tooltip: '俯瞰',
            onPressed: entries.isEmpty
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
      body: Column(
        children: [
          if (repo.paused) _pauseBanner(repo),
          if (repo.snoozeCount > 0) _snoozeChip(repo),
          if (repo.parkedTasks.isNotEmpty)
            _quietChip(repo.parkedTasks.length),
          FleetBar(
            stack: visible,
            pendingByAgent: pendingByAgent,
            selectedAgent: _fleetFilter,
            onSelect: (agent) => setState(() => _fleetFilter = agent),
          ),
          Expanded(
            child: entries.isEmpty
                ? _EmptyState(reconnecting: !repo.connected.value)
                : _overview
                    ? OverviewGrid(
                        tasks: entries.expand((e) => e.members).toList(),
                        onPick: (task) {
                          repo.bringToTop(task.taskId);
                          setState(() => _overview = false);
                        },
                        onClose: () => setState(() => _overview = false),
                      )
                    : _buildStack(entries),
          ),
          const ProcessedTray(),
        ],
      ),
    );
  }

  /// Remembers when the current top entry arrived so rubber-stamp
  /// timing (I-401) measures display age, not card age.
  void _trackTop(List<StackEntry> entries) {
    final key = entries.isEmpty ? null : entries.first.key;
    if (key != _topKey) {
      _topKey = key;
      _topSince = DateTime.now();
    }
  }

  /// Emergency stop broadcast by the hub: approve actions are disabled
  /// until resume (wave-2 pauseState).
  Widget _pauseBanner(TaskRepository repo) {
    final until = repo.pauseUntil;
    final detail = until == null
        ? ''
        : '（${until.toLocal().month}/${until.toLocal().day} '
            '${until.toLocal().hour.toString().padLeft(2, '0')}:'
            '${until.toLocal().minute.toString().padLeft(2, '0')} まで）';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: PopColors.red,
      child: Text(
        '緊急停止中$detail — 承認は一時停止しています',
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w800,
          color: Colors.white,
        ),
      ),
    );
  }

  Widget _snoozeChip(TaskRepository repo) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: PopColors.fill2,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          'あとで ${repo.snoozeCount}',
          style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: PopColors.text2),
        ),
      ),
    );
  }

  Widget _quietChip(int count) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: PopColors.fill2,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          'おやすみ中 $count',
          style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: PopColors.text2),
        ),
      ),
    );
  }

  /// Swipe "weight" follows the top card's risk (I-102): high-risk cards
  /// need a longer drag; locked cards (critical + irreversible) can't be
  /// right-swiped at all and require the hold-to-confirm ring (I-103).
  Widget _buildStack(List<StackEntry> entries) {
    final repo = context.read<TaskRepository>();
    final top = entries.first;
    final risk = top.isBundle
        ? riskLevel(top.members.first)
        : riskLevel(top.single!);
    final locked = !top.isBundle && risk == RiskLevel.locked;
    final isChoose = !top.isBundle && top.single!.decisionKind == 'choose';
    final paused = repo.paused;
    // Rubber-stamp (I-401): the armed threshold doubles for this card.
    final stamped = _stampArmed &&
        !top.isBundle &&
        (risk == RiskLevel.high || risk == RiskLevel.locked);
    return LayoutBuilder(
      builder: (context, constraints) {
        _stackSize = constraints.biggest;
        // CardSwiper treats `threshold` as a pixel distance here; the
        // second stage (I-101) is ~85% of the card width.
        var thresholdPx = risk == RiskLevel.high ? 90 : 50;
        if (stamped) thresholdPx *= 2;
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
                cardsCount: entries.length,
                isLoop: false,
                isDisabled: _dropMode,
                numberOfCardsDisplayed:
                    entries.length >= 3 ? 3 : entries.length,
                threshold: thresholdPx,
                allowedSwipeDirection: isChoose
                    ? const AllowedSwipeDirection.only(
                        // Choose cards (I-111): up = A, down = B;
                        // right/left disabled, reject via ✕ only.
                        right: false,
                        left: false,
                        up: true,
                        down: true,
                      )
                    : AllowedSwipeDirection.only(
                        right: !locked && !paused,
                        left: true,
                        up: false, // inspect is tap-only; an up-swipe cannot be cancelled
                        down: true,
                      ),
                backCardOffset: const Offset(0, -24),
                onSwipe: _onSwipe,
                cardBuilder:
                    (context, index, percentThresholdX, percentThresholdY) {
                  final entry = entries[index];
                  if (entry.isBundle) {
                    return SwipeThresholdHaptic(
                      percentThresholdX: percentThresholdX,
                      percentThresholdY: percentThresholdY,
                      secondThreshold: secondStage,
                      onSecondStage: (active, right) => _secondStage =
                          active ? (right ? 'right' : 'left') : null,
                      child: BundleCardView(
                        tasks: entry.members,
                        timeAgo: timeAgo,
                        swipePercentX: percentThresholdX,
                        swipePercentY: percentThresholdY,
                        onPickItem: _pickBundleItem,
                        onInspect: () => _inspect(entry.members.first),
                      ),
                    );
                  }
                  final task = entry.single!;
                  if (task.decisionKind == 'choose') {
                    return SwipeThresholdHaptic(
                      percentThresholdX: percentThresholdX,
                      percentThresholdY: percentThresholdY,
                      secondThreshold: secondStage,
                      onSecondStage: (active, right) => _secondStage =
                          active ? (right ? 'right' : 'left') : null,
                      child: ChoiceCardView(
                        task: task,
                        timeAgo: timeAgo,
                        swipePercentY: percentThresholdY,
                        onChoose: (i) => _choose(task, i),
                        onInspect: () => _inspect(task),
                        delegatedTo: repo.delegatedFor(task.taskId) ??
                            task.delegatedTo,
                        approvalCount:
                            repo.approvalCountFor(task.taskId),
                        rubberStamp: stamped && task.taskId == top.single!.taskId,
                      ),
                    );
                  }
                  return SwipeThresholdHaptic(
                    percentThresholdX: percentThresholdX,
                    percentThresholdY: percentThresholdY,
                    secondThreshold: secondStage,
                    onSecondStage: (active, right) => _secondStage =
                        active ? (right ? 'right' : 'left') : null,
                    child: _singleCard(repo, task, percentThresholdX,
                        percentThresholdY, secondStage, stamped &&
                            task.taskId == (top.single?.taskId ?? '')),
                  );
                },
              ),
              if (_dropMode)
                Positioned.fill(
                  child: IgnorePointer(
                    child: DropZoneOverlay(hovered: _dropHover),
                  ),
                ),
              _bottomBar(entries),
            ],
          ),
        );
      },
    );
  }

  /// One normal card with all wave-2 badges wired to the repository.
  Widget _singleCard(
    TaskRepository repo,
    TaskCard task,
    int percentThresholdX,
    int percentThresholdY,
    int secondStage,
    bool stamped,
  ) {
    return TaskCardView(
      task: task,
      timeAgo: timeAgo,
      swipePercentX: percentThresholdX,
      swipePercentY: percentThresholdY,
      secondStageThreshold: secondStage,
      selectedRowIds: repo.rowSelection(task.taskId).toSet(),
      onRowToggle: (id) {
        final current = repo.rowSelection(task.taskId).toSet();
        if (current.contains(id)) {
          current.remove(id);
        } else {
          current.add(id);
        }
        repo.setRowSelection(task.taskId, current.toList());
      },
      editedValue: task.editable == null
          ? null
          : repo.editedValueFor(task.taskId, task.editable!.componentId),
      onEditedValue: (v) {
        final hint = task.editable;
        if (hint == null) return;
        repo.setEditedValue(task.taskId, hint.componentId, v);
      },
      delegatedTo:
          repo.delegatedFor(task.taskId) ?? task.delegatedTo,
      approvalCount: repo.approvalCountFor(task.taskId),
      deliveryFailed: repo.isDeliveryFailed(task.taskId),
      rubberStamp: stamped,
      revised: repo.isRevised(task.taskId),
      onQuickAction: (binding) => _triage(
        task,
        actionName: binding.actionName,
        data: binding.payload,
        source: ActionSource.quickChip,
      ),
      onInspect: () => _inspect(task),
    );
  }

  /// Takes one bundle member out of the bundle and brings it to the top
  /// so it can be triaged on its own (I-201).
  void _pickBundleItem(TaskCard task) {
    HapticFeedback.selectionClick();
    _ungrouped.add(task.taskId);
    context.read<TaskRepository>().bringToTop(task.taskId);
  }

  /// Bottom action bar (I-134): same movements as the gestures via
  /// CardSwiperController.swipe(); on locked cards the ✓ slot becomes
  /// the hold-to-confirm ring (I-103). Choose cards (I-111) expose
  /// reject ✕ plus the two choices; bundles expose bulk actions.
  Widget _bottomBar(List<StackEntry> entries) {
    final repo = context.read<TaskRepository>();
    final top = entries.first;
    final paused = repo.paused;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 10,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          if (top.isBundle) ...[
            _BarAction(
              icon: Icons.close,
              label: 'まとめて拒否',
              onTap: () => _controller.swipe(CardSwiperDirection.left),
            ),
            _BarAction(
              icon: Icons.snooze,
              label: 'あとで',
              onTap: () => _controller.swipe(CardSwiperDirection.bottom),
            ),
            _BarAction(
              icon: Icons.check,
              label: '${top.members.length}件承認',
              onTap: paused
                  ? null
                  : () => _controller.swipe(CardSwiperDirection.right),
            ),
          ] else if (top.single!.decisionKind == 'choose') ...[
            _BarAction(
              icon: Icons.close,
              label: top.single!.onSwipeLeft?.label ?? '拒否',
              onTap: () => _rejectWithReasons(top.single!),
            ),
            _BarAction(
              icon: Icons.arrow_upward,
              label: _choiceLabel(top.single!, 0),
              onTap: () => _choose(top.single!, 0),
            ),
            _BarAction(
              icon: Icons.arrow_downward,
              label: _choiceLabel(top.single!, 1),
              onTap: () => _choose(top.single!, 1),
            ),
          ] else ...[
            _BarAction(
              icon: Icons.close,
              label: top.single!.onSwipeLeft?.label ?? '拒否',
              onTap: () =>
                  _controller.swipe(CardSwiperDirection.left),
            ),
            _BarAction(
              icon: Icons.snooze,
              label: 'あとで',
              onTap: () =>
                  _controller.swipe(CardSwiperDirection.bottom),
            ),
            if (riskLevel(top.single!) == RiskLevel.locked)
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  paused
                      ? const Icon(Icons.pause_circle_outline,
                          size: 34, color: Colors.white38)
                      : HoldConfirmButton(
                          label: top.single!.onSwipeRight?.label ?? 'Approve',
                          onConfirmed: () => _triage(
                            top.single!,
                            actionName: top.single!.onSwipeRight?.actionName ??
                                'approve',
                            data: top.single!.onSwipeRight?.payload,
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
                label: top.single!.onSwipeRight?.label ?? '承認',
                onTap: paused
                    ? null
                    : () => _controller.swipe(CardSwiperDirection.right),
              ),
          ],
        ],
      ),
    );
  }

  static String _choiceLabel(TaskCard task, int index) =>
      task.choices.length > index ? task.choices[index].label : '?';


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
        final repo = context.read<TaskRepository>();
        final entries = _currentEntries(repo);
        if (entries.isNotEmpty && entries.first.isBundle) {
          // Two fingers on a bundle = approve everything at once (I-201).
          _dropTimer?.cancel();
          _dropTimer = null;
          _pointers.clear();
          _pinchBase = null;
          HapticFeedback.heavyImpact();
          unawaited(repo.bulkApprove(entries.first.members));
        } else {
          _dropTimer?.cancel();
          _dropTimer = null;
          _pointers.clear();
          _pinchBase = null;
          setState(() => _overview = true);
        }
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
    final entries = _currentEntries(repo);
    if (entries.isEmpty) return;
    final top = entries.first.members.first;
    switch (action) {
      case DropAction.snoozeHour:
        HapticFeedback.mediumImpact();
        unawaited(repo.serverSnooze(top, after: const Duration(hours: 1)));
        break;
      case DropAction.snoozeMorning:
        HapticFeedback.mediumImpact();
        final now = DateTime.now();
        var morning = DateTime(now.year, now.month, now.day, 7);
        if (!morning.isAfter(now)) {
          morning = morning.add(const Duration(days: 1));
        }
        unawaited(repo.serverSnooze(top,
            after: morning.difference(DateTime.now())));
        break;
      case DropAction.ask:
        _inspect(top);
        break;
      case DropAction.delegate:
        unawaited(_delegate(top));
        break;
    }
  }

  /// Entries the stack currently renders: visible stack filtered by the
  /// fleet lane (bundle visible when ANY member matches). Swipe, drop
  /// and pinch handlers use this so gestures hit the rendered top card.
  List<StackEntry> _currentEntries(TaskRepository repo) {
    final all =
        StackEntry.build(repo.visibleStack, ungrouped: _ungrouped);
    if (_fleetFilter == null) return all;
    return all
        .where((e) => e.members.any((m) => m.agent.name == _fleetFilter))
        .toList();
  }

  FutureOr<bool> _onSwipe(
    int previousIndex,
    int? currentIndex,
    CardSwiperDirection direction,
  ) {
    final repo = context.read<TaskRepository>();
    final entries = _currentEntries(repo);
    if (previousIndex < 0 || previousIndex >= entries.length) return false;
    final entry = entries[previousIndex];
    final secondStage = _secondStage;
    _secondStage = null;
    if (entry.isBundle) return _swipeBundle(repo, entry, direction);
    final task = entry.single!;
    if (task.decisionKind == 'choose') {
      return _swipeChoose(task, direction);
    }
    final wasStamped = _stampArmed;
    // Locked cards (critical + irreversible) cannot be approved by
    // swipe — belt-and-braces guard in case the direction filter misses.
    if (direction == CardSwiperDirection.right &&
        riskLevel(task) == RiskLevel.locked) {
      return false;
    }
    if (direction == CardSwiperDirection.right) {
      if (repo.paused) return false;
      final binding = task.onSwipeRight;
      final propose = secondStage == 'right';
      final data = <String, dynamic>{
        ...?binding?.payload,
        if (propose) 'proposeAutomation': true,
      };
      _recordApproval(task);
      if (wasStamped) _resetStamp();
      _triage(
        task,
        actionName: binding?.actionName ?? 'approve',
        data: data,
        source:
            propose ? ActionSource.twoStageSwipe : ActionSource.swipeGesture,
      );
    } else if (direction == CardSwiperDirection.left) {
      _resetStamp();
      _rejectWithReasons(task, muteSimilar: secondStage == 'left');
    } else if (direction == CardSwiperDirection.bottom) {
      _resetStamp();
      HapticFeedback.mediumImpact();
      unawaited(repo.serverSnooze(task));
    } else {
      return false;
    }
    return true;
  }

  /// Bundles (I-201): right approves every member via bulk, left rejects
  /// them all via bulk, down snoozes them all. Up is reserved.
  bool _swipeBundle(
    TaskRepository repo,
    StackEntry entry,
    CardSwiperDirection direction,
  ) {
    final members = entry.members;
    if (direction == CardSwiperDirection.right) {
      if (repo.paused) return false;
      HapticFeedback.heavyImpact();
      unawaited(repo.bulkApprove(members));
    } else if (direction == CardSwiperDirection.left) {
      _resetStamp();
      unawaited(repo.bulkReject(members));
    } else if (direction == CardSwiperDirection.bottom) {
      _resetStamp();
      HapticFeedback.mediumImpact();
      for (final task in members) {
        unawaited(repo.serverSnooze(task));
      }
    } else {
      return false;
    }
    return true;
  }

  /// Choose cards (I-111): up commits the first choice, down the
  /// second. Horizontal swipes are disabled (the sheet never allows
  /// them); rejection happens through the bottom-bar ✕ only.
  bool _swipeChoose(TaskCard task, CardSwiperDirection direction) {
    if (direction == CardSwiperDirection.top) {
      _choose(task, 0);
    } else if (direction == CardSwiperDirection.bottom) {
      _choose(task, 1);
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

/// 山札の並び順を切り替えるメニュー（I-123 / I-206）。選択すると
/// リポジトリに永続化し、既存の listen 配線で画面が再描画される。
class _OrderMenu extends StatelessWidget {
  final TaskRepository repo;

  const _OrderMenu({required this.repo});

  static const Map<StackOrder, String> _labels = <StackOrder, String>{
    StackOrder.urgent: '緊急順',
    StackOrder.newest: '新しい順',
    StackOrder.agent: 'エージェント順',
  };

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<StackOrder>(
      icon: const Icon(Icons.sort),
      tooltip: '並び順',
      initialValue: repo.order,
      onSelected: (mode) => repo.setOrder(mode),
      itemBuilder: (context) => <PopupMenuEntry<StackOrder>>[
        for (final mode in StackOrder.values)
          CheckedPopupMenuItem<StackOrder>(
            value: mode,
            checked: repo.order == mode,
            child: Text(_labels[mode]!),
          ),
      ],
    );
  }
}

/// Round button in the bottom action bar (I-134). Tap triggers the same
/// swipe animation the gesture would via [CardSwiperController]. A null
/// [onTap] renders the slot disabled (e.g. approve during 緊急停止中）.
class _BarAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _BarAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: enabled
              ? () {
                  HapticFeedback.selectionClick();
                  onTap!();
                }
              : null,
          icon: Icon(icon),
          iconSize: 30,
          color: enabled ? Colors.white70 : Colors.white24,
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
