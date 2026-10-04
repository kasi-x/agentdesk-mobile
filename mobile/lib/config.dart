import 'package:shared_preferences/shared_preferences.dart';

/// Hub connection settings, persisted on device (NFR-2.3: the client
/// carries its own bearer token, never embedded in payloads).
class HubConfig {
  final String hubUrl;
  final String clientToken;

  const HubConfig({required this.hubUrl, required this.clientToken});

  static const HubConfig defaults = HubConfig(
    hubUrl: 'http://127.0.0.1:8787',
    clientToken: 'dev-client-token',
  );

  static Future<HubConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    return HubConfig(
      hubUrl: prefs.getString('hubUrl') ?? defaults.hubUrl,
      clientToken: prefs.getString('clientToken') ?? defaults.clientToken,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('hubUrl', hubUrl);
    await prefs.setString('clientToken', clientToken);
  }

  String get _base =>
      hubUrl.endsWith('/') ? hubUrl.substring(0, hubUrl.length - 1) : hubUrl;

  String get apiBase => '$_base/api/v1';

  String get streamUrl => '$apiBase/stream';
}
