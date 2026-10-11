import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// iOS Live Activities / Dynamic Island bridge (Phase 3).
///
/// Mirrors the waiting stack ("N agents waiting — top: <title>") to the
/// Lock Screen / Dynamic Island. Dart side of the
/// `dev.agentdesk/live_activities` MethodChannel; the Swift owner is
/// `LiveActivityManager` (mobile/ios/Runner/) and the UI is the
/// `LiveActivityWidget` extension target.
///
/// Silently no-ops off iOS (and on web), so every other platform — and
/// `flutter test` — is unaffected. MethodChannel only, no new
/// dependencies. Callers should invoke [update] whenever the waiting
/// list changes and [end] when it empties; repeat states are deduped
/// here so unchanged snapshots never reach the platform channel.
class LiveActivitiesService {
  /// Must match `LiveActivityManager.channelName` (Swift).
  static const String channelName = 'dev.agentdesk/live_activities';

  static const MethodChannel channel = MethodChannel(channelName);

  int _lastCount = -1;
  String? _lastTitle;
  String? _lastAgent;
  bool _active = false;

  /// Pushes the current waiting state. Cheap: skips the platform call
  /// when nothing changed since the last call.
  Future<void> update({
    required int pendingCount,
    required String? topTitle,
    required String? topAgent,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    if (_active &&
        _lastCount == pendingCount &&
        _lastTitle == topTitle &&
        _lastAgent == topAgent) {
      return;
    }
    _lastCount = pendingCount;
    _lastTitle = topTitle;
    _lastAgent = topAgent;
    _active = true;
    try {
      await channel.invokeMethod<void>('update', <String, Object?>{
        'pendingCount': pendingCount,
        'topTitle': topTitle,
        'topAgent': topAgent,
      });
    } catch (_) {
      // No Swift host (tests, simulator builds without the extension).
      // Triage must never break because of this mirror.
    }
  }

  /// Ends the activity. Cheap: no-ops unless an activity was started.
  Future<void> end() async {
    if (!_active) return;
    _active = false;
    _lastCount = -1;
    _lastTitle = null;
    _lastAgent = null;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      await channel.invokeMethod<void>('end');
    } catch (_) {
      // Same as above: never break triage for the mirror.
    }
  }
}
