import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Outcome of a `POST /api/v1/pair/redeem` attempt (I-808).
class PairingOutcome {
  /// Hub the code was redeemed against, when derivable from the paste.
  final String? hubUrl;
  final String? token;
  final String? user;
  final String? error;

  const PairingOutcome({this.hubUrl, this.token, this.user, this.error});

  bool get ok => token != null;
}

/// Redeems a pasted pairing URL or 6-char code (I-808). The input may be
/// a full URL (`https://hub.example/pair?code=ABC123`), a bare code, or
/// a URL plus code. When the paste carries no hub, [fallbackHubUrl] (the
/// configured one) is used. The redeem endpoint is unauthenticated.
Future<PairingOutcome> redeemPairing({
  required String input,
  required String fallbackHubUrl,
  http.Client? client,
}) async {
  final trimmed = input.trim();
  if (trimmed.isEmpty) {
    return const PairingOutcome(error: 'コードを入力してください');
  }

  String? hubUrl;
  String? code;

  final uri = Uri.tryParse(trimmed);
  if (uri != null && uri.hasScheme && uri.host.isNotEmpty) {
    hubUrl = '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
    code = uri.queryParameters['code'] ??
        (uri.pathSegments.isNotEmpty ? uri.pathSegments.last : null);
  } else {
    code = trimmed;
  }
  code = code?.trim().toUpperCase();
  if (code == null || code.isEmpty) {
    return const PairingOutcome(error: 'コードを読み取れませんでした');
  }
  hubUrl ??= fallbackHubUrl;

  final endpoint = '${hubUrl.replaceAll(RegExp(r'/+$'), '')}/api/v1/pair/redeem';
  final http.Client httpClient = client ?? http.Client();
  try {
    final res = await httpClient
        .post(
          Uri.parse(endpoint),
          headers: const <String, String>{'Content-Type': 'application/json'},
          body: jsonEncode(<String, String>{'code': code}),
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      return PairingOutcome(
        hubUrl: hubUrl,
        error: res.statusCode == 404
            ? 'コードが無効か期限切れです'
            : 'ペアリングに失敗しました (${res.statusCode})',
      );
    }
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (body is! Map || body['token'] is! String) {
      return PairingOutcome(hubUrl: hubUrl, error: '応答を解釈できませんでした');
    }
    return PairingOutcome(
      hubUrl: hubUrl,
      token: body['token'] as String,
      user: body['user'] as String?,
    );
  } on TimeoutException {
    return PairingOutcome(hubUrl: hubUrl, error: '接続がタイムアウトしました');
  } on SocketException {
    return PairingOutcome(hubUrl: hubUrl, error: 'ハブに接続できません');
  } on http.ClientException {
    return PairingOutcome(hubUrl: hubUrl, error: 'ハブに接続できません');
  } on FormatException {
    return PairingOutcome(hubUrl: hubUrl, error: '応答を解釈できませんでした');
  } finally {
    if (client == null) httpClient.close();
  }
}
