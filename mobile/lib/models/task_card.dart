/// Tolerant parsing of the wire protocol (docs/protocol.md).
///
/// Unknown component types are preserved and rendered as fallback cards
/// (FR-1.3); malformed payloads must never crash the app. This file is
/// the client mirror of `backend/src/protocol.ts` — update both (and
/// docs/protocol.md) in the same commit.

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
  final Map<String, dynamic> payload;

  const ActionBinding({
    required this.actionName,
    this.payload = const <String, dynamic>{},
  });

  factory ActionBinding.fromJson(dynamic raw) {
    if (raw is! Map) return const ActionBinding(actionName: 'unknown');
    return ActionBinding(
      actionName: (raw['actionName'] as String?) ?? 'unknown',
      payload: raw['payload'] is Map
          ? Map<String, dynamic>.from(raw['payload'] as Map)
          : const <String, dynamic>{},
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
              'payload': onSwipeRight!.payload,
            },
          if (onSwipeLeft != null)
            'onSwipeLeft': <String, dynamic>{
              'actionName': onSwipeLeft!.actionName,
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
      };
}
