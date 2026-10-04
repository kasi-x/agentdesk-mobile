import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/task_card.dart';
import '../models/triage_action.dart';

enum ActionSendResult { sent, conflict, rejected, networkError }

abstract class HubApi {
  Future<List<TaskCard>> fetchPendingTasks();
  Future<ActionSendResult> sendAction(TriageActionReply reply);
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
}
