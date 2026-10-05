// Tolerant parsing of the wire protocol (docs/protocol.md).
//
// Unknown component types are preserved and rendered as fallback cards
// (FR-1.3); malformed payloads must never crash the app. This file is
// the client mirror of `backend/src/protocol.ts` — update both (and
// docs/protocol.md) in the same commit.

class AgentInfo {
  final String name;
  final String? avatarUrl;

  const AgentInfo({required this.name, this.avatarUrl});

  factory AgentInfo.fromJson(dynamic raw) {
    if (raw is! Map) return const AgentInfo(name: 'Unknown agent');
    return AgentInfo(
      name: (raw['name'] as String?) ?? 'Unknown agent',
      avatarUrl: raw['avatarUrl'] as String?,
    );
  }
}

class CardComponent {
  static int _anonCounter = 0;

  final String id;
  final String component;
  final Map<String, dynamic> properties;
  final List<String> children;

  const CardComponent({
    required this.id,
    required this.component,
    this.properties = const <String, dynamic>{},
    this.children = const <String>[],
  });

  factory CardComponent.fromJson(dynamic raw) {
    final anon = 'anon_${_anonCounter++}';
    if (raw is! Map) {
      return CardComponent(id: anon, component: 'Unknown', properties: <String, dynamic>{'text': '$raw'});
    }
    return CardComponent(
      id: (raw['id'] as String?) ?? anon,
      component: (raw['component'] as String?) ?? 'Unknown',
      properties: raw['properties'] is Map
          ? Map<String, dynamic>.from(raw['properties'] as Map)
          : const <String, dynamic>{},
      children: raw['children'] is List
          ? (raw['children'] as List).whereType<String>().toList()
          : const <String>[],
    );
  }
}

class ActionBinding {
  final String actionName;
  /// Action-specific verb shown while swiping (I-130); null falls back
  /// to APPROVE / REJECT.
  final String? label;
  final Map<String, dynamic> payload;

  const ActionBinding({
    required this.actionName,
    this.label,
    this.payload = const <String, dynamic>{},
  });

  factory ActionBinding.fromJson(dynamic raw) {
    if (raw is! Map) return const ActionBinding(actionName: 'unknown');
    return ActionBinding(
      actionName: (raw['actionName'] as String?) ?? 'unknown',
      label: (raw['label'] as String?)?.isNotEmpty == true
          ? raw['label'] as String
          : null,
      payload: raw['payload'] is Map
          ? Map<String, dynamic>.from(raw['payload'] as Map)
          : const <String, dynamic>{},
    );
  }
}

/// Agent-supplied candidate for "why was this rejected" (I-118).
class RejectReason {
  final String id;
  final String label;

  const RejectReason({required this.id, required this.label});

  factory RejectReason.fromJson(dynamic raw) {
    if (raw is! Map) {
      return const RejectReason(id: 'unknown', label: '?');
    }
    return RejectReason(
      id: (raw['id'] as String?) ?? 'unknown',
      label: (raw['label'] as String?)?.isNotEmpty == true
          ? raw['label'] as String
          : '?',
    );
  }
}

/// What accepting this card does (I-202). All fields optional.
class CardImpact {
  final String? summary;
  /// null = unknown; false renders a 「取り消し不可」 badge.
  final bool? reversible;
  final double? costAmount;
  final String? costCurrency;
  final String? scope;

  const CardImpact({
    this.summary,
    this.reversible,
    this.costAmount,
    this.costCurrency,
    this.scope,
  });

  factory CardImpact.fromJson(dynamic raw) {
    if (raw is! Map) return const CardImpact();
    final cost = raw['cost'];
    return CardImpact(
      summary: (raw['summary'] as String?)?.isNotEmpty == true
          ? raw['summary'] as String
          : null,
      reversible: raw['reversible'] is bool ? raw['reversible'] as bool : null,
      costAmount:
          cost is Map ? (cost['amount'] as num?)?.toDouble() : null,
      costCurrency:
          cost is Map ? (cost['currency'] as String?) : null,
      scope: (raw['scope'] as String?)?.isNotEmpty == true
          ? raw['scope'] as String
          : null,
    );
  }
}

/// Structured "back of the card" context (P1/P3): 誰が / 誰と / なぜ /
/// どこから。Rendered in the expandable details panel; all optional.
class ContextPerson {
  final String name;
  final String? status;

  const ContextPerson({required this.name, this.status});

  factory ContextPerson.fromJson(dynamic raw) {
    if (raw is! Map) return const ContextPerson(name: '?');
    return ContextPerson(
      name: (raw['name'] as String?) ?? '?',
      status: raw['status'] is String ? raw['status'] as String : null,
    );
  }
}

class TaskContext {
  final String? requesterName;
  final String? requesterOnBehalfOf;
  final List<ContextPerson> participants;
  final String? reasoning;
  final String? sourceLabel;
  final String? sourceUrl;

  const TaskContext({
    this.requesterName,
    this.requesterOnBehalfOf,
    this.participants = const <ContextPerson>[],
    this.reasoning,
    this.sourceLabel,
    this.sourceUrl,
  });

  factory TaskContext.fromJson(dynamic raw) {
    if (raw is! Map) return const TaskContext();
    final requester =
        raw['requester'] is Map ? raw['requester'] as Map : null;
    final source = raw['source'] is Map ? raw['source'] as Map : null;
    String? field(Map? m, String key) {
      if (m == null) return null;
      final v = m[key];
      return v is String && v.isNotEmpty ? v : null;
    }

    String? safeUrl(String? url) =>
        url != null && RegExp(r'^https?://').hasMatch(url) ? url : null;
    final requesterName = field(requester, 'name');
    final requesterOnBehalfOf = field(requester, 'onBehalfOf');
    final sourceLabel = field(source, 'label');
    final sourceUrl = safeUrl(field(source, 'url'));
    final reasoning = field(raw, 'reasoning');
    final participants = raw['participants'] is List
        ? (raw['participants'] as List)
            .map(ContextPerson.fromJson)
            .where((p) => p.name != '?')
            .toList()
        : const <ContextPerson>[];
    return TaskContext(
      requesterName: requesterName,
      requesterOnBehalfOf: requesterOnBehalfOf,
      participants: participants,
      reasoning: reasoning,
      sourceLabel: sourceLabel,
      sourceUrl: sourceUrl,
    );
  }
}

class TaskCard {
  final String taskId;
  final String nonce;
  final AgentInfo agent;
  final double confidence;
  final List<String> confidenceReasons;
  final String severity;
  final String summary;
  final String? surfaceId;
  final DateTime createdAt;
  final String? replyUrl;
  final List<CardComponent> components;
  final ActionBinding? onSwipeRight;
  final ActionBinding? onSwipeLeft;
  final List<CardComponent> inspectForm;
  final CardImpact? impact;
  /// Agent-supplied reject reasons (I-118). On left swipe the client
  /// offers them as one-tap chips; the chosen id is sent as
  /// `data.reason`.
  final List<RejectReason> rejectReasons;
  /// Deadline after which the hub runs the default behavior (I-203);
  /// null = no expiry. Clients only render a countdown from it.
  final DateTime? expiresAt;
  /// approve | reject | escalate | drop — displayed next to the
  /// countdown; the hub decides at the deadline, never the client.
  final String? onExpire;
  /// Structured back-of-card context (裏面) for the details panel.
  final TaskContext? context;

  const TaskCard({
    required this.taskId,
    required this.nonce,
    required this.agent,
    required this.confidence,
    required this.confidenceReasons,
    required this.severity,
    required this.summary,
    required this.surfaceId,
    required this.createdAt,
    required this.replyUrl,
    required this.components,
    required this.onSwipeRight,
    required this.onSwipeLeft,
    required this.inspectForm,
    required this.impact,
    this.rejectReasons = const <RejectReason>[],
    this.expiresAt,
    this.onExpire,
    this.context,
  });

  factory TaskCard.fromJson(dynamic raw) {
    if (raw is! Map) {
      return TaskCard.fromJson(<String, dynamic>{});
    }
    final createdAtRaw = raw['createdAt'];
    final createdAt = DateTime.tryParse(createdAtRaw is String ? createdAtRaw : '') ?? DateTime.now();
    final actions = raw['actions'] is Map ? Map<String, dynamic>.from(raw['actions'] as Map) : const <String, dynamic>{};
    return TaskCard(
      taskId: (raw['taskId'] as String?) ??
          'task_unknown_${DateTime.now().microsecondsSinceEpoch}',
      nonce: (raw['nonce'] as String?) ?? '',
      agent: AgentInfo.fromJson(raw['agent']),
      confidence: (raw['confidence'] as num?)?.toDouble() ?? 0.5,
      confidenceReasons: raw['confidenceReasons'] is List
          ? (raw['confidenceReasons'] as List).whereType<String>().toList()
          : const <String>[],
      severity: (raw['severity'] as String?) ?? 'info',
      summary: (raw['summary'] as String?) ?? '(no summary)',
      surfaceId: raw['surfaceId'] as String?,
      createdAt: createdAt,
      replyUrl: raw['replyUrl'] as String?,
      components: raw['components'] is List
          ? (raw['components'] as List).map(CardComponent.fromJson).toList()
          : const <CardComponent>[],
      onSwipeRight: actions['onSwipeRight'] == null
          ? null
          : ActionBinding.fromJson(actions['onSwipeRight']),
      onSwipeLeft: actions['onSwipeLeft'] == null
          ? null
          : ActionBinding.fromJson(actions['onSwipeLeft']),
      inspectForm: actions['inspectForm'] is List
          ? (actions['inspectForm'] as List).map(CardComponent.fromJson).toList()
          : const <CardComponent>[],
      impact: raw['impact'] is Map
          ? CardImpact.fromJson(raw['impact'])
          : null,
      rejectReasons: actions['rejectReasons'] is List
          ? (actions['rejectReasons'] as List)
              .map(RejectReason.fromJson)
              .toList()
          : const <RejectReason>[],
      expiresAt: DateTime.tryParse(raw['expiresAt'] is String ? raw['expiresAt'] as String : ''),
      onExpire: raw['onExpire'] is String ? raw['onExpire'] as String : null,
      context: raw['context'] is Map ? TaskContext.fromJson(raw['context']) : null,
    );
  }

  /// Visible body components in render order: the root `TriageCard`
  /// children if declared, otherwise array order. Components missing
  /// from the root's children are appended (schema breakage tolerant).
  List<CardComponent> get bodyComponents {
    final roots = components.where((c) => c.component == 'TriageCard').toList();
    if (roots.isEmpty) return components;
    final byId = <String, CardComponent>{
      for (final c in components) c.id: c,
    };
    final ordered = <CardComponent>[];
    for (final id in roots.first.children) {
      final c = byId[id];
      if (c != null && c.component != 'TriageCard') ordered.add(c);
    }
    for (final c in components) {
      if (c.component != 'TriageCard' && !ordered.contains(c)) ordered.add(c);
    }
    return ordered;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': 'createTaskCard',
        'taskId': taskId,
        'nonce': nonce,
        'agent': <String, dynamic>{
          'name': agent.name,
          if (agent.avatarUrl != null) 'avatarUrl': agent.avatarUrl,
        },
        'confidence': confidence,
        'confidenceReasons': confidenceReasons,
        'severity': severity,
        'summary': summary,
        if (surfaceId != null) 'surfaceId': surfaceId,
        'createdAt': createdAt.toUtc().toIso8601String(),
        if (replyUrl != null) 'replyUrl': replyUrl,
        'components': components
            .map((c) => <String, dynamic>{
                  'id': c.id,
                  'component': c.component,
                  'properties': c.properties,
                  'children': c.children,
                })
            .toList(),
        'actions': <String, dynamic>{
          if (onSwipeRight != null)
            'onSwipeRight': <String, dynamic>{
              'actionName': onSwipeRight!.actionName,
              if (onSwipeRight!.label != null) 'label': onSwipeRight!.label,
              'payload': onSwipeRight!.payload,
            },
          if (onSwipeLeft != null)
            'onSwipeLeft': <String, dynamic>{
              'actionName': onSwipeLeft!.actionName,
              if (onSwipeLeft!.label != null) 'label': onSwipeLeft!.label,
              'payload': onSwipeLeft!.payload,
            },
          'inspectForm': inspectForm
              .map((c) => <String, dynamic>{
                    'id': c.id,
                    'component': c.component,
                    'properties': c.properties,
                  })
              .toList(),
        },
        if (impact != null)
          'impact': <String, dynamic>{
            if (impact!.summary != null) 'summary': impact!.summary,
            if (impact!.reversible != null) 'reversible': impact!.reversible,
            if (impact!.costAmount != null && impact!.costCurrency != null)
              'cost': <String, dynamic>{
                'amount': impact!.costAmount,
                'currency': impact!.costCurrency,
              },
            if (impact!.scope != null) 'scope': impact!.scope,
          },
        if (expiresAt != null) 'expiresAt': expiresAt!.toUtc().toIso8601String(),
        if (onExpire != null) 'onExpire': onExpire,
        if (context != null)
          'context': <String, dynamic>{
            if (context!.requesterName != null)
              'requester': <String, dynamic>{
                'name': context!.requesterName,
                if (context!.requesterOnBehalfOf != null)
                  'onBehalfOf': context!.requesterOnBehalfOf,
              },
            'participants': context!.participants
                .map((p) => <String, dynamic>{
                      'name': p.name,
                      if (p.status != null) 'status': p.status,
                    })
                .toList(),
            if (context!.reasoning != null) 'reasoning': context!.reasoning,
            if (context!.sourceLabel != null)
              'source': <String, dynamic>{
                'label': context!.sourceLabel,
                if (context!.sourceUrl != null) 'url': context!.sourceUrl,
              },
          },
      };
}

/// How "heavy" a card feels to triage (I-102). Derived from severity and
/// impact — the same rule is mirrored in web/app.js.
enum RiskLevel {
  /// Standard swipe distances.
  normal,

  /// Elevated: longer swipe threshold (cost, critical, or irreversible).
  high,

  /// Locked: critical AND irreversible. Right-swipe is disabled; approval
  /// requires the hold-to-confirm ring (I-103).
  locked,
}

RiskLevel riskLevel(TaskCard task) {
  final irreversible = task.impact?.reversible == false;
  if (task.severity == 'critical' && irreversible) {
    return RiskLevel.locked;
  }
  if (task.severity == 'critical' ||
      irreversible ||
      (task.impact?.costAmount ?? 0) > 0) {
    return RiskLevel.high;
  }
  return RiskLevel.normal;
}
