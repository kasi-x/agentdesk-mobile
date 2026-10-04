import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

class HttpHubApi implements HubApi {
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
    } on SocketException {
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
    } on SocketException {
      return UndoResult.networkError;
    } on http.ClientException {
      return UndoResult.networkError;
    }
  }
}
