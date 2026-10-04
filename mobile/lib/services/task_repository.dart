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
  /// repeated messages.
  void Function(String message)? onToast;

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
    final reply = TriageActionReply(
      taskId: task.taskId,
      nonce: task.nonce,
      actionName: actionName,
      timestamp: DateTime.now().toUtc(),
      source: source,
      data: data ?? const <String, dynamic>{},
    );
    await _deliver(reply);
  }

  Future<void> _deliver(TriageActionReply reply) async {
    final result = await api.sendAction(reply);
    switch (result) {
      case ActionSendResult.sent:
        _lastUndoneTask = null;
        _lastUndoneTask = _UndoneTask(taskId: reply.taskId, at: DateTime.now());
        _toast('処理しました');
        break;
      case ActionSendResult.conflict:
        _toast('処理済みのタスクです（別デバイスで承認済み）');
        break;
      case ActionSendResult.rejected:
        _toast('送信が拒否されました (${reply.taskId})');
        break;
      case ActionSendResult.networkError:
        _queue.add(reply);
        await _persistQueue();
        _toast('オフライン: 端末に保存しました（再接続時に送信）');
        break;
    }
  }

  _UndoneTask? _lastUndoneTask;

  /// The most recently triaged task id, while its server grace window
  /// (I-104) may still be open. Private type stays out of the public API.
  String? get lastUndoneTaskId => _lastUndoneTask?.taskId;

  void clearUndoWindow() {
    _lastUndoneTask = null;
    notifyListeners();
  }

  /// Ask the hub to revive the last triaged task (I-104). The revived card
  /// arrives via SSE `createTaskCard`; a late window reports it.
  Future<void> undoLast() async {
    final pending = _lastUndoneTask;
    if (pending == null) return;
    _lastUndoneTask = null;
    notifyListeners();
    final result = await api.sendUndo(pending.taskId);
    switch (result) {
      case UndoResult.undone:
        _toast('元に戻しました');
        break;
      case UndoResult.tooLate:
      case UndoResult.notFound:
        _toast('取り消し期限を過ぎています');
        break;
      case UndoResult.rejected:
        _toast('取り消しが拒否されました');
        break;
      case UndoResult.networkError:
        _toast('オフライン: 取り消しできませんでした');
        break;
    }
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

  void _toast(String message) {
    _lastToast = message;
    _toastSeq++;
    onToast?.call(message);
  }
}

/// A triage awaiting the end of its server Undo grace window (I-104).
class _UndoneTask {
  final String taskId;
  final DateTime at;

  _UndoneTask({required this.taskId, required this.at});
}
