import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../models/task_card.dart';
import '../models/triage_action.dart';
import 'hub_api.dart';
import 'live_activities.dart';
import 'priority.dart';
import 'sse_client.dart';

/// One finished triage decision (I-120/I-512): shown in the processed tray
/// grouped by date, newest first. `source` is one of user/snooze/auto/
/// expire/withdraw/other (see [TaskRepository.processed]).
class ProcessedEntry {
  final String taskId;
  final String summary;
  final String actionName;
  final String source;
  final DateTime at;
  final String agentName;

  const ProcessedEntry({
    required this.taskId,
    required this.summary,
    required this.actionName,
    required this.source,
    required this.at,
    required this.agentName,
  });

  factory ProcessedEntry.fromJson(Map<String, dynamic> raw) {
    final at = DateTime.tryParse('${raw['at'] ?? ''}');
    return ProcessedEntry(
      taskId: '${raw['taskId'] ?? ''}',
      summary: '${raw['summary'] ?? '(no summary)'}',
      actionName: '${raw['action'] ?? 'approve'}',
      source: '${raw['source'] ?? 'other'}',
      at: at ?? DateTime.fromMillisecondsSinceEpoch(0),
      agentName: '${raw['agent'] ?? ''}',
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'taskId': taskId,
        'summary': summary,
        'action': actionName,
        'source': source,
        'at': at.toUtc().toIso8601String(),
        'agent': agentName,
      };
}

/// Owns the triage stack: optimistic removal (FR-2.1), async delivery +
/// offline queue (FR-2.2/2.3), snapshot reconciliation (FR-3.2/3.3) and
/// the wave-2 server features — server snooze, delegation, bulk triage,
/// pause, approval progress and quiet hours. See docs/architecture.md.
class TaskRepository extends ChangeNotifier {
  final HubApi api;
  final ValueNotifier<bool> connected = ValueNotifier<bool>(false);

  HubConfig _config;
  SseClient? _sse;
  List<TaskCard> _stack = <TaskCard>[];
  StackOrder _order = StackOrder.urgent;
  final Set<String> _snoozedIds = <String>{};
  List<TriageActionReply> _queue = <TriageActionReply>[];
  /// Snoozes that failed offline, replayed on reconnect (I-102/wave-2).
  List<Map<String, dynamic>> _snoozeQueue = <Map<String, dynamic>>[];
  /// Cards triaged this session, kept for undo (I-104). Insertion order
  /// = recency; bounded so a long session cannot grow it unboundedly.
  final Map<String, TaskCard> _undoable = <String, TaskCard>{};
  static const int _undoableLimit = 30;

  /// Task ids whose decision we sent and whose `dismissTask` echo is still
  /// expected — the echo is swallowed so a device never toasts its own
  /// triage (wave-2 multi-device polish).
  final Set<String> _pendingActionIds = <String>{};

  /// Server-side snoozes (I-102): taskId → resurface time. Cards live
  /// outside the stack until the hub re-broadcasts them.
  final Map<String, DateTime> _serverSnoozed = <String, DateTime>{};
  final Map<String, int> _approvalProgress = <String, int>{};
  final Map<String, String> _delegatedTo = <String, String>{};
  final Set<String> _deliveryFailed = <String>{};
  bool _paused = false;
  DateTime? _pauseUntil;

  /// Finished triage decisions (I-120/I-512): newest first, capped at
  /// [_processedLimit]. Recorded on every local triage and every remote
  /// dismiss event; persisted to shared_preferences as JSON.
  final List<ProcessedEntry> _processed = <ProcessedEntry>[];
  static const int _processedLimit = 100;
  static const String _processedKey = 'processedHistory';

  /// 「更新されました」 banner (I-204): taskId → expiry timer.
  final Set<String> _revisedIds = <String>{};
  final Map<String, Timer> _revisedTimers = <String, Timer>{};

  final Map<String, List<String>> _rowSelections = <String, List<String>>{};
  final Map<String, Map<String, Object?>> _editedValues =
      <String, Map<String, Object?>>{};

  int? _quietStart;
  int? _quietEnd;

  static const Set<String> _nonApproveActions = <String>{
    'reject',
    'snooze',
    'delegate',
    'ask',
  };

  /// Maps a hub dismiss `by` marker to a tray action label (I-512). The
  /// dismiss payload carries no action — only `auto_rule` is known to be
  /// an approval; everything else unknown renders as `other` (⧉).
  static String actionForDismissBy(String? by) {
    final marker = by ?? '';
    if (marker == 'auto_rule') return 'approve';
    if (marker == 'withdraw') return 'withdraw';
    if (marker.startsWith('on_expire')) return 'expire';
    return 'other';
  }

  String? _lastToast;
  int _toastSeq = 0;
  /// Every stack funnel (`_reconcile`, `upsert`, `remove`,
  /// `_hideForSnooze`, `_restore`, local `snooze`/`bringToTop`, order and
  /// quiet-hours changes) ends in [notifyListeners], so this single hook
  /// mirrors all of them. Tray-only notifies (history, toasts, approval
  /// progress) are absorbed by [LiveActivitiesService]'s dedupe — no
  /// platform call unless count/top actually changed.
  @override
  void notifyListeners() {
    _syncLiveActivity();
    super.notifyListeners();
  }

  /// iOS Live Activity mirror (Phase 3): "N agents waiting — top: <title>".
  /// Lazily instantiated so tests and non-iOS devices never allocate a
  /// platform channel; every push is fire-and-forget and deduped inside
  /// [LiveActivitiesService], so stack mutations never block on it.
  LiveActivitiesService? _liveActivities;
  LiveActivitiesService get _live {
    final existing = _liveActivities;
    if (existing != null) return existing;
    final created = LiveActivitiesService();
    _liveActivities = created;
    return created;
  }

  /// Waiting-stack mirror: start/update while cards remain, end at zero.
  /// Uses [visibleStack] so quiet-hours-parked cards match what the user
  /// sees; head of the post-restack ordering is the visible top card.
  void _syncLiveActivity() {
    final cards = visibleStack;
    if (cards.isEmpty) {
      unawaited(_live.end());
      return;
    }
    final top = cards.first;
    unawaited(_live.update(
      pendingCount: cards.length,
      topTitle: top.summary,
      topAgent: top.agent.name,
    ));
  }

  TaskRepository({required HubConfig config, HubApi? api})
      : _config = config,
        api = api ?? HttpHubApi(config: config);

  List<TaskCard> get stack => List.unmodifiable(_stack);

  /// Cards the stack should render: [stack] minus cards parked by quiet
  /// hours (I-402). Critical cards are never parked.
  List<TaskCard> get visibleStack {
    if (!quietHoursActive) return List.unmodifiable(_stack);
    final parked = parkedTasks.map((t) => t.taskId).toSet();
    return List.unmodifiable(_stack.where((t) => !parked.contains(t.taskId)));
  }

  int get pendingCount => _stack.length;
  HubConfig get config => _config;
  StackOrder get order => _order;
  bool get hasQueuedActions => _queue.isNotEmpty || _snoozeQueue.isNotEmpty;
  String? get lastToast => _lastToast;
  int get toastSeq => _toastSeq;

  /// Number of cards hidden by a server-side snooze (「あとで N」).
  int get snoozeCount => _serverSnoozed.length;

  /// All finished decisions, newest first (I-120/I-512).
  List<ProcessedEntry> get processed => List.unmodifiable(_processed);

  /// Decisions finished today (local calendar day) — the tray strip count.
  int get processedTodayCount {
    final now = DateTime.now();
    return _processed
        .where((e) =>
            e.at.year == now.year &&
            e.at.month == now.month &&
            e.at.day == now.day)
        .length;
  }

  /// Non-critical cards parked while quiet hours are active (I-402).
  List<TaskCard> get parkedTasks => quietHoursActive
      ? _stack.where((t) => t.severity != 'critical').toList()
      : const <TaskCard>[];

  bool get quietHoursActive {
    final start = _quietStart;
    final end = _quietEnd;
    if (start == null || end == null || start == end) return false;
    final now = DateTime.now();
    final minutes = now.hour * 60 + now.minute;
    return start <= end
        ? minutes >= start && minutes < end
        : minutes >= start || minutes < end;
  }

  int? get quietStart => _quietStart;
  int? get quietEnd => _quietEnd;

  bool get paused => _paused;
  DateTime? get pauseUntil => _pauseUntil;

  int approvalCountFor(String taskId) => _approvalProgress[taskId] ?? 0;
  String? delegatedFor(String taskId) => _delegatedTo[taskId];
  bool isDeliveryFailed(String taskId) => _deliveryFailed.contains(taskId);
  bool isRevised(String taskId) => _revisedIds.contains(taskId);

  List<String> rowSelection(String taskId) =>
      List.unmodifiable(_rowSelections[taskId] ?? const <String>[]);

  /// Current value of the inline editor (I-114) for [componentId].
  Object? editedValueFor(String taskId, String componentId) =>
      _editedValues[taskId]?[componentId];

  /// The UI plugs a snackbar shower in here; [toastSeq] disambiguates
  /// repeated messages. `undoableTaskId` is set when the toast announces
  /// a triage decision inside the undo grace window (I-104) and the UI
  /// should offer a "元に戻す" action calling [undo].
  void Function(String message, {String? undoableTaskId})? onToast;

  /// Fires when the hub reports 409 (task already processed elsewhere).
  /// The UI maps it to a double haptic tap (I-131).
  void Function()? onConflict;
  /// I-1005: fired after a committed decide action so the UI can offer
  /// 「同種を自動化」 — receives the decided card and the rule action
  /// ('approve' | 'reject') the scope sheet should draft.
  void Function(TaskCard task, String action)? onAutomatable;

  HubApiV2? get _v2 => api is HubApiV2 ? api as HubApiV2 : null;

  // ------------------------------------------------------------------
  // Lifecycle

  void start() {
    unawaited(_loadOrder());
    _connectSse();
  }

  static const String _orderPrefsKey = 'stack_order';

  Future<void> _loadOrder() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_orderPrefsKey);
    if (saved == null) return;
    final loaded = StackOrder.values.asNameMap()[saved];
    if (loaded == null || loaded == _order) return;
    _order = loaded;
    // 起動時のスナップショットより後に解決しうるため、確定時点で並べ直す。
    _restack();
    notifyListeners();
  }

  /// 山札の並び順を切り替える（緊急順 / 新しい順 / エージェント順）。
  Future<void> setOrder(StackOrder order) async {
    if (_order == order) return;
    _order = order;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_orderPrefsKey, order.name);
    _restack();
    notifyListeners();
  }

  void _connectSse() {
    _sse?.dispose();
    final sse = SseClient();
    _sse = sse;
    sse.connect(
      uri: Uri.parse(_config.streamUrl)
          .replace(queryParameters: <String, String>{'token': _config.clientToken}),
      headers: <String, String>{
        'Authorization': 'Bearer ${_config.clientToken}',
        'Accept': 'text/event-stream',
      },
      onEvent: _handleEvent,
      onConnected: () {
        connected.value = true;
        unawaited(flushQueue());
      },
    );
  }

  Future<void> applyConfig(HubConfig config) async {
    _config = config;
    await config.save();
    _connectSse();
  }

  @override
  void dispose() {
    _sse?.dispose();
    for (final timer in _revisedTimers.values) {
      timer.cancel();
    }
    connected.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------
  // Offline queue (FR-2.3)

  Future<void> restoreQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('offlineActions');
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List;
        _queue = list.map(TriageActionReply.fromJson).toList();
      } on Exception {
        _queue = <TriageActionReply>[];
      }
    }
    final rawSnoozes = prefs.getString('offlineSnoozes');
    if (rawSnoozes != null) {
      try {
        final list = jsonDecode(rawSnoozes) as List;
        _snoozeQueue = list
            .whereType<Map>()
            .map((m) => Map<String, dynamic>.from(m))
            .toList();
      } on Exception {
        _snoozeQueue = <Map<String, dynamic>>[];
      }
    }
    _quietStart = prefs.getInt('quietStart');
    _quietEnd = prefs.getInt('quietEnd');
    final rawProcessed = prefs.getString(_processedKey);
    if (rawProcessed != null) {
      try {
        final list = jsonDecode(rawProcessed) as List;
        _processed
          ..clear()
          ..addAll(list
              .whereType<Map>()
              .map((m) => ProcessedEntry.fromJson(Map<String, dynamic>.from(m)))
              .take(_processedLimit));
      } on Exception {
        _processed.clear();
      }
    }
  }

  Future<void> _persistQueue() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'offlineActions',
      jsonEncode(_queue.map((r) => r.toJson()).toList()),
    );
  }

  Future<void> _persistSnoozes() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('offlineSnoozes', jsonEncode(_snoozeQueue));
  }

  Future<void> _persistProcessed() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _processedKey,
      jsonEncode(_processed.map((e) => e.toJson()).toList()),
    );
  }

  /// Appends a finished decision.
  void recordProcessed(ProcessedEntry entry) {
    _processed.insert(0, entry);
    while (_processed.length > _processedLimit) {
      _processed.removeLast();
    }
    unawaited(_persistProcessed());
    notifyListeners();
  }

  /// Undo coherence (I-120): drops the latest tray entry for [taskId].
  void removeProcessedFor(String taskId) {
    final index = _processed.indexWhere((e) => e.taskId == taskId);
    if (index == -1) return;
    _processed.removeAt(index);
    unawaited(_persistProcessed());
    notifyListeners();
  }

  /// Maps a hub dismiss `by` marker to a tray source label (I-512).
  static String sourceForDismissBy(String? by) {
    final marker = by ?? '';
    if (marker == 'withdraw') return 'withdraw';
    if (marker.startsWith('on_expire')) return 'expire';
    if (marker == 'auto_rule') return 'auto';
    return 'other';
  }

  /// Persists quiet hours (I-402); `start`/`end` are minutes-of-day, both
  /// null disables the window.
  Future<void> setQuietHours({int? start, int? end}) async {
    _quietStart = start;
    _quietEnd = end;
    final prefs = await SharedPreferences.getInstance();
    if (start == null || end == null) {
      await prefs.remove('quietStart');
      await prefs.remove('quietEnd');
    } else {
      await prefs.setInt('quietStart', start);
      await prefs.setInt('quietEnd', end);
    }
    notifyListeners();
  }

  /// Sends queued decisions and snoozes in order; stops at the first
  /// network error (still offline) keeping the tail. 409s count as
  /// delivered — the task was processed elsewhere (FR-3.3).
  Future<void> flushQueue() async {
    await _flushReplies();
    await _flushSnoozes();
  }

  Future<void> _flushReplies() async {
    if (_queue.isEmpty) return;
    final remaining = <TriageActionReply>[];
    for (var i = 0; i < _queue.length; i++) {
      final reply = _queue[i];
      final result = await api.sendAction(reply);
      if (result == ActionSendResult.networkError) {
        remaining.addAll(_queue.skip(i));
        break;
      }
      _stack.removeWhere((t) => t.taskId == reply.taskId);
      if (result == ActionSendResult.conflict) {
        _toast('処理済みのタスクです（別デバイスで承認済み）');
        onConflict?.call();
      } else if (result == ActionSendResult.rejected) {
        _toast('無効な操作を破棄しました');
      }
    }
    _queue = remaining;
    await _persistQueue();
    notifyListeners();
  }

  Future<void> _flushSnoozes() async {
    if (_snoozeQueue.isEmpty) return;
    final v2 = _v2;
    if (v2 == null) return;
    final remaining = <Map<String, dynamic>>[];
    for (var i = 0; i < _snoozeQueue.length; i++) {
      final entry = _snoozeQueue[i];
      final taskId = entry['taskId'] as String?;
      final nonce = entry['nonce'] as String?;
      final until = DateTime.tryParse('${entry['until'] ?? ''}');
      if (taskId == null || nonce == null || until == null) continue;
      final result = await v2.snooze(taskId: taskId, nonce: nonce, until: until);
      if (result == ActionSendResult.networkError) {
        remaining.addAll(_snoozeQueue.skip(i));
        break;
      }
      _hideForSnooze(taskId, until);
    }
    _snoozeQueue = remaining;
    await _persistSnoozes();
    notifyListeners();
  }

  // ------------------------------------------------------------------
  // Triage

  /// Optimistic path: the card is already gone from the screen (the
  /// swipe animation completed); we deliver the decision async and
  /// queue it when offline. Row selections (I-112) and inline value edits
  /// (I-114) are merged in for approve-like actions.
  Future<void> triage(
    TaskCard task, {
    required String actionName,
    Map<String, dynamic>? data,
    required String source,
    Object? learnRule = false,
  }) async {
    // Snapshot row selections/edits BEFORE remove() — remove clears them.
    final extras = (data?.containsKey('reason') ?? false) ||
            _nonApproveActions.contains(actionName)
        ? const <String, dynamic>{}
        : _approveExtras(task.taskId);
    remove(task.taskId);
    _rememberUndoable(task);
    recordProcessed(ProcessedEntry(
      taskId: task.taskId,
      summary: task.summary,
      actionName: actionName,
      source: actionName == 'snooze' ? 'snooze' : 'user',
      at: DateTime.now(),
      agentName: task.agent.name,
    ));
    _pendingActionIds.add(task.taskId);
    final merged = Map<String, dynamic>.from(data ?? const <String, dynamic>{})
      ..addAll(extras);
    if (_pendingActionIds.length > 500) _pendingActionIds.clear();
    final reply = TriageActionReply(
      taskId: task.taskId,
      nonce: task.nonce,
      actionName: actionName,
      timestamp: DateTime.now().toUtc(),
      source: source,
      data: merged,
      learnRule: learnRule,
    );
    final result = await _deliver(reply);
    if (result == ActionSendResult.sent) {
      _toast('$actionName しました', undoableTaskId: task.taskId);
      // I-1005: a committed decide action (not snooze/delegate/ask, not
      // already learning, not a partial multi-party approval) earns a
      // one-tap scoped-rule offer — the sheet does range+deadline+preview.
      if (!_nonApproveActions.contains(actionName) &&
          learnRule != true &&
          task.requiredApprovals <= 1) {
        onAutomatable?.call(
            task, actionName == 'reject' ? 'reject' : 'approve');
      }
    } else if (result == ActionSendResult.networkError) {
      _toast('オフライン: 端末に保存しました（再接続時に送信）',
          undoableTaskId: task.taskId);
    }
  }

  /// Bundled approval via `POST /api/v1/actions/bulk` (I-201): every
  /// member is removed optimistically and CASed independently.
  Future<void> bulkApprove(List<TaskCard> tasks) =>
      _bulkTriage(tasks, (t) => t.onSwipeRight, 'approve');

  Future<void> bulkReject(List<TaskCard> tasks) =>
      _bulkTriage(tasks, (t) => t.onSwipeLeft, 'reject');

  Future<void> _bulkTriage(
    List<TaskCard> tasks,
    ActionBinding? Function(TaskCard) binding,
    String fallback,
  ) async {
    if (tasks.isEmpty) return;
    final replies = <TriageActionReply>[];
    for (final task in tasks) {
      remove(task.taskId);
      _rememberUndoable(task);
      final b = binding(task);
      recordProcessed(ProcessedEntry(
        taskId: task.taskId,
        summary: task.summary,
        actionName: b?.actionName ?? fallback,
        source: 'user',
        at: DateTime.now(),
        agentName: task.agent.name,
      ));
      _pendingActionIds.add(task.taskId);
      replies.add(TriageActionReply(
        taskId: task.taskId,
        nonce: task.nonce,
        actionName: b?.actionName ?? fallback,
        timestamp: DateTime.now().toUtc(),
        source: ActionSource.bulk,
        data: b?.payload ?? const <String, dynamic>{},
      ));
    }
    if (_pendingActionIds.length > 500) _pendingActionIds.clear();
    final v2 = _v2;
    if (v2 == null) {
      for (final reply in replies) {
        await _deliver(reply);
      }
      _toast('${tasks.length}件まとめて処理しました',
          undoableTaskId: tasks.first.taskId);
      return;
    }
    final result = await v2.bulk(replies);
    if (result.networkError) {
      _queue.addAll(replies);
      await _persistQueue();
      _toast('オフライン: ${tasks.length}件を保存しました（再接続時に送信）',
          undoableTaskId: tasks.first.taskId);
      return;
    }
    final failed = result.failedCount;
    if (failed == 0) {
      _toast('${tasks.length}件まとめて処理しました',
          undoableTaskId: tasks.first.taskId);
    } else {
      _toast('${tasks.length - failed}件を処理、$failed件は失敗しました');
      if (result.results.any((r) => !r.ok)) onConflict?.call();
    }
  }

  /// Server-side snooze (I-102): hides the card on every device until
  /// [after] from now. Falls back to a local tail move + queued sync when
  /// the hub is unreachable.
  Future<void> serverSnooze(TaskCard task,
      {Duration after = const Duration(hours: 1)}) async {
    final until = DateTime.now().toUtc().add(after);
    final v2 = _v2;
    if (v2 == null) {
      snooze(task.taskId);
      recordProcessed(ProcessedEntry(
        taskId: task.taskId,
        summary: task.summary,
        actionName: 'snooze',
        source: 'snooze',
        at: DateTime.now(),
        agentName: task.agent.name,
      ));
      _toast('あとで（${_afterLabel(after)}）');
      return;
    }
    _pendingActionIds.add(task.taskId);
    final result =
        await v2.snooze(taskId: task.taskId, nonce: task.nonce, until: until);
    switch (result) {
      case ActionSendResult.sent:
        _hideForSnooze(task.taskId, until);
        recordProcessed(ProcessedEntry(
          taskId: task.taskId,
          summary: task.summary,
          actionName: 'snooze',
          source: 'snooze',
          at: DateTime.now(),
          agentName: task.agent.name,
        ));
        _toast('あとで（${_afterLabel(after)}）');
        break;
      case ActionSendResult.conflict:
        _stack.removeWhere((t) => t.taskId == task.taskId);
        _toast('処理済みのタスクです（別デバイスで承認済み）');
        onConflict?.call();
        notifyListeners();
        break;
      case ActionSendResult.rejected:
        _toast('スヌーズできませんでした');
        break;
      case ActionSendResult.networkError:
        snooze(task.taskId);
        recordProcessed(ProcessedEntry(
          taskId: task.taskId,
          summary: task.summary,
          actionName: 'snooze',
          source: 'snooze',
          at: DateTime.now(),
          agentName: task.agent.name,
        ));
        _snoozeQueue.add(<String, dynamic>{
          'taskId': task.taskId,
          'nonce': task.nonce,
          'until': until.toIso8601String(),
        });
        await _persistSnoozes();
        _toast('オフライン: 端末内であとで（再接続時に同期）');
        break;
    }
  }

  /// Hand a card to a colleague (I-501): the card stays pending and the
  /// hub records the assignee.
  Future<void> delegate(TaskCard task, String to) async {
    final name = to.trim();
    if (name.isEmpty) return;
    if (_delegatedTo[task.taskId] == name) {
      _toast('$name さんに回しています');
      return;
    }
    final v2 = _v2;
    if (v2 == null) {
      _toast('委任はハブの対応が必要です');
      return;
    }
    final result =
        await v2.delegate(taskId: task.taskId, nonce: task.nonce, to: name);
    switch (result) {
      case ActionSendResult.sent:
        _delegatedTo[task.taskId] = name;
        notifyListeners();
        _toast('$name さんに回しました');
        break;
      case ActionSendResult.conflict:
        _toast('処理済みのタスクです（別デバイスで承認済み）');
        onConflict?.call();
        break;
      case ActionSendResult.rejected:
        _toast('委任できませんでした');
        break;
      case ActionSendResult.networkError:
        _toast('オフライン: 委任できませんでした');
        break;
    }
  }

  void setRowSelection(String taskId, List<String> ids) {
    if (ids.isEmpty) {
      _rowSelections.remove(taskId);
    } else {
      _rowSelections[taskId] = List<String>.of(ids);
    }
    notifyListeners();
  }

  void setEditedValue(String taskId, String componentId, Object? value) {
    final map = _editedValues.putIfAbsent(taskId, () => <String, Object?>{});
    if (value == null) {
      map.remove(componentId);
      if (map.isEmpty) _editedValues.remove(taskId);
    } else {
      map[componentId] = value;
    }
    notifyListeners();
  }

  Map<String, dynamic> _approveExtras(String taskId) {
    final out = <String, dynamic>{};
    final rows = _rowSelections[taskId];
    if (rows != null && rows.isNotEmpty) {
      out['acceptedRows'] = List<String>.of(rows);
    }
    final edited = _editedValues[taskId];
    if (edited != null && edited.isNotEmpty) {
      final entry = edited.entries.first;
      out['edited'] = <String, dynamic>{
        'componentId': entry.key,
        'value': entry.value,
      };
    }
    return out;
  }

  /// Revert a triage decision. While the server-side reply is still in
  /// the undo grace window the hub restores the card (re-broadcast via
  /// createTaskCard); a locally queued (offline) reply is simply dropped
  /// and the card restored here (I-104).
  Future<void> undo(String taskId) async {
    final task = _undoable[taskId];
    if (task == null) {
      _toast('元に戻せません（この端末では操作していません）');
      return;
    }
    _undoable.remove(taskId);

    // Offline first: our decision may never have left the device.
    final before = _queue.length;
    _queue.removeWhere((r) => r.taskId == taskId);
    if (_queue.length != before) {
      await _persistQueue();
      _restore(task);
      removeProcessedFor(taskId);
      _toast('元に戻しました（送信前の操作を取り消し）');
      return;
    }

    final result = await api.undo(taskId: taskId, nonce: task.nonce);
    switch (result) {
      case UndoResult.undone:
        // The hub re-broadcasts the card via SSE; if the stream is down
        // the next snapshot still restores it (status pending).
        removeProcessedFor(taskId);
        _toast('元に戻しました');
        break;
      case UndoResult.tooLate:
      case UndoResult.notFound:
        _toast('元に戻せません（確定済み）');
        break;
      case UndoResult.rejected:
        _toast('元に戻せませんでした ($taskId)');
        break;
      case UndoResult.networkError:
        _undoable[taskId] = task; // keep for a later retry
        _toast('オフライン: まだ元に戻せていません');
        break;
    }
  }

  void _rememberUndoable(TaskCard task) {
    _undoable.remove(task.taskId); // re-insert to refresh recency
    _undoable[task.taskId] = task;
    while (_undoable.length > _undoableLimit) {
      _undoable.remove(_undoable.keys.first);
    }
  }

  void _restore(TaskCard task) {
    if (_stack.any((t) => t.taskId == task.taskId)) return;
    _stack.insert(0, task);
    notifyListeners();
  }

  /// 現在の並び順モードで山札を並べ直す。ローカルでスヌーズしたカードは
  /// どのモードでも山札の末尾に固定（既存動作を維持）。
  void _restack() {
    final now = DateTime.now();
    final nonSnoozed = <TaskCard>[
      for (final t in _stack)
        if (!_snoozedIds.contains(t.taskId)) t,
    ];
    final snoozed = <TaskCard>[
      for (final t in _stack)
        if (_snoozedIds.contains(t.taskId)) t,
    ];
    _stack = <TaskCard>[
      ...sortTasks(nonSnoozed, _order, now),
      ...sortTasks(snoozed, _order, now),
    ];
  }

  /// Delivers a reply, queueing on network failure. Returns the send
  /// result so callers can tailor their toast (undo offers I-104).
  Future<ActionSendResult> _deliver(TriageActionReply reply) async {
    final result = await api.sendAction(reply);
    switch (result) {
      case ActionSendResult.sent:
        break;
      case ActionSendResult.conflict:
        _toast('処理済みのタスクです（別デバイスで承認済み）');
        onConflict?.call();
        break;
      case ActionSendResult.rejected:
        _toast('送信が拒否されました (${reply.taskId})');
        break;
      case ActionSendResult.networkError:
        _queue.add(reply);
        await _persistQueue();
        break;
    }
    return result;
  }

  /// Client-local snooze fallback: move to the stack tail. Used when the
  /// hub cannot take a server snooze (offline) — the queued request syncs
  /// on reconnect.
  void snooze(String taskId) {
    final index = _stack.indexWhere((t) => t.taskId == taskId);
    if (index == -1) return;
    final task = _stack.removeAt(index);
    _snoozedIds.add(taskId);
    _stack.add(task);
    // スヌーズ集合は末尾に固定しつつ、内部は現在の並び順に従う。
    _restack();
    notifyListeners();
  }

  /// Moves a card to the top of the stack (I-105 pinch overview: tapping
  /// a tile brings that card back into focus).
  void bringToTop(String taskId) {
    final index = _stack.indexWhere((t) => t.taskId == taskId);
    if (index <= 0) return;
    final task = _stack.removeAt(index);
    _stack.insert(0, task);
    notifyListeners();
  }

  // ------------------------------------------------------------------
  // SSE events

  void _handleEvent(String event, String data) {
    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(data) as Map<String, dynamic>;
    } on FormatException {
      return; // malformed frame — ignore, never crash (FR-1.3)
    }
    switch (event) {
      case 'snapshot':
        _applySnapshotPayload(payload);
        break;
      case 'createTaskCard':
        upsert(TaskCard.fromJson(payload));
        break;
      case 'dismissTask':
        _handleDismiss(payload);
        break;
      case 'withdrawTask':
        final taskId = payload['taskId'] as String?;
        if (taskId != null) {
          remove(taskId, remote: true, remoteBy: 'withdraw');
        }
        break;
      case 'delegateTask':
        final taskId = payload['taskId'] as String?;
        final to = payload['to'] as String?;
        if (taskId != null && to != null && _delegatedTo[taskId] != to) {
          _delegatedTo[taskId] = to;
          notifyListeners();
          _toast('$to さんに回しました');
        }
        break;
      case 'approvalProgress':
        final taskId = payload['taskId'] as String?;
        final count = payload['count'];
        if (taskId != null && count is num) {
          _approvalProgress[taskId] = count.toInt();
          notifyListeners();
        }
        break;
      case 'pauseState':
        _paused = payload['paused'] == true;
        _pauseUntil = DateTime.tryParse('${payload['until'] ?? ''}');
        notifyListeners();
        _toast(_paused ? '緊急停止中です' : '再開しました');
        break;
      case 'deliveryFailed':
        final taskId = payload['taskId'] as String?;
        if (taskId != null && _deliveryFailed.add(taskId)) {
          notifyListeners();
          _toast('エージェントへの返送に失敗しました ($taskId)');
        }
        break;
      default:
        break;
    }
  }

  void _applySnapshotPayload(Map<String, dynamic> payload) {
    final rawTasks = payload['tasks'];
    final tasks = rawTasks is List
        ? rawTasks
            .whereType<Map>()
            .map((t) => TaskCard.fromJson(Map<String, dynamic>.from(t)))
            .toList()
        : <TaskCard>[];
    final snoozed = payload['snoozed'] is List
        ? (payload['snoozed'] as List)
            .whereType<Map>()
            .map((m) => Map<String, dynamic>.from(m))
            .toList()
        : <Map<String, dynamic>>[];
    final rawApproval = payload['approvalProgress'];
    final progress = rawApproval is Map
        ? <String, int>{
            for (final entry in rawApproval.entries)
              '${entry.key}':
                  entry.value is num ? (entry.value as num).toInt() : 0,
          }
        : <String, int>{};
    final delivery = payload['delivery'] is List
        ? (payload['delivery'] as List)
            .whereType<Map>()
            .map((m) => Map<String, dynamic>.from(m))
            .toList()
        : <Map<String, dynamic>>[];
    applySnapshotEnvelope(
      tasks: tasks,
      snoozed: snoozed,
      paused: payload['paused'] is bool ? payload['paused'] as bool : null,
      approvalProgress: progress,
      delivery: delivery,
    );
  }

  void _handleDismiss(Map<String, dynamic> payload) {
    final taskId = payload['taskId'] as String?;
    if (taskId == null) return;
    final by = payload['by'] as String?;
    if (by == 'snooze') {
      _hideForSnooze(taskId, DateTime.tryParse('${payload['snoozedUntil'] ?? ''}'));
      return;
    }
    remove(taskId, remote: true, remoteBy: by);
  }

  void _hideForSnooze(String taskId, DateTime? until) {
    _pendingActionIds.remove(taskId);
    _serverSnoozed[taskId] = until ?? DateTime.now().add(const Duration(hours: 1));
    _stack.removeWhere((t) => t.taskId == taskId);
    _snoozedIds.remove(taskId);
    _rowSelections.remove(taskId);
    _editedValues.remove(taskId);
    notifyListeners();
  }

  // ------------------------------------------------------------------
  // Stack mutations (public: also exercised by tests)

  /// Replaces the stack from a server snapshot (newest-first).
  /// Tasks with decisions still sitting in the offline queue are
  /// excluded so a queued decision is not resurrected.
  void applySnapshot(List<TaskCard> tasks) {
    final fresh = _filterQueued(tasks)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    _reconcile(fresh);
  }

  /// Full snapshot envelope (wave-2): tasks, server snoozes, pause state,
  /// approval progress and delivery failures, reconciled wholesale.
  void applySnapshotEnvelope({
    required List<TaskCard> tasks,
    List<Map<String, dynamic>> snoozed = const <Map<String, dynamic>>[],
    bool? paused,
    Map<String, int> approvalProgress = const <String, int>{},
    List<Map<String, dynamic>> delivery = const <Map<String, dynamic>>[],
  }) {
    if (paused != null) _paused = paused;
    _serverSnoozed
      ..clear()
      ..addAll(<String, DateTime>{
        for (final entry in snoozed)
          if (entry['taskId'] is String)
            entry['taskId'] as String:
                DateTime.tryParse('${entry['until'] ?? ''}') ??
                    DateTime.now().add(const Duration(hours: 1)),
      });
    _approvalProgress
      ..clear()
      ..addAll(approvalProgress);
    _deliveryFailed
      ..clear()
      ..addAll(<String>{
        for (final entry in delivery)
          if (entry['taskId'] is String) entry['taskId'] as String,
      });
    final fresh = _filterQueued(tasks)
      ..sort((a, b) {
        final pa = a.priority ?? double.negativeInfinity;
        final pb = b.priority ?? double.negativeInfinity;
        final cmp = pb.compareTo(pa);
        return cmp != 0 ? cmp : a.createdAt.compareTo(b.createdAt);
      });
    _reconcile(fresh);
  }

  List<TaskCard> _filterQueued(List<TaskCard> tasks) {
    final queuedIds = _queue.map((r) => r.taskId).toSet();
    return tasks
        .where((t) => !queuedIds.contains(t.taskId))
        .toList();
  }

  void _reconcile(List<TaskCard> fresh) {
    _snoozedIds.removeWhere(
      (id) => !fresh.any((t) => t.taskId == id),
    );
    final visible = fresh
        .where((t) => !_serverSnoozed.containsKey(t.taskId))
        .toList();
    _stack = visible;
    _restack();
    notifyListeners();
  }

  /// The hub may re-broadcast a card we already hold (I-203 escalate /
  /// I-204 update / snooze resurface). The hub is the single source of
  /// truth (P9), so replace in place instead of ignoring the event.
  void upsert(TaskCard task) {
    final resurfaced = _serverSnoozed.remove(task.taskId) != null;
    final index = _stack.indexWhere((t) => t.taskId == task.taskId);
    if (index != -1) {
      _stack[index] = task;
    } else if (resurfaced) {
      _stack.insert(0, task);
    } else if (_snoozedIds.contains(task.taskId)) {
      _stack.add(task);
    } else {
      _stack.add(task);
    }
    if (task.revised) _flashRevised(task.taskId);
    // 新規は末尾に積み、既存（I-203 escalate など）は置換後に
    // 現在のモードで並べ直す。
    _restack();
    notifyListeners();
  }

  void _flashRevised(String taskId) {
    _revisedIds.add(taskId);
    _revisedTimers[taskId]?.cancel();
    _revisedTimers[taskId] = Timer(const Duration(seconds: 4), () {
      _revisedIds.remove(taskId);
      _revisedTimers.remove(taskId);
      notifyListeners();
    });
  }

  void remove(String? taskId, {bool remote = false, String? remoteBy}) {
    if (taskId == null) return;
    // Our own decision echo — the card is already gone; never re-toast it.
    // The local triage already recorded the tray entry, so do not double
    // it — but snooze echoes must not resurrect a snooze entry either.
    if (remote && _pendingActionIds.remove(taskId)) {
      _stack.removeWhere((t) => t.taskId == taskId);
      _serverSnoozed.remove(taskId);
      _snoozedIds.remove(taskId);
      notifyListeners();
      return;
    }
    final index = _stack.indexWhere((t) => t.taskId == taskId);
    _serverSnoozed.remove(taskId);
    final known = index != -1 ? _stack[index] : null;
    if (index == -1) return;
    _stack.removeAt(index);
    _snoozedIds.remove(taskId);
    _rowSelections.remove(taskId);
    _editedValues.remove(taskId);
    if (remote) {
      final by = remoteBy ?? '';
      if (known != null) {
        recordProcessed(ProcessedEntry(
          taskId: taskId,
          summary: known.summary,
          actionName: actionForDismissBy(remoteBy),
          source: sourceForDismissBy(remoteBy),
          at: DateTime.now(),
          agentName: known.agent.name,
        ));
      }
      if (by == 'snooze') {
        // handled by _hideForSnooze; stay silent defensively
      } else if (by.startsWith('on_expire')) {
        _toast('期限のため自動処理されました ($taskId)');
      } else if (by == 'withdraw') {
        _toast('エージェントが取り下げました ($taskId)');
      } else {
        _toast('別のデバイスで処理されました ($taskId)');
      }
    }
    notifyListeners();
  }

  static String _afterLabel(Duration after) {
    if (after.inHours <= 1) return '1時間後';
    if (after.inHours <= 24) return '明朝';
    return '${after.inHours}時間後';
  }

  void _toast(String message, {String? undoableTaskId}) {
    _lastToast = message;
    _toastSeq++;
    onToast?.call(message, undoableTaskId: undoableTaskId);
  }
}
