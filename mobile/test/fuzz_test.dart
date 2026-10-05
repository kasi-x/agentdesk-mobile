// I-909: adversarial payload fuzzing for the client-side wire parsing and
// the declarative component renderer.
//
// Determinism: every mutation stream is driven by `Random(42)`, so a failing
// case is reproducible from the printed index + mutation labels. Nothing here
// hits the network or the hub.
//
// Contract under test (FR-1.3, NFR-2.1):
//  - `TaskCard.fromJson` / `TriageActionReply.fromJson` either return a model
//    or fail with a *clean, catchable* typed error (FormatException for an
//    explicit throw, TypeError for the model's unchecked `as` casts on a
//    wrong-typed field). Anything else — or a hang — is a failure.
//  - Any returned card must render without crashing, and unknown component
//    types must render the fallback card, never blank/crash.

import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:agentdesk_mobile/models/task_card.dart';
import 'package:agentdesk_mobile/models/triage_action.dart';
import 'package:agentdesk_mobile/ui/widgets/component_renderer.dart';
import 'package:agentdesk_mobile/ui/widgets/task_card_view.dart';

/// Component names the catalog actually renders; everything else must take
/// the FR-1.3 fallback path.
const Set<String> _knownComponents = <String>{
  'Text',
  'DiffBox',
  'Chips',
  'TriageCard',
};

const List<String> _wildStrings = <String>[
  'approve',
  'drop',
  'explode',
  '',
  '🚀🚀🚀',
  '\u202Ertl-override\u202C',
  'עברית',
  'العربية',
  '👨‍👩‍👧‍👦',
  '\u0000\u0001',
  'https://example.com/x',
  'javascript:alert(1)',
];

const List<String> _junkKeys = <String>[
  'agent',
  'summary',
  'components',
  'actions',
  'confidence',
  'confidenceReasons',
  'severity',
  'surfaceId',
  'createdAt',
  'replyUrl',
  'expiresAt',
  'onExpire',
  'taskId',
  'nonce',
  'impact',
  'context',
  'type',
  'protocolVersion',
  'groupKey',
  'decisionKind',
  'editable',
  '__junk',
  '',
  '🤖',
];

const List<dynamic> _wrongTypes = <dynamic>[
  null,
  true,
  42,
  -1.5,
  '',
  'nope',
  <dynamic>[],
  <String, dynamic>{},
  <dynamic>['x'],
  <String, dynamic>{'nested': true},
];

Widget _wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

T _pick<T>(Random rnd, List<T> values) => values[rnd.nextInt(values.length)];

Map<String, dynamic> _clone(Map<String, dynamic> source) =>
    jsonDecode(jsonEncode(source)) as Map<String, dynamic>;

String _preview(Map<String, dynamic> body) {
  final encoded = jsonEncode(body);
  return encoded.length <= 200 ? encoded : '${encoded.substring(0, 200)}…';
}

/// A fully-populated, valid card payload (hub wire shape).
Map<String, dynamic> _validCard() => <String, dynamic>{
      'type': 'createTaskCard',
      'taskId': 'task_fuzz_1',
      'nonce': 'tok_fuzz_1',
      'protocolVersion': 1,
      'agent': <String, dynamic>{
        'name': 'Fuzz Agent',
        'avatarUrl': 'https://example.com/a.png',
      },
      'confidence': 0.8,
      'confidenceReasons': <String>['r1', 'r2'],
      'severity': 'warning',
      'summary': 'Fuzz summary 日本語',
      'surfaceId': 'surface_1',
      'createdAt': '2026-10-05T00:00:00.000Z',
      'replyUrl': 'https://example.com/reply',
      'components': <dynamic>[
        <String, dynamic>{
          'id': 'root',
          'component': 'TriageCard',
          'children': <String>['t', 'd', 'u'],
        },
        <String, dynamic>{
          'id': 't',
          'component': 'Text',
          'properties': <String, dynamic>{'text': 'hi'},
        },
        <String, dynamic>{
          'id': 'd',
          'component': 'DiffBox',
          'properties': <String, dynamic>{
            'before': '14:00',
            'after': '16:30',
            'highlight': 'warning',
          },
        },
        <String, dynamic>{
          'id': 'u',
          'component': 'HologramWidget',
          'properties': <String, dynamic>{'spin': true},
        },
      ],
      'actions': <String, dynamic>{
        'onSwipeRight': <String, dynamic>{
          'actionName': 'approve',
          'payload': <String, dynamic>{'decision': 'ACCEPT'},
        },
        'onSwipeLeft': <String, dynamic>{
          'actionName': 'reject',
          'payload': <String, dynamic>{'decision': 'DECLINE'},
        },
        'inspectForm': <dynamic>[
          <String, dynamic>{
            'id': 'tp',
            'component': 'TimePicker',
            'properties': <String, dynamic>{'label': 't'},
          },
        ],
        'rejectReasons': <dynamic>[
          <String, dynamic>{'id': 'r', 'label': 'reason'},
        ],
      },
      'impact': <String, dynamic>{
        'summary': 'does X',
        'reversible': false,
        'cost': <String, dynamic>{'amount': 10, 'currency': 'JPY'},
        'scope': 's',
      },
      'context': <String, dynamic>{
        'requester': <String, dynamic>{'name': 'req', 'onBehalfOf': 'boss'},
        'participants': <dynamic>[
          <String, dynamic>{'name': 'p1', 'status': 'busy'},
        ],
        'reasoning': 'because',
        'source': <String, dynamic>{
          'label': 'mail',
          'url': 'https://example.com/m',
        },
      },
      'expiresAt': '2026-10-05T01:00:00.000Z',
      'onExpire': 'drop',
      'groupKey': 'grp_1',
      'decisionKind': 'choose',
      'editable': <String, dynamic>{
        'componentId': 't',
        'kind': 'number',
        'min': 0,
        'max': 10,
        'step': 1,
      },
      'priority': 42,
      'revised': true,
    };

Map<String, dynamic> _validReply() => <String, dynamic>{
      'taskId': 'task_1',
      'nonce': 'tok_1',
      'actionName': 'approve',
      'timestamp': '2026-10-05T00:00:00.000Z',
      'source': 'swipe_gesture',
      'data': <String, dynamic>{'decision': 'ACCEPT'},
    };

// ---------------------------------------------------------------------------
// random values + mutation engine
// ---------------------------------------------------------------------------

/// A random JSON-ish value (never NaN/Infinity: the wire is JSON).
dynamic _randomValue(Random rnd, int depth) {
  if (depth <= 0 || rnd.nextDouble() < 0.35) {
    switch (rnd.nextInt(7)) {
      case 0:
        return null;
      case 1:
        return rnd.nextBool();
      case 2:
        return rnd.nextInt(2000000) - 1000000;
      case 3:
        return (rnd.nextDouble() - 0.5) * 2000;
      case 4:
        return '';
      case 5:
        return _pick(rnd, _wildStrings);
      default:
        return rnd.nextDouble() * 100;
    }
  }
  if (rnd.nextDouble() < 0.5) {
    final length = rnd.nextInt(5);
    return List<dynamic>.generate(length, (_) => _randomValue(rnd, depth - 1));
  }
  final obj = <String, dynamic>{};
  final length = rnd.nextInt(6);
  for (var i = 0; i < length; i++) {
    obj[_pick(rnd, _junkKeys)] = _randomValue(rnd, depth - 1);
  }
  return obj;
}

class _Mutation {
  const _Mutation(this.name, this.apply);

  final String name;
  final void Function(Random rnd, Map<String, dynamic> body) apply;
}

List<dynamic> _componentList(Map<String, dynamic> body) =>
    body['components'] is List
        ? (body['components'] as List)
        : <dynamic>[];

Map<String, dynamic> _actionsMap(Map<String, dynamic> body) =>
    body['actions'] is Map
        ? Map<String, dynamic>.from(body['actions'] as Map)
        : <String, dynamic>{};

final List<_Mutation> _mutations = <_Mutation>[
  _Mutation('drop-random-field', (rnd, body) {
    if (body.isEmpty) return;
    body.remove(_pick(rnd, body.keys.toList()));
  }),
  _Mutation('randomize-field', (rnd, body) {
    if (body.isEmpty) return;
    body[_pick(rnd, body.keys.toList())] = _randomValue(rnd, 3);
  }),
  _Mutation('null-random-field', (rnd, body) {
    if (body.isEmpty) return;
    body[_pick(rnd, body.keys.toList())] = null;
  }),
  _Mutation('add-unknown-field', (rnd, body) {
    body['__junk_${rnd.nextInt(1000)}'] = _randomValue(rnd, 2);
  }),
  _Mutation('summary-wrong-type', (rnd, body) {
    body['summary'] = _pick(rnd, _wrongTypes);
  }),
  _Mutation('agent-wrong-type', (rnd, body) {
    body['agent'] = _pick(rnd, _wrongTypes);
  }),
  _Mutation('agent-name-wrong-type', (rnd, body) {
    body['agent'] = <String, dynamic>{'name': _pick(rnd, _wrongTypes)};
  }),
  _Mutation('confidence-invalid', (rnd, body) {
    body['confidence'] = _pick(rnd, <dynamic>[
      -1,
      2,
      '0.5',
      null,
      <String, dynamic>{},
      <dynamic>[],
      true,
    ]);
  }),
  _Mutation('expiresAt-invalid', (rnd, body) {
    body['expiresAt'] = _pick(rnd, <dynamic>[
      'not-a-date',
      12345,
      null,
      '',
      <String, dynamic>{},
    ]);
  }),
  _Mutation('onExpire-invalid', (rnd, body) {
    body['onExpire'] = _pick(rnd, <dynamic>['explode', 'APPROVE', 5, null, true]);
  }),
  _Mutation('components-not-list', (rnd, body) {
    body['components'] = _pick(rnd, <dynamic>[
      'nope',
      <String, dynamic>{},
      5,
      null,
      true,
    ]);
  }),
  _Mutation('component-entry-malformed', (rnd, body) {
    final list = _componentList(body);
    list.add(_pick(rnd, <dynamic>[
      null,
      'x',
      5,
      <String, dynamic>{},
      <String, dynamic>{'id': 5},
      <String, dynamic>{'component': 5},
      <String, dynamic>{'id': 'no-type'},
    ]));
    body['components'] = list;
  }),
  _Mutation('actions-wrong-type', (rnd, body) {
    body['actions'] = _pick(rnd, <dynamic>[
      <dynamic>[],
      'approve',
      5,
      null,
      true,
    ]);
  }),
  _Mutation('swipe-binding-malformed', (rnd, body) {
    final actions = _actionsMap(body);
    actions['onSwipeRight'] = _pick(rnd, <dynamic>[
      'approve',
      <String, dynamic>{'label': 'no actionName'},
      <String, dynamic>{'actionName': 5},
      null,
      <dynamic>[],
    ]);
    body['actions'] = actions;
  }),
  _Mutation('inspectForm-malformed', (rnd, body) {
    final actions = _actionsMap(body);
    actions['inspectForm'] = _pick(rnd, <dynamic>[
      'nope',
      5,
      <String, dynamic>{},
      <dynamic>[null],
      <dynamic>[
        <String, dynamic>{'id': 1},
      ],
    ]);
    body['actions'] = actions;
  }),
  _Mutation('rejectReasons-malformed', (rnd, body) {
    final actions = _actionsMap(body);
    actions['rejectReasons'] = _pick(rnd, <dynamic>[
      'oops',
      <dynamic>[
        <String, dynamic>{'id': 1, 'label': 2},
      ],
      <dynamic>[
        <String, dynamic>{'id': 'ok', 'label': 'ok'},
        'junk',
      ],
      null,
    ]);
    body['actions'] = actions;
  }),
  _Mutation('replyUrl-invalid', (rnd, body) {
    body['replyUrl'] = _pick(rnd, <dynamic>[
      'javascript:alert(1)',
      'ftp://x',
      'example.com',
      5,
      null,
      <String, dynamic>{},
    ]);
  }),
  _Mutation('unknown-component-type', (rnd, body) {
    final list = _componentList(body);
    list.add(<String, dynamic>{
      'id': 'unknown_${rnd.nextInt(1000000)}',
      'component': _pick(rnd, <String>['HologramWidget', '🧩', '', 'TriageCard2']),
      'properties': <String, dynamic>{
        'weird': <dynamic>[
          1,
          <String, dynamic>{'deep': true},
        ],
      },
    });
    body['components'] = list;
  }),
  _Mutation('unicode-payload', (rnd, body) {
    body[_pick(rnd, <String>['summary', 'surfaceId', 'taskId'])] =
        _pick(rnd, _wildStrings);
    final agent = body['agent'];
    if (agent is Map) {
      agent['name'] = _pick(rnd, _wildStrings);
    } else {
      body['agent'] = <String, dynamic>{'name': _pick(rnd, _wildStrings)};
    }
  }),
  _Mutation('jumbo-string', (rnd, body) {
    if (body.isEmpty) return;
    final size = rnd.nextDouble() < 0.2 ? 50000 : 4000;
    body[_pick(rnd, body.keys.toList())] = 'x' * size;
  }),
  _Mutation('deep-nesting', (rnd, body) {
    dynamic nested = <String, dynamic>{'leaf': true};
    final depth = 40 + rnd.nextInt(12); // up to ~52 levels
    for (var i = 0; i < depth; i++) {
      nested = <String, dynamic>{
        'child': <dynamic>[nested],
      };
    }
    final list = _componentList(body);
    list.add(<String, dynamic>{
      'id': 'deep',
      'component': 'Text',
      'properties': <String, dynamic>{'nested': nested},
    });
    body['components'] = list;
  }),
  _Mutation('context-malformed', (rnd, body) {
    body['context'] = _pick(rnd, <dynamic>[
      'oops',
      5,
      <String, dynamic>{'participants': 'not-array'},
      <String, dynamic>{
        'participants': <dynamic>[
          null,
          5,
          <String, dynamic>{'name': 1},
        ],
      },
      <String, dynamic>{
        'requester': <String, dynamic>{'name': 5},
        'source': <String, dynamic>{'label': 5, 'url': 'javascript:1'},
      },
    ]);
  }),
  _Mutation('impact-malformed', (rnd, body) {
    body['impact'] = _pick(rnd, <dynamic>[
      'oops',
      5,
      <String, dynamic>{
        'cost': <String, dynamic>{'amount': 'x', 'currency': 1},
      },
      <String, dynamic>{'reversible': 'yes', 'summary': 5},
    ]);
  }),
  _Mutation('protocolVersion-invalid', (rnd, body) {
    body['protocolVersion'] = _pick(rnd, <dynamic>[0, -1, 1.5, '1', null, 2]);
  }),
  _Mutation('groupKey-invalid', (rnd, body) {
    body['groupKey'] = _pick(rnd, <dynamic>['', 5, null, <String, dynamic>{}]);
  }),
  _Mutation('decisionKind-invalid', (rnd, body) {
    body['decisionKind'] =
        _pick(rnd, <dynamic>['explode', 'APPROVE', 5, null, <String, dynamic>{}]);
  }),
  _Mutation('editable-invalid', (rnd, body) {
    body['editable'] = _pick(rnd, <dynamic>[
      'x',
      5,
      <String, dynamic>{},
      <String, dynamic>{'componentId': '', 'kind': 'number'},
      <String, dynamic>{'componentId': 'c', 'kind': 'slider'},
      <String, dynamic>{'componentId': 'c', 'kind': 'number', 'min': '0'},
    ]);
  }),
  _Mutation('priority-revised-wrong-type', (rnd, body) {
    body['priority'] = _pick(rnd, <dynamic>['high', true, null]);
    body['revised'] = _pick(rnd, <dynamic>['yes', 1, null]);
  }),
];

List<String> _applyMutations(Random rnd, Map<String, dynamic> body) {
  final applied = <String>[];
  final count = 1 + rnd.nextInt(3);
  for (var i = 0; i < count; i++) {
    final mutation = _pick(rnd, _mutations);
    mutation.apply(rnd, body);
    applied.add(mutation.name);
  }
  return applied;
}

// ---------------------------------------------------------------------------
// reply mutations
// ---------------------------------------------------------------------------

class _ReplyMutation {
  const _ReplyMutation(this.name, this.apply);

  final String name;
  final void Function(Random rnd, Map<String, dynamic> body) apply;
}

final List<_ReplyMutation> _replyMutations = <_ReplyMutation>[
  _ReplyMutation('drop-random-field', (rnd, body) {
    if (body.isEmpty) return;
    body.remove(_pick(rnd, body.keys.toList()));
  }),
  _ReplyMutation('randomize-field', (rnd, body) {
    if (body.isEmpty) return;
    body[_pick(rnd, body.keys.toList())] = _randomValue(rnd, 3);
  }),
  _ReplyMutation('wrong-type-field', (rnd, body) {
    if (body.isEmpty) return;
    body[_pick(rnd, body.keys.toList())] = _pick(rnd, _wrongTypes);
  }),
  _ReplyMutation('bad-timestamp', (rnd, body) {
    body['timestamp'] = _pick(rnd, <dynamic>['garbage', 5, null, '', <dynamic>[]]);
  }),
  _ReplyMutation('unicode-field', (rnd, body) {
    body[_pick(rnd, body.keys.toList())] = _pick(rnd, _wildStrings);
  }),
  _ReplyMutation('jumbo-field', (rnd, body) {
    if (body.isEmpty) return;
    body[_pick(rnd, body.keys.toList())] = 'x' * 4000;
  }),
];

List<String> _applyReplyMutations(Random rnd, Map<String, dynamic> body) {
  final applied = <String>[];
  final count = 1 + rnd.nextInt(3);
  for (var i = 0; i < count; i++) {
    final mutation = _pick(rnd, _replyMutations);
    mutation.apply(rnd, body);
    applied.add(mutation.name);
  }
  return applied;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

void main() {
  test('TaskCard.fromJson tolerates non-Map roots', () {
    for (final root in <dynamic>[
      null,
      42,
      'x',
      true,
      <dynamic>[],
      <dynamic>[1, 2],
    ]) {
      final card = TaskCard.fromJson(root);
      expect(card.components, isEmpty, reason: 'root=$root');
      expect(card.summary, isNotEmpty, reason: 'root=$root');
    }
  });

  test('TaskCard.fromJson tolerates unknown keys and nulled fields', () {
    final withJunk = <String, dynamic>{
      ..._validCard(),
      '__junk': <dynamic>[
        1,
        <String, dynamic>{'a': true},
      ],
      'extra_field': 42,
    };
    expect(TaskCard.fromJson(withJunk).summary, isNotEmpty);

    final nulled = <String, dynamic>{..._validCard()};
    for (final key in <String>[
      'surfaceId',
      'replyUrl',
      'expiresAt',
      'onExpire',
      'impact',
      'context',
      'groupKey',
      'editable',
      'priority',
      'agent',
      'confidence',
      'severity',
      'summary',
      'taskId',
      'nonce',
      'createdAt',
    ]) {
      nulled[key] = null;
    }
    final card = TaskCard.fromJson(nulled);
    expect(card.taskId, isNotEmpty);
    expect(card.summary, isNotEmpty);
    expect(card.components, isNotEmpty);
  });

  test('TaskCard.fromJson parses 1 MiB / RTL / emoji payloads', () {
    final jumbo = 'x' * (1024 * 1024);
    for (final entry in <MapEntry<String, dynamic>>[
      MapEntry('summary', <String, dynamic>{
        ..._validCard(),
        'summary': jumbo,
      }),
      MapEntry('agent', <String, dynamic>{
        ..._validCard(),
        'agent': <String, dynamic>{'name': jumbo},
      }),
      MapEntry('summary-unicode', <String, dynamic>{
        ..._validCard(),
        'summary': 'עברית · العربية · 🇯🇵 · \u202Ereversed\u202C',
      }),
    ]) {
      final card = TaskCard.fromJson(entry.value);
      expect(card, isA<TaskCard>(), reason: entry.key);
    }
  });

  testWidgets(
    'TaskCard.fromJson + render survives 500 seeded mutations (FR-1.3)',
    (tester) async {
      final rnd = Random(42);
      final unknownComponents = <CardComponent>[];
      var rendered = 0;

      for (var i = 0; i < 500; i++) {
        final body = _clone(_validCard());
        final applied = _applyMutations(rnd, body);
        final label =
            'seed=42 i=$i [${applied.join(" + ")}] ${_preview(body)}';

        TaskCard? card;
        Object? error;
        try {
          card = TaskCard.fromJson(body);
        } catch (e) {
          error = e;
        }

        if (error != null) {
          expect(
            error,
            anyOf(isA<FormatException>(), isA<TypeError>()),
            reason: '$label :: fromJson threw ${error.runtimeType}: $error',
          );
          continue;
        }

        expect(card, isNotNull, reason: label);

        // Widget tests cannot fetch network images; drop the avatar so the
        // render path is exercised without an HTTP dependency. Removing a
        // field cannot make a previously-successful parse fail.
        final agent = body['agent'];
        if (agent is Map) {
          body['agent'] = Map<dynamic, dynamic>.from(agent)
            ..remove('avatarUrl');
        }
        final renderCard = TaskCard.fromJson(body);

        await tester.pumpWidget(_wrap(TaskCardView(
          task: renderCard,
          timeAgo: (_) => 'now',
          onQuickAction: (_) {},
          onInspect: () {},
        )));
        expect(tester.takeException(), isNull, reason: label);
        rendered++;

        for (final component in renderCard.components) {
          if (!_knownComponents.contains(component.component)) {
            unknownComponents.add(component);
          }
        }
      }

      expect(rendered, greaterThan(50), reason: 'expected many mutations to parse');

      // FR-1.3: unknown component types render the fallback card.
      var checked = 0;
      for (final component in unknownComponents) {
        if (checked >= 40) break;
        checked++;
        await tester.pumpWidget(
          _wrap(ComponentRenderer(component: component)),
        );
        expect(tester.takeException(), isNull,
            reason: 'unknown component "${component.component}" crashed');
        expect(
          find.text('Unsupported component'),
          findsOneWidget,
          reason: 'unknown component "${component.component}" missing fallback',
        );
      }
      expect(checked, greaterThan(0), reason: 'no unknown component was produced');

      // Dispose the final tree so implicit animations cannot outlive the test.
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test('TriageActionReply.fromJson rejects non-Map roots with FormatException',
      () {
    for (final root in <dynamic>[null, 42, 'x', true, <dynamic>[]]) {
      expect(
        () => TriageActionReply.fromJson(root),
        throwsA(isA<FormatException>()),
        reason: 'root=$root',
      );
    }
  });

  test('TriageActionReply.fromJson survives 400 seeded mutations', () {
    final rnd = Random(42);
    for (var i = 0; i < 400; i++) {
      final body = _clone(_validReply());
      final applied = _applyReplyMutations(rnd, body);
      final label =
          'seed=42 i=$i [${applied.join(" + ")}] ${_preview(body)}';

      TriageActionReply? reply;
      Object? error;
      try {
        reply = TriageActionReply.fromJson(body);
      } catch (e) {
        error = e;
      }

      if (error != null) {
        expect(
          error,
          anyOf(isA<FormatException>(), isA<TypeError>()),
          reason: '$label :: fromJson threw ${error.runtimeType}: $error',
        );
        continue;
      }

      expect(reply, isNotNull, reason: label);
      expect(reply!.taskId, isNotEmpty, reason: label);
      expect(reply.nonce, isNotEmpty, reason: label);
      expect(reply.actionName, isNotEmpty, reason: label);
      expect(reply.source, isNotEmpty, reason: label);
    }
  });
}
