/// A triage decision sent to the hub (docs/protocol.md §7.2).
class TriageActionReply {
  final String taskId;
  final String nonce;
  final String actionName;
  final DateTime timestamp;
  final String source;
  final Map<String, dynamic> data;

  /// I-1003 swipe-to-learn: when true the hub learns a `"learned"` rule
  /// from this card on commit (`POST /api/v1/actions {learnRule: true}`).
  /// I-1005 widened the wire shape: `true` OR a rule spec
  /// `{match?, action?, lease?}` the hub merges over the card-derived
  /// match. Advisory only — old hubs ignore the unknown key;
  /// snooze/delegate and partial approvals ignore it server-side too.
  final Object? learnRule;

  TriageActionReply({
    required this.taskId,
    required this.nonce,
    required this.actionName,
    required this.timestamp,
    required this.source,
    this.data = const <String, dynamic>{},
    this.learnRule = false,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'taskId': taskId,
        'nonce': nonce,
        'actionName': actionName,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'source': source,
        if (data.isNotEmpty) 'data': data,
        if (learnRule != null && learnRule != false)
          'learnRule': learnRule,
      };

  factory TriageActionReply.fromJson(dynamic raw) {
    if (raw is! Map) throw const FormatException('reply must be an object');
    String req(String key) {
      final v = raw[key];
      if (v is! String || v.isEmpty) {
        throw FormatException('reply.$key must be a non-empty string');
      }
      return v;
    }

    final source = raw['source'];
    return TriageActionReply(
      taskId: req('taskId'),
      nonce: req('nonce'),
      actionName: req('actionName'),
      timestamp: DateTime.parse(req('timestamp')),
      source: source is String && source.isNotEmpty
          ? source
          : ActionSource.swipeGesture,
      data: raw['data'] is Map
          ? Map<String, dynamic>.from(raw['data'] as Map)
          : const <String, dynamic>{},
      learnRule: raw['learnRule'] is Map
          ? Map<String, dynamic>.from(raw['learnRule'] as Map)
          : raw['learnRule'] == true,
    );
  }
}

/// Where a decision came from (docs/protocol.md).
abstract final class ActionSource {
  static const String swipeGesture = 'swipe_gesture';
  static const String quickChip = 'quick_chip';
  static const String inspectForm = 'inspect_form';
  static const String lockScreen = 'lock_screen';
  static const String webUi = 'web_ui';
  static const String snoozeLocal = 'snooze_local';
  /// Hold-to-confirm ring on locked cards (I-103).
  static const String holdConfirm = 'hold_confirm';
  /// Server-side snooze (`action: "snooze"`, synced across devices).
  static const String snooze = 'snooze';
  /// Second stage of a two-stage swipe (I-101).
  static const String twoStageSwipe = 'two_stage_swipe';
  /// Bundled approval via `POST /api/v1/actions/bulk` (I-201).
  static const String bulk = 'bulk';
  /// Delegation to a colleague (`action: "delegate"`, I-501).
  static const String delegate = 'delegate';
  /// Hub auto-approval via a rule (`source: "auto_rule"`, I-304/I-807).
  static const String autoRule = 'auto_rule';
  /// Operator fleet pause (I-403).
  static const String pause = 'pause';
}
