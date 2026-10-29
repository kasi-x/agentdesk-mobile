import 'package:flutter/material.dart';

import '../../models/task_card.dart';
import '../../services/hub_api.dart';
import '../colors.dart';

/// I-1005 post-decision scoped-rule sheet (mobile side).
///
/// Shown from the post-decision snackbar: 「今回だけ」 is the default
/// (dismiss = nothing), 同種を自動許可 / 却下 needs explicit scope + a
/// deadline + an impact preview before it can exist (strategy.md P0,
/// P6 — 観測・段階・取消可能). Saves via GET-modify-PUT /api/v1/rules;
/// the result is a `source: "learned"` rule the guardrails screen can
/// list and remove.
///
/// Returns true when a rule was actually saved.
Future<bool> showRuleScopeSheet(
  BuildContext context, {
  required TaskCard task,
  required String action,
  /// Probed as [HubRulesApi] / [HubGuardrailsApi] — `repo.api` is fine;
  /// a plain [HubApi] simply hides the preview and can't save.
  required dynamic api,
}) async {
  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: PopColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (_) => _RuleScopeSheet(task: task, action: action, api: api),
  );
  return saved ?? false;
}

class _RuleScopeSheet extends StatefulWidget {
  final TaskCard task;
  final String action; // 'approve' | 'reject'
  final dynamic api; // probed as HubRulesApi / HubGuardrailsApi

  const _RuleScopeSheet({
    required this.task,
    required this.action,
    required this.api,
  });

  @override
  State<_RuleScopeSheet> createState() => _RuleScopeSheetState();
}

class _RuleScopeSheetState extends State<_RuleScopeSheet> {
  late final TextEditingController _cost;
  String _period = '30d'; // bounded lease is the safe default (段階的)
  bool _saving = false;
  SimulateResult? _preview;
  bool _simUnsupported = false;

  Map<String, dynamic> get _match {
    final match = <String, dynamic>{};
    if (widget.task.agent.name.isNotEmpty) {
      match['agent'] = widget.task.agent.name;
    }
    if (widget.task.severity.isNotEmpty) {
      match['severity'] = <String>[widget.task.severity];
    }
    final gk = widget.task.groupKey;
    if (gk != null && gk.isNotEmpty) match['groupKey'] = gk;
    final cap = double.tryParse(_cost.text.trim());
    if (cap != null && cap >= 0) match['maxCost'] = cap;
    return match;
  }

  String? get _leaseUntil {
    final days = switch (_period) {
      '7d' => 7,
      '30d' => 30,
      _ => 0,
    };
    if (days == 0) return null;
    return DateTime.now()
        .add(Duration(days: days))
        .toUtc()
        .toIso8601String();
  }

  String get _describe {
    final parts = <String>[];
    if (widget.task.agent.name.isNotEmpty) parts.add(widget.task.agent.name);
    if (widget.task.severity.isNotEmpty) parts.add(widget.task.severity);
    final gk = widget.task.groupKey;
    if (gk != null && gk.isNotEmpty) parts.add('グループ $gk');
    return parts.isEmpty ? '同じ条件のカード' : parts.join(' · ');
  }

  @override
  void initState() {
    super.initState();
    final cost = widget.task.impact?.costAmount;
    _cost = TextEditingController(
      text: cost == null
          ? ''
          : (cost == cost.roundToDouble()
              ? cost.round().toString()
              : cost.toString()),
    );
    _cost.addListener(_refreshPreview);
    _refreshPreview();
  }

  @override
  void dispose() {
    _cost.dispose();
    super.dispose();
  }

  Future<void> _refreshPreview() async {
    if (_simUnsupported) return;
    final api = widget.api;
    if (api is! HubGuardrailsApi) {
      setState(() => _simUnsupported = true);
      return;
    }
    final res = await api.simulateRules(
      match: _match,
      action: widget.action,
    );
    if (!mounted) return;
    setState(() {
      if (res == null) {
        _simUnsupported = true; // old hub — hide preview, still allow save
      } else {
        _preview = res;
      }
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    bool ok = false;
    final api = widget.api;
    if (api is HubRulesApi) {
      final rules = await api.fetchRules() ?? <AutoApprovalRule>[];
      final until = _leaseUntil;
      rules.add(AutoApprovalRule(
        id: 'r_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}',
        action: widget.action,
        source: 'learned',
        agent: _match['agent'] as String?,
        severity: (_match['severity'] as List?)?.cast<String>() ??
            const <String>[],
        maxCost: _match['maxCost'] as double?,
        groupKey: _match['groupKey'] as String?,
        leaseUntil: until,
      ));
      ok = await api.saveRules(rules);
    }
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ルールを作成しました — ルール画面で取り消せます')),
      );
    } else {
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ルールを保存できませんでした')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final verb = widget.action == 'reject' ? '自動で却下' : '自動で承認';
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('同種を自動化',
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: PopColors.text)),
          const SizedBox(height: 8),
          Text('$_describe を今後 $verb します。いつでもルール画面から取り消せます。',
              style: const TextStyle(fontSize: 13, color: PopColors.text2)),
          const SizedBox(height: 12),
          TextField(
            controller: _cost,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: '上限金額（空=なし）',
              isDense: true,
            ),
            style: const TextStyle(fontSize: 14, color: PopColors.text),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: _period,
            decoration: const InputDecoration(
                labelText: '適用期間', isDense: true),
            items: const [
              DropdownMenuItem(value: '7d', child: Text('7日間')),
              DropdownMenuItem(value: '30d', child: Text('30日間')),
              DropdownMenuItem(value: 'none', child: Text('無制限')),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _period = v);
            },
          ),
          const SizedBox(height: 10),
          if (_preview != null)
            Text(
              '直近 ${_preview!.sampleSize} 件中 '
              '${widget.action == 'reject' ? _preview!.autoReject : _preview!.autoApprove}'
              ' 件を自動処理 · 手動 ${_preview!.hitl} 件',
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: PopColors.text2),
            )
          else if (_simUnsupported)
            const Text('このハブは影響プレビューに未対応です',
                style: TextStyle(fontSize: 12, color: PopColors.text3)),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _saving
                      ? null
                      : () => Navigator.of(context).pop(false),
                  child: const Text('今回だけ'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? '保存中…' : 'ルールを作成'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
