import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../models/task_card.dart';
import '../models/triage_action.dart';
import 'hub_api.dart';
import 'sse_client.dart';

/// Owns the triage stack: optimistic removal (FR-2.1), async delivery +
/// offline queue (FR-2.2/2.3), snapshot reconciliation and remote
/// dismissals (FR-3.2/3.3). See docs/architecture.md.
class TaskRepository extends ChangeNotifier {
  final HubApi api;
  final ValueNotifier<bool> connected = ValueNotifier<bool>(false);

  HubConfig _config;
  SseClient? _sse;
  List<TaskCard> _stack = <TaskCard>[];
  final Set<String> _snoozedIds = <String>{};
  List<TriageActionReply> _queue = <TriageActionReply>[];
  /// Cards triaged this session, kept for undo (I-104). Insertion order
  /// = recency; bounded so a long session cannot grow it unboundedly.
  final Map<String, TaskCard> _undoable = <String, TaskCard>{};
  static const int _undoableLimit = 30;
  String? _lastToast;
  int _toastSeq = 0;
  TaskRepository({required HubConfig config, HubApi? api})
      : _config = config,
        api = api ?? HttpHubApi(config: config);

  List<TaskCard> get stack => List.unmodifiable(_stack);
  int get pendingCount => _stack.length;
  HubConfig get config => _config;
  bool get hasQueuedActions => _queue.isNotEmpty;
  String? get lastToast => _lastToast;
  int get toastSeq => _toastSeq;

  /// The UI plugs a snackbar shower in here; [toastSeq] disambiguates
  /// repeated messages. `undoableTaskId` is set when the toast announces
  /// a triage decision inside the undo grace window (I-104) and the UI
  /// should offer a "元に戻す" action calling [undo].
  void Function(String message, {String? undoableTaskId})? onToast;

  /// Fires when the hub reports 409 (task already processed elsewhere).
  /// The UI maps it to a double haptic tap (I-131).
  void Function()? onConflict;

  // ------------------------------------------------------------------
  // Lifecycle

  void start() => _connectSse();

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
    connected.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------
  // Offline queue (FR-2.3)

  Future<void> restoreQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('offlineActions');
    if (raw == null) return;
    try {
      final list = jsonDecode(raw) as List;
      _queue = list.map(TriageActionReply.fromJson).toList();
    } on Exception {
      _queue = <TriageActionReply>[];
    }
  }

  Future<void> _persistQueue() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'offlineActions',
      jsonEncode(_queue.map((r) => r.toJson()).toList()),
    );
  }

  /// Sends queued decisions in order; stops at the first network error
  /// (still offline) keeping the tail. 409s count as delivered — the
  /// task was processed elsewhere (FR-3.3).
  Future<void> flushQueue() async {
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

  // ------------------------------------------------------------------
  // Triage

  /// Optimistic path: the card is already gone from the screen (the
  /// swipe animation completed); we deliver the decision async and
  /// queue it when offline.
  Future<void> triage(
    TaskCard task, {
    required String actionName,
    Map<String, dynamic>? data,
    required String source,
  }) async {
    remove(task.taskId);
    _rememberUndoable(task);
    final reply = TriageActionReply(
      taskId: task.taskId,
      nonce: task.nonce,
      actionName: actionName,
      timestamp: DateTime.now().toUtc(),
      source: source,
      data: data ?? const <String, dynamic>{},
    );
    final result = await _deliver(reply);
    if (result == ActionSendResult.sent) {
      _toast('$actionName しました', undoableTaskId: task.taskId);
    } else if (result == ActionSendResult.networkError) {
      _toast('オフライン: 端末に保存しました（再接続時に送信）',
          undoableTaskId: task.taskId);
    }
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
      _toast('元に戻しました（送信前の操作を取り消し）');
      return;
    }

    final result =
        await api.undo(taskId: taskId, nonce: task.nonce);
    switch (result) {
      case UndoResult.undone:
        // The hub re-broadcasts the card via SSE; if the stream is down
        // the next snapshot still restores it (status pending).
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

  /// Client-local snooze: move to the stack tail. Timed re-notification
  /// is a Phase 2 item.
  void snooze(String taskId) {
    final index = _stack.indexWhere((t) => t.taskId == taskId);
    if (index == -1) return;
    final task = _stack.removeAt(index);
    _snoozedIds.add(taskId);
    _stack.add(task);
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
        applySnapshot(
          (payload['tasks'] as List? ?? <dynamic>[])
              .map((t) => TaskCard.fromJson(Map<String, dynamic>.from(t as Map)))
              .toList(),
        );
        break;
      case 'createTaskCard':
        upsert(TaskCard.fromJson(payload));
        break;
      case 'dismissTask':
        remove(payload['taskId'] as String?, remote: true);
        break;
      default:
        break;
    }
  }

  // ------------------------------------------------------------------
  // Stack mutations (public: also exercised by tests)

  /// Replaces the stack from a server snapshot (oldest→newest).
  /// Tasks with decisions still sitting in the offline queue are
  /// excluded so a queued decision is not resurrected.
  void applySnapshot(List<TaskCard> tasks) {
    final queuedIds = _queue.map((r) => r.taskId).toSet();
    final fresh =
        tasks.where((t) => !queuedIds.contains(t.taskId)).toList();
    fresh.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    _snoozedIds.removeWhere(
      (id) => !fresh.any((t) => t.taskId == id),
    );
    _stack = <TaskCard>[
      ...fresh.where((t) => !_snoozedIds.contains(t.taskId)),
      ...fresh.where((t) => _snoozedIds.contains(t.taskId)),
    ];
    notifyListeners();
  }

  void upsert(TaskCard task) {
    if (_stack.any((t) => t.taskId == task.taskId)) return;
    if (_snoozedIds.contains(task.taskId)) {
      _stack.add(task);
    } else {
      _stack.insert(0, task);
    }
    notifyListeners();
  }

  void remove(String? taskId, {bool remote = false}) {
    if (taskId == null) return;
    final index = _stack.indexWhere((t) => t.taskId == taskId);
    if (index == -1) return;
    _stack.removeAt(index);
    _snoozedIds.remove(taskId);
    if (remote) _toast('別のデバイスで処理されました ($taskId)');
    notifyListeners();
  }

  void _toast(String message, {String? undoableTaskId}) {
    _lastToast = message;
    _toastSeq++;
    onToast?.call(message, undoableTaskId: undoableTaskId);
  }
}
