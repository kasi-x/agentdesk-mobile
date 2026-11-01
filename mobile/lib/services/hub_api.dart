import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/task_card.dart';
import '../models/triage_action.dart';

enum ActionSendResult { sent, conflict, rejected, networkError }

enum UndoResult { undone, tooLate, notFound, rejected, networkError }

abstract class HubApi {
  Future<List<TaskCard>> fetchPendingTasks();
  Future<ActionSendResult> sendAction(TriageActionReply reply);
  Future<UndoResult> undo({required String taskId, required String nonce});
}

/// One item's outcome inside a `POST /api/v1/actions/bulk` response.
class BulkItemResult {
  final String taskId;
  final bool ok;

  /// Hub error code when `ok` is false (`bad_nonce`, …).
  final String? error;

  const BulkItemResult({required this.taskId, required this.ok, this.error});
}

class BulkResult {
  final List<BulkItemResult> results;

  /// True when the request never reached the hub (offline).
  final bool networkError;

  const BulkResult({this.results = const <BulkItemResult>[], this.networkError = false});

  int get failedCount => results.where((r) => !r.ok).length;
}
/// One auto-approval rule (I-304/I-807): the client mirror of `Rule` in
/// `backend/src/protocol.ts`. Rules match NEW pending cards only — the hub
/// approves matches with `source: "auto_rule"` against the rule's lease.
class AutoApprovalRule {
  final String id;

  /// approve | reject — what a match does (I-1002, default approve).
  /// Parsed tolerantly: anything but `reject` reads as approve so old
  /// hubs (no `action` key) keep working.
  final String action;

  /// manual | learned — display-only origin mark (`learned` = created by
  /// a swipe via `learnRule: true`, I-1003). Absent on old hubs; never
  /// used in match logic.
  final String? source;

  /// Substring of `agent.name`; null = any agent.
  final String? agent;

  /// Allowed severities; empty = any.
  final List<String> severity;

  /// Maximum `impact.cost.amount`; null = any.
  final double? maxCost;

  /// Minimum card confidence 0–1; null = any (I-1002).
  final double? minConfidence;

  /// Substring of `groupKey`; null = any.
  final String? groupKey;

  /// ISO 8601 instant after which the rule stops firing; null = no expiry.
  final String? leaseUntil;

  /// Maximum auto-approvals before the rule stops; null = unlimited.
  final int? leaseMaxCount;

  final bool enabled;

  const AutoApprovalRule({
    required this.id,
    this.action = 'approve',
    this.source,
    this.agent,
    this.severity = const <String>[],
    this.maxCost,
    this.minConfidence,
    this.groupKey,
    this.leaseUntil,
    this.leaseMaxCount,
    this.enabled = true,
  });

  factory AutoApprovalRule.fromJson(Map<String, dynamic> raw) {
    final match = raw['match'] is Map
        ? Map<String, dynamic>.from(raw['match'] as Map)
        : const <String, dynamic>{};
    final lease = raw['lease'] is Map
        ? Map<String, dynamic>.from(raw['lease'] as Map)
        : null;
    final severityRaw = match['severity'];
    final maxCostRaw = match['maxCost'];
    final minConfRaw = match['minConfidence'];
    final maxCountRaw = lease?['maxCount'];
    final actionRaw = raw['action'];
    final sourceRaw = raw['source'];
    return AutoApprovalRule(
      id: '${raw['id'] ?? ''}',
      action: actionRaw == 'reject' ? 'reject' : 'approve',
      source: sourceRaw is String ? sourceRaw : null,
      agent: match['agent'] is String ? match['agent'] : null,
      severity:
          severityRaw is List ? severityRaw.whereType<String>().toList() : const <String>[],
      maxCost: maxCostRaw is num ? maxCostRaw.toDouble() : null,
      minConfidence: minConfRaw is num
          ? minConfRaw.toDouble().clamp(0.0, 1.0)
          : null,
      groupKey: match['groupKey'] is String ? match['groupKey'] as String : null,
      leaseUntil: lease?['until'] is String ? lease!['until'] : null,
      leaseMaxCount: maxCountRaw is num ? maxCountRaw.toInt() : null,
      enabled: raw['enabled'] is bool ? raw['enabled'] as bool : true,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'action': action,
        'match': <String, dynamic>{
          if (agent != null) 'agent': agent,
          if (severity.isNotEmpty) 'severity': severity,
          if (maxCost != null) 'maxCost': maxCost,
          if (minConfidence != null) 'minConfidence': minConfidence,
          if (groupKey != null) 'groupKey': groupKey,
        },
        if (source != null) 'source': source,
        if (leaseUntil != null || leaseMaxCount != null)
          'lease': <String, dynamic>{
            if (leaseUntil != null) 'until': leaseUntil,
            if (leaseMaxCount != null) 'maxCount': leaseMaxCount,
          },
        'enabled': enabled,
      };

  AutoApprovalRule copyWith({
    String? action,
    String? source,
    String? agent,
    List<String>? severity,
    double? maxCost,
    double? minConfidence,
    String? groupKey,
    String? leaseUntil,
    int? leaseMaxCount,
    bool? enabled,
    bool clearAgent = false,
    bool clearMaxCost = false,
    bool clearMinConfidence = false,
    bool clearGroupKey = false,
    bool clearLeaseUntil = false,
    bool clearLeaseMaxCount = false,
    bool clearSource = false,
  }) =>
      AutoApprovalRule(
        id: id,
        action: action ?? this.action,
        source: clearSource ? null : (source ?? this.source),
        agent: clearAgent ? null : (agent ?? this.agent),
        severity: severity ?? this.severity,
        maxCost: clearMaxCost ? null : (maxCost ?? this.maxCost),
        minConfidence:
            clearMinConfidence ? null : (minConfidence ?? this.minConfidence),
        groupKey: clearGroupKey ? null : (groupKey ?? this.groupKey),
        leaseUntil: clearLeaseUntil ? null : (leaseUntil ?? this.leaseUntil),
        leaseMaxCount:
            clearLeaseMaxCount ? null : (leaseMaxCount ?? this.leaseMaxCount),
        enabled: enabled ?? this.enabled,
      );
}

/// Rules surface: `GET/PUT /api/v1/rules` (whole-list replace). Kept
/// separate from [HubApiV2] so existing fakes stay source-compatible;
/// callers probe with `api is HubRulesApi` and render read-only offline.
abstract class HubRulesApi {
  /// Returns null when the list could not be read (offline / hub error).
  Future<List<AutoApprovalRule>?> fetchRules();

  /// Replaces the whole rule set; false when the save did not reach the hub.
  Future<bool> saveRules(List<AutoApprovalRule> rules);
}

/// One dry-run count from `POST /api/v1/rules/simulate` (I-1002):
/// `{sampleSize, autoApprove, autoReject, hitl}`. All counts ≥ 0 and
/// `autoApprove + autoReject + hitl ≤ sampleSize` on a well-formed hub.
class SimulateResult {
  final int sampleSize;
  final int autoApprove;
  final int autoReject;
  final int hitl;

  const SimulateResult({
    required this.sampleSize,
    required this.autoApprove,
    required this.autoReject,
    required this.hitl,
  });

  factory SimulateResult.fromJson(Map<String, dynamic> raw) {
    int count(Object? v) => v is num ? v.toInt().clamp(0, 1 << 30) : 0;
    return SimulateResult(
      sampleSize: count(raw['sampleSize']),
      autoApprove: count(raw['autoApprove']),
      autoReject: count(raw['autoReject']),
      hitl: count(raw['hitl']),
    );
  }
}

/// Uploaded blob reference (I-1001): `POST /api/v1/attachments`
/// `{kind, contentType, dataBase64}` → `{id, url}`.
class AttachmentRef {
  final String id;
  final String url;

  const AttachmentRef({required this.id, required this.url});

  factory AttachmentRef.fromJson(Map<String, dynamic> raw) =>
      AttachmentRef(id: '${raw['id'] ?? ''}', url: '${raw['url'] ?? ''}');
}

/// Executive Desk server surface (I-1001/I-1002): rule dry-run plus
/// attachment upload. Kept separate from [HubApi]/[HubRulesApi] so
/// existing fakes stay source-compatible; callers probe with
/// `api is HubGuardrailsApi` and hide the preview / fail the upload
/// gracefully when absent. Old hubs (404 on these routes) surface as
/// null/false — never a crash.
abstract class HubGuardrailsApi {
  /// Dry-runs `match`+`action` on top of the stored rules over the hub's
  /// recent-card sample. Both null = dry-run the current set.
  /// Returns null when unsupported or unreachable (old hub / offline).
  Future<SimulateResult?> simulateRules({
    Map<String, dynamic>? match,
    String? action,
  });

  /// Uploads one audio/image blob. Null bytes/invalid args return null;
  /// network or hub errors return null (callers keep the field empty).
  Future<AttachmentRef?> uploadAttachment({
    required String kind,
    required String contentType,
    required String dataBase64,
  });
}

/// Wave-2 server surface: server-side snooze, delegation and bulk triage
/// (docs/protocol.md). Kept separate from [HubApi] so existing
/// implementations and tests stay source-compatible; callers probe with
/// `api is HubApiV2` and degrade to local handling when absent.
abstract class HubApiV2 {
  /// `POST /actions {action:"snooze", until}` — hides the card on every
  /// device until [until] without consuming the nonce.
  Future<ActionSendResult> snooze({
    required String taskId,
    required String nonce,
    required DateTime until,
  });

  /// `POST /actions {action:"delegate", data:{to}}` — the card stays
  /// pending and the hub records the assignee.
  Future<ActionSendResult> delegate({
    required String taskId,
    required String nonce,
    required String to,
  });

  /// `POST /actions {action:"ask", data:{question}}` — forwards the
  /// question to the agent's replyUrl; the card stays pending (I-504).
  Future<ActionSendResult> ask({
    required String taskId,
    required String nonce,
    required String question,
  });

  /// `POST /actions/bulk` — each item CASed independently (I-201).
  Future<BulkResult> bulk(List<TriageActionReply> actions);
}

class HttpHubApi implements HubApi, HubApiV2, HubRulesApi, HubGuardrailsApi {
  final HubConfig config;
  final http.Client _client;

  HttpHubApi({required this.config, http.Client? client})
      : _client = client ?? http.Client();

  Uri _uri(String path) => Uri.parse('${config.apiBase}$path');

  Map<String, String> get _headers => <String, String>{
        'Authorization': 'Bearer ${config.clientToken}',
        'Content-Type': 'application/json',
      };

  @override
  Future<List<TaskCard>> fetchPendingTasks() async {
    try {
      final res = await _client
          .get(_uri('/state'), headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return <TaskCard>[];
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      if (body is! Map || body['tasks'] is! List) return <TaskCard>[];
      return (body['tasks'] as List)
          .map((t) => TaskCard.fromJson(Map<String, dynamic>.from(t as Map)))
          .toList();
    } on Exception {
      return <TaskCard>[];
    }
  }

  @override
  Future<ActionSendResult> sendAction(TriageActionReply reply) async {
    try {
      final res = await _client
          .post(_uri('/actions'), headers: _headers, body: jsonEncode(reply.toJson()))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) return ActionSendResult.sent;
      if (res.statusCode == 409) return ActionSendResult.conflict;
      return ActionSendResult.rejected;
    } on TimeoutException {
      return ActionSendResult.networkError;
    } on http.ClientException {
      return ActionSendResult.networkError;
    }
  }

  @override
  Future<UndoResult> undo({required String taskId, required String nonce}) async {
    try {
      final res = await _client
          .post(
            _uri('/actions/undo'),
            headers: _headers,
            body: jsonEncode(<String, String>{'taskId': taskId, 'nonce': nonce}),
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) return UndoResult.undone;
      if (res.statusCode == 404) return UndoResult.notFound;
      if (res.statusCode == 409) {
        // too_late vs bad_nonce: both mean the undo cannot proceed; the
        // caller only needs "failed" vs "succeeded".
        return UndoResult.tooLate;
      }
      return UndoResult.rejected;
    } on TimeoutException {
      return UndoResult.networkError;
    } on http.ClientException {
      return UndoResult.networkError;
    }
  }

  @override
  Future<ActionSendResult> snooze({
    required String taskId,
    required String nonce,
    required DateTime until,
  }) async {
    try {
      final res = await _client
          .post(
            _uri('/actions'),
            headers: _headers,
            body: jsonEncode(<String, dynamic>{
              'taskId': taskId,
              'nonce': nonce,
              'action': 'snooze',
              'until': until.toUtc().toIso8601String(),
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) return ActionSendResult.sent;
      if (res.statusCode == 409) return ActionSendResult.conflict;
      return ActionSendResult.rejected;
    } on TimeoutException {
      return ActionSendResult.networkError;
    } on http.ClientException {
      return ActionSendResult.networkError;
    }
  }

  @override
  Future<ActionSendResult> delegate({
    required String taskId,
    required String nonce,
    required String to,
  }) async {
    try {
      final res = await _client
          .post(
            _uri('/actions'),
            headers: _headers,
            body: jsonEncode(<String, dynamic>{
              'taskId': taskId,
              'nonce': nonce,
              'action': 'delegate',
              'data': <String, dynamic>{'to': to},
              'source': ActionSource.delegate,
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) return ActionSendResult.sent;
      if (res.statusCode == 409) return ActionSendResult.conflict;
      return ActionSendResult.rejected;
    } on TimeoutException {
      return ActionSendResult.networkError;
    } on http.ClientException {
      return ActionSendResult.networkError;
    }
  }

  @override
  Future<ActionSendResult> ask({
    required String taskId,
    required String nonce,
    required String question,
  }) async {
    try {
      final res = await _client
          .post(
            _uri('/actions'),
            headers: _headers,
            body: jsonEncode(<String, dynamic>{
              'taskId': taskId,
              'nonce': nonce,
              'action': 'ask',
              'data': <String, dynamic>{'question': question},
              'source': ActionSource.ask,
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) return ActionSendResult.sent;
      if (res.statusCode == 409) return ActionSendResult.conflict;
      return ActionSendResult.rejected;
    } on TimeoutException {
      return ActionSendResult.networkError;
    } on http.ClientException {
      return ActionSendResult.networkError;
    }
  }

  @override
  Future<BulkResult> bulk(List<TriageActionReply> actions) async {
    try {
      final res = await _client
          .post(
            _uri('/actions/bulk'),
            headers: _headers,
            body: jsonEncode(<String, dynamic>{
              'actions': [
                for (final reply in actions)
                  <String, dynamic>{
                    'taskId': reply.taskId,
                    'nonce': reply.nonce,
                    'action': reply.actionName,
                    'source': reply.source,
                    if (reply.data.isNotEmpty) 'data': reply.data,
                    if (reply.learnRule != null && reply.learnRule != false)
                      'learnRule': reply.learnRule,
                  },
              ],
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return const BulkResult(networkError: false);
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      if (body is! Map || body['results'] is! List) {
        return const BulkResult();
      }
      return BulkResult(
        results: [
          for (final item in body['results'] as List)
            if (item is Map)
              BulkItemResult(
                taskId: '${item['taskId'] ?? ''}',
                ok: item['ok'] == true,
                error: item['error'] is String ? item['error'] as String : null,
              ),
        ],
      );
    } on TimeoutException {
      return const BulkResult(networkError: true);
    } on http.ClientException {
      return const BulkResult(networkError: true);
    }
  }

  @override
  Future<List<AutoApprovalRule>?> fetchRules() async {
    try {
      final res = await _client
          .get(_uri('/rules'), headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      if (body is! Map || body['rules'] is! List) return null;
      return <AutoApprovalRule>[
        for (final item in body['rules'] as List)
          if (item is Map)
            AutoApprovalRule.fromJson(Map<String, dynamic>.from(item)),
      ];
    } on Exception {
      return null;
    }
  }

  @override
  Future<bool> saveRules(List<AutoApprovalRule> rules) async {
    try {
      final res = await _client
          .put(
            _uri('/rules'),
            headers: _headers,
            body: jsonEncode(<String, dynamic>{
              'rules': [for (final rule in rules) rule.toJson()],
            }),
          )
          .timeout(const Duration(seconds: 10));
      return res.statusCode == 200;
    } on Exception {
      return false;
    }
  }
  @override
  Future<SimulateResult?> simulateRules({
    Map<String, dynamic>? match,
    String? action,
  }) async {
    try {
      final res = await _client
          .post(
            _uri('/rules/simulate'),
            headers: _headers,
            body: jsonEncode(<String, dynamic>{
              if (match != null) 'match': match,
              if (action != null) 'action': action,
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      if (body is! Map) return null;
      return SimulateResult.fromJson(Map<String, dynamic>.from(body));
    } on Exception {
      return null;
    }
  }

  @override
  Future<AttachmentRef?> uploadAttachment({
    required String kind,
    required String contentType,
    required String dataBase64,
  }) async {
    if (kind != 'audio' && kind != 'image') return null;
    if (contentType.isEmpty || dataBase64.isEmpty) return null;
    try {
      final res = await _client
          .post(
            _uri('/attachments'),
            headers: _headers,
            body: jsonEncode(<String, dynamic>{
              'kind': kind,
              'contentType': contentType,
              'dataBase64': dataBase64,
            }),
          )
          .timeout(const Duration(seconds: 30));
      if (res.statusCode != 200 && res.statusCode != 201) return null;
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      if (body is! Map) return null;
      final ref = AttachmentRef.fromJson(Map<String, dynamic>.from(body));
      if (ref.id.isEmpty) return null;
      return ref;
    } on Exception {
      return null;
    }
  }


  /// Native push registration (APNs/FCM): `POST /api/v1/push/native`
  /// `{platform: "apns"|"fcm", token}`. True on 200/201, false otherwise
  /// (offline / hub error). No `dart:io` — same http client + error style
  /// as the rest of this class.
  Future<bool> registerNativePush({
    required String platform,
    required String token,
  }) async {
    try {
      final res = await _client
          .post(
            _uri('/push/native'),
            headers: _headers,
            body: jsonEncode(<String, String>{
              'platform': platform,
              'token': token,
            }),
          )
          .timeout(const Duration(seconds: 10));
      return res.statusCode == 200 || res.statusCode == 201;
    } on TimeoutException {
      return false;
    } on http.ClientException {
      return false;
    }
  }
}
