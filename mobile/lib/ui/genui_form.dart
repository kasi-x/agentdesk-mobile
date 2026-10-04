import 'package:a2ui_core/a2ui_core.dart' as core;
import 'package:flutter/foundation.dart';
import 'package:genui/genui.dart';

import '../models/task_card.dart';

/// Renders inspect-form components (docs/protocol.md) through the genui
/// A2UI engine instead of the hand-rolled catalog in `inspect_sheet.dart`.
///
/// The engine is fully local: a [`SurfaceController`] with the fixed
/// basic catalog (NFR-2.1 — catalogs are compiled code, never built from
/// payloads). Each form component gets its own surface whose root component
/// is the translated widget, so a failure in one component falls back
/// individually and can never blank the rest of the sheet (FR-1.3).
///
/// Values live in the surface data model under `/form/<componentId>` and
/// are seeded with the protocol defaults before the components are sent.
/// `collectValues` reads them back and converts genui representations
/// (ISO-8601 date/time strings, list-valued pickers) to the protocol
/// wire values (HH:mm, yyyy-MM-dd, scalar).
class GenUiFormAdapter {
  GenUiFormAdapter();

  final SurfaceController _controller = SurfaceController(
    catalogs: <Catalog>[BasicCatalogItems.asCatalog()],
  );

  // Canonical id of BasicCatalogItems.asCatalog() — never hardcoded from
  // payloads (NFR-2.1).
  late final String _catalogId = basicCatalogId;

  final List<CardComponent> _form = <CardComponent>[];
  final Map<String, String> _surfaceIds = <String, String>{};
  final Set<String> _failedIds = <String>{};
  bool _disposed = false;

  /// Component ids whose genui rendering failed (translate, seed, or
  /// surface update). Callers must render those with the hand-rolled
  /// fallback instead of a genui [`Surface`].
  Set<String> get failedIds => Set<String>.unmodifiable(_failedIds);

  /// Whether [c] can be rendered through genui with sane properties.
  /// Malformed payloads (bad defaults, min >= max, empty options) are
  /// reported as unsupported so the caller keeps the hand-rolled fallback.
  bool handles(CardComponent c) {
    if (_disposed) return false;
    try {
      return switch (c.component) {
        'TimePicker' => _saneTime(c),
        'DatePicker' => _saneDate(c),
        'Slider' => _saneSlider(c),
        'Segmented' => _saneSegmented(c),
        'TextField' => true,
        _ => false,
      };
    } catch (_) {
      return false;
    }
  }

  /// Creates one genui surface per handled component immigrating the
  /// protocol defaults, then updates the components. Failures are recorded
  /// in [failedIds] per component; a whole-form failure fails every handled
  /// component. Never throws.
  void buildForm(List<CardComponent> form) {
    if (_disposed) return;
    _form
      ..clear()
      ..addAll(form);
    _failedIds.clear();
    _surfaceIds.clear();
    if (form.isEmpty) return;

    try {
      // One surface per component: fallback stays per-component and a bad
      // component cannot blank the whole sheet.
      for (var i = 0; i < form.length; i++) {
        final c = form[i];
        if (!handles(c)) continue;
        final surfaceId = 'genui_form_$i';
        try {
          _controller.handleMessage(core.CreateSurfaceMessage(
            surfaceId: surfaceId,
            catalogId: _catalogId,
          ));
          _surfaceIds[c.id] = surfaceId;
        } catch (error) {
          _failedIds.add(c.id);
          debugPrint('GenUiFormAdapter: create failed for ${c.id}: $error');
        }
      }

      // Seed defaults before the components exist so the widgets bind
      // initial values on first build.
      for (final c in _form) {
        if (!handles(c) || _failedIds.contains(c.id)) continue;
        try {
          final seed = _seedValue(c);
          if (seed == null) continue;
          _controller.handleMessage(core.UpdateDataModelMessage(
            surfaceId: _surfaceIds[c.id]!,
            path: '/form/${c.id}',
            value: seed,
          ));
        } catch (error) {
          _failedIds.add(c.id);
          debugPrint('GenUiFormAdapter: seed failed for ${c.id}: $error');
        }
      }

      // The root component of each surface is the translated widget.
      for (final c in _form) {
        if (!handles(c) || _failedIds.contains(c.id)) continue;
        try {
          _controller.handleMessage(core.UpdateComponentsMessage(
            surfaceId: _surfaceIds[c.id]!,
            components: <Map<String, dynamic>>[_translate(c)],
          ));
        } catch (error) {
          _failedIds.add(c.id);
          debugPrint('GenUiFormAdapter: update failed for ${c.id}: $error');
        }
      }
    } catch (error) {
      for (final c in _form) {
        if (handles(c)) _failedIds.add(c.id);
      }
      debugPrint('GenUiFormAdapter: buildForm failed: $error');
    }
  }

  /// Reads every genui-rendered field back from the data model, converting
  /// to protocol wire values. Null or wrong-typed values fall back to the
  /// component default from `properties`; fields with no value at all are
  /// omitted so the swipe-right payload keeps its value. Never throws.
  Map<String, dynamic> collectValues() {
    if (_disposed) return const <String, dynamic>{};
    final result = <String, dynamic>{};
    for (final c in _form) {
      if (!handles(c) || _failedIds.contains(c.id)) continue;
      final surfaceId = _surfaceIds[c.id];
      if (surfaceId == null) continue;
      Object? value;
      try {
        value = _controller
            .contextFor(surfaceId)
            .dataModel
            .getValue<Object>(DataPath('/form/${c.id}'));
      } catch (_) {
        value = null;
      }
      final converted = _convertBack(c, value) ?? _defaultFor(c);
      if (converted == null) continue;
      // An empty text field reports nothing, mirroring the hand-rolled
      // renderer: the swipe-right payload keeps its value.
      if (c.component == 'TextField' &&
          converted is String &&
          converted.isEmpty) {
        continue;
      }
      result[c.id] = converted;
    }
    return result;
  }

  /// The genui surface context for a component rendered by this adapter.
  /// Only valid for components that `handles` and are not in [failedIds]
  /// after [buildForm].
  SurfaceContext contextFor(String componentId) {
    final surfaceId = _surfaceIds[componentId];
    if (surfaceId == null) {
      throw StateError(
        'No genui surface for component "$componentId"; '
        'it was not rendered through GenUiFormAdapter.',
      );
    }
    return _controller.contextFor(surfaceId);
  }

  /// Deletes the surfaces and releases the controller. Idempotent; safe to
  /// call twice anywhere in the lifecycle.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final surfaceId in _surfaceIds.values) {
      try {
        _controller.handleMessage(
          core.DeleteSurfaceMessage(surfaceId: surfaceId),
        );
      } catch (_) {
        // Surface may already be gone; controller.dispose() cleans up.
      }
    }
    _surfaceIds.clear();
    _form.clear();
    _failedIds.clear();
    _controller.dispose();
  }

  // ---------------------------------------------------------------------
  // Translation

  /// Wire JSON for the genui component: properties are siblings of `id` and
  /// `component` (the a2ui_core processor flattens them), and every field
  /// binds to the data model via a `{path: '/form/<id>'}` reference rather
  /// than a literal value.
  Map<String, dynamic> _translate(CardComponent c) {
    final props = c.properties;
    final label = props['label'] == null ? null : '${props['label']}';
    return switch (c.component) {
      'TimePicker' => <String, dynamic>{
          'id': 'root',
          'component': 'DateTimeInput',
          'value': <String, dynamic>{'path': '/form/${c.id}'},
          'variant': 'time',
          if (label != null) 'label': label,
        },
      'DatePicker' => <String, dynamic>{
          'id': 'root',
          'component': 'DateTimeInput',
          'value': <String, dynamic>{'path': '/form/${c.id}'},
          'variant': 'date',
          if (label != null) 'label': label,
        },
      'Slider' => <String, dynamic>{
          'id': 'root',
          'component': 'Slider',
          'value': <String, dynamic>{'path': '/form/${c.id}'},
          if (label != null) 'label': label,
          if (props['min'] is num) 'min': (props['min'] as num).toDouble(),
          if (props['max'] is num) 'max': (props['max'] as num).toDouble(),
        },
      'Segmented' => <String, dynamic>{
          'id': 'root',
          'component': 'ChoicePicker',
          'value': <String, dynamic>{'path': '/form/${c.id}'},
          'variant': 'mutuallyExclusive',
          'displayStyle': 'chips',
          if (label != null) 'label': label,
          'options': _segmentedOptions(c),
        },
      'TextField' => <String, dynamic>{
          'id': 'root',
          'component': 'TextField',
          'value': <String, dynamic>{'path': '/form/${c.id}'},
          if (label != null) 'label': label,
          if (props['multiline'] == true) 'variant': 'longText',
        },
      _ => throw ArgumentError('Unhandled component type: ${c.component}'),
    };
  }

  /// Segmented options → ChoicePicker options. Options may be plain strings
  /// or `{label, value}` maps; order is preserved; the value defaults to the
  /// label when the protocol does not provide one.
  List<Map<String, dynamic>> _segmentedOptions(CardComponent c) {
    final raw = c.properties['options'];
    if (raw is! List) throw ArgumentError('Segmented options must be a list');
    return [
      for (final option in raw)
        if (option is String)
          <String, dynamic>{'label': option, 'value': option}
        else if (option is Map)
          <String, dynamic>{
            'label': '${option['label'] ?? option['value'] ?? ''}',
            'value': '${option['value'] ?? option['label'] ?? ''}',
          }
        else
          throw ArgumentError('Segmented option must be a string or map'),
    ];
  }

  // ---------------------------------------------------------------------
  // Seeding and read-back

  /// The data-model value seeded for [c]'s default.
  Object? _seedValue(CardComponent c) {
    return switch (c.component) {
      'TimePicker' => _seedTime(c),
      'DatePicker' => _seedDate(c),
      'Slider' => _seedSlider(c),
      'Segmented' => _seedSegmented(c),
      'TextField' => _seedText(c),
      _ => null,
    };
  }

  Object? _seedTime(CardComponent c) {
    final time = _protocolTime('${c.properties['default'] ?? ''}');
    if (time == null) return null;
    return '1970-01-01T$time:00.000';
  }

  Object? _seedDate(CardComponent c) {
    final raw = c.properties['default'];
    if (raw is! String || raw.isEmpty) return null;
    final date = DateTime.tryParse(raw);
    if (date == null) return null;
    return _isoDate(date);
  }

  Object? _seedSlider(CardComponent c) {
    final min = (c.properties['min'] as num?)?.toDouble() ?? 0;
    final max = (c.properties['max'] as num?)?.toDouble() ?? 1;
    final def = (c.properties['default'] as num?)?.toDouble() ?? min;
    return def.clamp(min, max);
  }

  Object? _seedSegmented(CardComponent c) {
    final options = _segmentedOptions(c);
    final selected = _protocolSegmentedDefault(c, options);
    return selected;
  }

  Object? _seedText(CardComponent c) {
    final raw = c.properties['default'];
    return raw == null ? '' : '$raw';
  }

  /// Converts a genui data-model value back to the protocol wire value.
  Object? _convertBack(CardComponent c, Object? value) {
    if (value == null) return null;
    return switch (c.component) {
      'TimePicker' => _readTime(value),
      'DatePicker' => _readDate(value),
      'Slider' => value is num ? value.toDouble() : null,
      'Segmented' => _readSegmented(value),
      'TextField' => value is String ? value : null,
      _ => null,
    };
  }

  /// Protocol-side default (the value a bare hand-rolled field would
  /// report when the data model is empty).
  Object? _defaultFor(CardComponent c) {
    return switch (c.component) {
      'TimePicker' => _protocolTime('${c.properties['default'] ?? ''}'),
      'DatePicker' => _protocolDate(c.properties['default']),
      'Slider' => _seedSlider(c),
      'Segmented' => _protocolSegmentedDefault(c, _segmentedOptions(c)),
      'TextField' => _seedText(c),
      _ => null,
    };
  }

  String? _protocolTime(String raw) {
    final match = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(raw.trim());
    if (match == null) return null;
    final hour = int.parse(match.group(1)!);
    final minute = int.parse(match.group(2)!);
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
    return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  }

  String? _protocolDate(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    final date = DateTime.tryParse(raw);
    return date == null ? null : _isoDate(date);
  }

  String? _readTime(Object? value) {
    if (value is! String) return null;
    final match = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(value.trim());
    if (match != null) {
      final hour = int.parse(match.group(1)!);
      final minute = int.parse(match.group(2)!);
      if (hour <= 23 && minute <= 59) {
        return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
      }
    }
    final date = DateTime.tryParse(value);
    if (date == null) return null;
    return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  String? _readDate(Object? value) {
    if (value is! String) return null;
    final date = DateTime.tryParse(value);
    return date == null ? null : _isoDate(date);
  }

  String? _readSegmented(Object? value) {
    if (value is List && value.isNotEmpty) return '${value.first}';
    if (value is String) return value;
    return null;
  }

  String? _protocolSegmentedDefault(
    CardComponent c,
    List<Map<String, dynamic>> options,
  ) {
    final raw = c.properties['default'];
    if (raw is String) return raw;
    return options.isEmpty ? null : options.first['value'] as String?;
  }

  String _isoDate(DateTime date) {
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  // ---------------------------------------------------------------------
  // Sanity checks (handles())

  bool _saneTime(CardComponent c) {
    final d = c.properties['default'];
    if (d == null) return true;
    return d is String && _protocolTime(d) != null;
  }

  bool _saneDate(CardComponent c) {
    final d = c.properties['default'];
    if (d == null) return true;
    return d is String && DateTime.tryParse(d) != null;
  }

  bool _saneSlider(CardComponent c) {
    final min = c.properties['min'];
    final max = c.properties['max'];
    if (min != null && min is! num) return false;
    if (max != null && max is! num) return false;
    if (min is num && max is num && min >= max) return false;
    final d = c.properties['default'];
    return d == null || d is num;
  }

  bool _saneSegmented(CardComponent c) {
    final raw = c.properties['options'];
    if (raw is! List || raw.isEmpty) return false;
    return raw.every(
      (option) =>
          option is String ||
          (option is Map &&
              (option['label'] != null || option['value'] != null)),
    );
  }
}