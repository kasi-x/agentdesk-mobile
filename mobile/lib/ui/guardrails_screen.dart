import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/hub_api.dart';
import '../services/task_repository.dart';
import 'colors.dart';

/// Guardrails screen — Executive Desk rules manager (I-1002).
///
/// Lists rules from `GET /api/v1/rules` with per-rule enabled toggle,
/// action (approve/reject) badge, delete, and a "learned" tag when
/// `source == "learned"` (I-1003 swipe-to-learn). The editor offers a
/// minConfidence slider, maxCost stepper, severity chips, agent substring
/// and an approve/reject toggle, with a live dry-run preview via
/// `POST /api/v1/rules/simulate` (debounced ~300ms).
///
/// Old hubs: no simulate route → the preview hides but rules stay
/// editable; no rules surface at all → read-only offline-style state.
class GuardrailsScreen extends StatefulWidget {
  const GuardrailsScreen({super.key});

  @override
  State<GuardrailsScreen> createState() => _GuardrailsScreenState();
}

const List<String> _severities = <String>['info', 'warning', 'critical'];

class _GuardrailsScreenState extends State<GuardrailsScreen> {
  List<AutoApprovalRule>? _rules;
  bool _loading = true;
  bool _saving = false;
  bool _readOnly = false;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<TaskRepository>().api;
    if (api is! HubRulesApi) {
      if (mounted) {
        setState(() {
          _loading = false;
          _rules = <AutoApprovalRule>[];
          _readOnly = true;
          _notice = 'このハブはルール管理に対応していません（表示のみ）';
        });
      }
      return;
    }
    final rules = await (api as HubRulesApi).fetchRules();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _rules = rules ?? <AutoApprovalRule>[];
      _readOnly = rules == null;
      _notice = rules == null ? 'オフライン: 表示のみ' : null;
    });
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _save() async {
    final rules = _rules;
    if (rules == null || _saving) return;
    final api = context.read<TaskRepository>().api;
    if (api is! HubRulesApi) {
      _toast('このハブはルール管理に対応していません');
      return;
    }
    setState(() => _saving = true);
    final ok = await (api as HubRulesApi).saveRules(rules);
    if (!mounted) return;
    setState(() => _saving = false);
    if (!ok) {
      _toast('保存できませんでした（オフライン？）');
      return;
    }
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop();
  }

  void _toggle(String id, bool enabled) {
    HapticFeedback.selectionClick();
    setState(() {
      _rules = [
        for (final rule in _rules!)
          if (rule.id == id) rule.copyWith(enabled: enabled) else rule,
      ];
    });
  }

  void _delete(String id) {
    HapticFeedback.selectionClick();
    setState(() {
      _rules = [for (final rule in _rules!) if (rule.id != id) rule];
    });
  }

  HubGuardrailsApi? get _guardrails {
    final api = context.read<TaskRepository>().api;
    return api is HubGuardrailsApi ? api as HubGuardrailsApi : null;
  }

  Future<void> _edit(AutoApprovalRule rule) async {
    if (_readOnly) return;
    // The sheet route sits above the provider scope, so hand the API
    // down explicitly rather than context.read inside the editor.
    final guardrails = _guardrails;
    final updated = await showModalBottomSheet<AutoApprovalRule>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _RuleEditor(initial: rule, guardrails: guardrails),
    );
    if (updated == null || !mounted) return;
    HapticFeedback.mediumImpact();
    setState(() {
      _rules = [
        for (final r in _rules!) if (r.id == updated.id) updated else r,
      ];
    });
  }

  Future<void> _add() async {
    final guardrails = _guardrails;
    final created = await showModalBottomSheet<AutoApprovalRule>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _RuleEditor(guardrails: guardrails),
    );
    if (created == null || !mounted) return;
    HapticFeedback.mediumImpact();
    setState(() => _rules = [..._rules!, created]);
  }

  @override
  Widget build(BuildContext context) {
    final rules = _rules;
    return Scaffold(
      appBar: AppBar(
        title: const Text('ガードレール'),
        actions: [
          if (!_readOnly && !_loading)
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: 'ルールを追加',
              onPressed: _add,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    '新しいカードにのみ適用されます。既に届いたカードは対象外です。',
                    style: TextStyle(fontSize: 12, color: Colors.white54),
                  ),
                ),
                if (_notice != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                    child: Text(
                      _notice!,
                      style: const TextStyle(
                          fontSize: 12, color: PopColors.orange),
                    ),
                  ),
                Expanded(
                  child: rules == null || rules.isEmpty
                      ? const Center(
                          child: Text(
                            'ルールはまだありません',
                            style: TextStyle(
                                fontSize: 13, color: Colors.white54),
                          ),
                        )
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                          children: [
                            for (final rule in rules)
                              _RuleCard(
                                rule: rule,
                                readOnly: _readOnly,
                                onToggle: (v) => _toggle(rule.id, v),
                                onDelete: () => _delete(rule.id),
                                onEdit: () => _edit(rule),
                              ),
                          ],
                        ),
                ),
                if (!_readOnly)
                  SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: _saving ? null : _save,
                          child: Text(_saving ? '保存中…' : '保存'),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _RuleCard extends StatelessWidget {
  final AutoApprovalRule rule;
  final bool readOnly;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;
  final VoidCallback onEdit;

  const _RuleCard({
    required this.rule,
    required this.readOnly,
    required this.onToggle,
    required this.onDelete,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final isReject = rule.action == 'reject';
    return Card(
      color: PopColors.surface2,
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: readOnly ? null : onEdit,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: isReject
                                ? PopColors.red.withValues(alpha: 0.2)
                                : PopColors.fill2,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            isReject ? 'reject' : 'approve',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: isReject
                                  ? PopColors.red
                                  : const Color(0xFF7BE494),
                            ),
                          ),
                        ),
                        if (rule.source == 'learned')
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: PopColors.orange.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: const Text(
                              'learned',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                color: PopColors.orange,
                              ),
                            ),
                          ),
                        if (!rule.enabled)
                          const Text(
                            'off',
                            style: TextStyle(
                                fontSize: 11, color: Colors.white38),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _describe(rule),
                      style: const TextStyle(
                          fontSize: 12, color: Colors.white70),
                    ),
                  ],
                ),
              ),
              Switch(
                value: rule.enabled,
                onChanged: readOnly ? null : onToggle,
              ),
              if (!readOnly)
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  tooltip: '削除',
                  onPressed: onDelete,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

String _describe(AutoApprovalRule rule) {
  final parts = <String>[];
  if (rule.agent != null && rule.agent!.isNotEmpty) {
    parts.add('agent: ${rule.agent}');
  }
  if (rule.severity.isNotEmpty) {
    parts.add('severity: ${rule.severity.join(',')}');
  }
  if (rule.maxCost != null) parts.add('maxCost ≤ ${rule.maxCost}');
  if (rule.minConfidence != null) {
    parts.add('confidence ≥ ${rule.minConfidence!.toStringAsFixed(2)}');
  }
  if (rule.groupKey != null && rule.groupKey!.isNotEmpty) {
    parts.add('group: ${rule.groupKey}');
  }
  if (rule.leaseMaxCount != null) parts.add('上限 ${rule.leaseMaxCount}件');
  if (rule.leaseUntil != null) parts.add('期限 ${rule.leaseUntil}');
  if (parts.isEmpty) return 'すべてに一致';
  return parts.join(' · ');
}

/// Rule composer/editor with a live dry-run preview (I-1002).
///
/// The preview debounces edits ~300ms and calls
/// `POST /api/v1/rules/simulate {match, action}`; the result renders as
/// a segmented auto-approve / human / auto-reject bar with counts and
/// sampleSize. Hubs without simulate (old hubs, offline) hide the
/// preview — the rule stays editable.
class _RuleEditor extends StatefulWidget {
  final AutoApprovalRule? initial;

  /// Explicitly handed down: the sheet route is above the provider
  /// scope, so the editor must not context.read the repository.
  /// Null = old hub without simulate; the preview hides.
  final HubGuardrailsApi? guardrails;

  const _RuleEditor({this.initial, this.guardrails});

  @override
  State<_RuleEditor> createState() => _RuleEditorState();
}

class _RuleEditorState extends State<_RuleEditor> {
  late final TextEditingController _agent;
  late final TextEditingController _groupKey;
  late final TextEditingController _maxCost;
  late final TextEditingController _maxCount;
  late final Set<String> _severity;
  double? _minConfidence;
  late String _action;
  bool _noConfidenceFloor = false;
  bool _noMaxCost = false;

  Timer? _debounce;
  SimulateResult? _preview;
  bool _previewLoading = false;
  bool _simulateSupported = true;

  bool get _isNew => widget.initial == null;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _agent = TextEditingController(text: initial?.agent ?? '');
    _groupKey = TextEditingController(text: initial?.groupKey ?? '');
    _maxCost = TextEditingController(
        text: initial?.maxCost == null ? '' : '${initial!.maxCost}');
    _maxCount = TextEditingController(
        text: initial?.leaseMaxCount == null
            ? ''
            : '${initial!.leaseMaxCount}');
    _severity = <String>{...(initial?.severity ?? const <String>[])};
    _minConfidence = initial?.minConfidence;
    _action = initial?.action == 'reject' ? 'reject' : 'approve';
    _noConfidenceFloor = initial != null && initial.minConfidence == null;
    _noMaxCost = initial != null && initial.maxCost == null;
    for (final c in [_agent, _groupKey, _maxCost, _maxCount]) {
      c.addListener(_schedulePreview);
    }
    _schedulePreview();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _agent.dispose();
    _groupKey.dispose();
    _maxCost.dispose();
    _maxCount.dispose();
    super.dispose();
  }

  Map<String, dynamic> _draftMatch() {
    final agent = _agent.text.trim();
    final group = _groupKey.text.trim();
    final maxCost = double.tryParse(_maxCost.text.trim());
    return <String, dynamic>{
      if (agent.isNotEmpty) 'agent': agent,
      if (_severity.isNotEmpty) 'severity': _severity.toList(),
      if (!_noMaxCost && maxCost != null) 'maxCost': maxCost,
      if (!_noConfidenceFloor && _minConfidence != null)
        'minConfidence': _minConfidence,
      if (group.isNotEmpty) 'groupKey': group,
    };
  }

  void _schedulePreview() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _runPreview);
  }

  Future<void> _runPreview() async {
    if (!mounted || !_simulateSupported) return;
    final api = widget.guardrails;
    if (api == null) {
      if (mounted) setState(() => _simulateSupported = false);
      return;
    }
    setState(() => _previewLoading = true);
    final result = await api.simulateRules(
      match: _draftMatch(),
      action: _action,
    );
    if (!mounted) return;
    setState(() {
      _previewLoading = false;
      if (result == null) {
        // Old hub (404) or offline: hide the preview, stay editable.
        // Keep trying on later edits — a reconnect may heal it.
        _preview = null;
      } else {
        _preview = result;
      }
    });
  }

  /// Null on success, error message on validation failure.
  String? _validate() {
    if (_maxCost.text.trim().isNotEmpty &&
        !_noMaxCost &&
        double.tryParse(_maxCost.text.trim()) == null) {
      return 'maxCost は数値で入力してください';
    }
    final maxCountRaw = _maxCount.text.trim();
    if (maxCountRaw.isNotEmpty) {
      final maxCount = int.tryParse(maxCountRaw);
      if (maxCount == null || maxCount < 1) return '上限は1以上の整数で入力してください';
    }
    return null;
  }

  void _submit() {
    final error = _validate();
    if (error != null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    final agent = _agent.text.trim();
    final group = _groupKey.text.trim();
    final maxCost = _noMaxCost ? null : double.tryParse(_maxCost.text.trim());
    final maxCountRaw = _maxCount.text.trim();
    final maxCount =
        maxCountRaw.isEmpty ? null : int.tryParse(maxCountRaw);
    final initial = widget.initial;
    final id = initial?.id ?? 'rule_${DateTime.now().millisecondsSinceEpoch}';
    Navigator.of(context).pop(AutoApprovalRule(
      id: id,
      action: _action,
      source: initial?.source,
      agent: agent.isEmpty ? null : agent,
      severity: _severity.toList(),
      maxCost: maxCost,
      minConfidence: _noConfidenceFloor ? null : _minConfidence,
      groupKey: group.isEmpty ? null : group,
      leaseUntil: initial?.leaseUntil,
      leaseMaxCount: maxCount,
      enabled: initial?.enabled ?? true,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 12, 16, 20 + bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Center(child: Icon(Icons.drag_handle, size: 16)),
              const SizedBox(height: 4),
              Text(_isNew ? 'ルールを追加' : 'ルールを編集',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                      value: 'approve', label: Text('approve')),
                  ButtonSegment(value: 'reject', label: Text('reject')),
                ],
                selected: <String>{_action},
                onSelectionChanged: (selection) {
                  if (selection.isNotEmpty) {
                    setState(() => _action = selection.first);
                    _schedulePreview();
                  }
                },
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _agent,
                decoration: const InputDecoration(
                  labelText: 'エージェント名（部分一致、空欄で全て）',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              const Text('重要度（未選択で全て）',
                  style: TextStyle(fontSize: 12, color: Colors.white54)),
              Wrap(
                spacing: 4,
                runSpacing: 0,
                children: [
                  for (final s in _severities)
                    FilterChip(
                      label: Text(s),
                      selected: _severity.contains(s),
                      visualDensity: VisualDensity.compact,
                      onSelected: (on) {
                        setState(() {
                          if (on) {
                            _severity.add(s);
                          } else {
                            _severity.remove(s);
                          }
                        });
                        _schedulePreview();
                      },
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Expanded(
                    child: Text('信頼度の下限（minConfidence）',
                        style:
                            TextStyle(fontSize: 12, color: Colors.white54)),
                  ),
                  Text(
                    _noConfidenceFloor || _minConfidence == null
                        ? '指定なし'
                        : _minConfidence!.toStringAsFixed(2),
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              Slider(
                value: (_minConfidence ?? 0.0).clamp(0.0, 1.0),
                min: 0.0,
                max: 1.0,
                divisions: 20,
                onChanged: _noConfidenceFloor
                    ? null
                    : (v) {
                        setState(() => _minConfidence = v);
                        _schedulePreview();
                      },
              ),
              Row(
                children: [
                  const Text('下限なし',
                      style: TextStyle(fontSize: 12, color: Colors.white54)),
                  Switch(
                    value: _noConfidenceFloor,
                    onChanged: (v) {
                      setState(() {
                        _noConfidenceFloor = v;
                        if (v) {
                          _minConfidence = null;
                        } else {
                          _minConfidence ??= 0.5;
                        }
                      });
                      _schedulePreview();
                    },
                  ),
                ],
              ),
              TextField(
                controller: _maxCost,
                enabled: !_noMaxCost,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'maxCost（上限金額、空欄で無制限）',
                  border: OutlineInputBorder(),
                ),
              ),
              Row(
                children: [
                  const Text('上限なし',
                      style: TextStyle(fontSize: 12, color: Colors.white54)),
                  Switch(
                    value: _noMaxCost,
                    onChanged: (v) {
                      setState(() => _noMaxCost = v);
                      _schedulePreview();
                    },
                  ),
                ],
              ),
              TextField(
                controller: _groupKey,
                decoration: const InputDecoration(
                  labelText: 'グループ（部分一致、空欄で全て）',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _maxCount,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '上限件数（空欄で無制限）',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              _PreviewBar(
                result: _preview,
                loading: _previewLoading,
                supported: _simulateSupported,
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _submit,
                  child: Text(_isNew ? '追加' : '更新'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Segmented auto-approve % / human % / auto-reject % bar + counts.
class _PreviewBar extends StatelessWidget {
  final SimulateResult? result;
  final bool loading;
  final bool supported;

  const _PreviewBar({
    required this.result,
    required this.loading,
    required this.supported,
  });

  @override
  Widget build(BuildContext context) {
    if (!supported) return const SizedBox.shrink();
    final preview = result;
    if (preview == null && !loading) return const SizedBox.shrink();
    final total = preview?.sampleSize ?? 0;
    final approve = preview?.autoApprove ?? 0;
    final reject = preview?.autoReject ?? 0;
    final hitl = preview?.hitl ?? 0;
    final denom = total <= 0 ? 1 : total;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('プレビュー',
                style: TextStyle(fontSize: 11, color: Colors.white54)),
            const SizedBox(width: 4),
            if (loading)
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: SizedBox(
            height: 8,
            child: Row(
              children: [
                Expanded(
                  flex: (approve * 1000 ~/ denom).clamp(0, 1000),
                  child: Container(color: const Color(0xFF7BE494)),
                ),
                Expanded(
                  flex: (hitl * 1000 ~/ denom).clamp(0, 1000),
                  child: Container(color: PopColors.fill2),
                ),
                Expanded(
                  flex: (reject * 1000 ~/ denom).clamp(0, 1000),
                  child: Container(color: PopColors.red),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          total <= 0
              ? 'サンプルなし'
              : '自動承認 $approve · 人間 $hitl · 自動拒否 $reject（n=$total）',
          style: const TextStyle(fontSize: 11, color: Colors.white70),
        ),
      ],
    );
  }
}
