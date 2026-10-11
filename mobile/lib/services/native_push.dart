import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// iOS APNs registration over the `dev.agentdesk/push` MethodChannel
/// (plain UNUserNotificationCenter — no Firebase, so Android builds never
/// need google-services.json).
///
/// Flow: [register] asks iOS for permission and a device token; the
/// native side returns the hex token, which the caller posts to the hub
/// via `HubApi.registerNativePush`. Everything no-ops off iOS.
///
/// Deliberately imports no `dart:io` (web-safe): the platform guard uses
/// `kIsWeb` + `defaultTargetPlatform`.
class NativePush {
  static const MethodChannel _channel = MethodChannel('dev.agentdesk/push');

  /// Cached hex device token from the last successful registration.
  String? _token;

  String? get deviceToken => _token;

  /// Request notification permission + APNs token. Returns the hex token,
  /// or null on non-iOS platforms, denied permission, or any channel
  /// error. Never throws.
  Future<String?> register() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return null;
    try {
      final token = await _channel
          .invokeMethod<String>('register')
          .timeout(const Duration(seconds: 15));
      if (token != null && token.isNotEmpty) _token = token;
      return token;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    } on TimeoutException {
      return null;
    }
  }

  /// Best-effort unregister (stops iOS delivery for this install).
  /// Never throws.
  Future<void> unregister() async {
    _token = null;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      await _channel
          .invokeMethod<void>('unregister')
          .timeout(const Duration(seconds: 10));
    } on PlatformException {
      // Best-effort: the hub row can be deleted explicitly instead.
    } on MissingPluginException {
      // Old install without the native channel — nothing to do.
    } on TimeoutException {
      // Best-effort.
    }
  }
}
