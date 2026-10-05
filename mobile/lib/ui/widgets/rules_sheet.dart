import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/hub_api.dart';
import '../../services/task_repository.dart';
import '../colors.dart';

/// Rules manager (I-304/807/602): opened from the Settings 「自動承認ルール」
/// row. Lists rules from `GET /api/v1/rules`, edits the whole list locally,
/// and saves via `PUT /api/v1/rules`. Rules apply to NEW cards only.
///
/// Offline the sheet is read-only and shows 「オフライン: 表示のみ」;
/// any failed load/save surfaces a toast.
class RulesSheet extends StatefulWidget {
  const RulesSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const RulesSheet(),
    );
  }

  @override
  State<RulesSheet> createState() => _RulesSheetState();
}

const List<String> _severities = <String>[
  'info',
  'warning',
  'critical',
];

class _RulesSheetState extends State<RulesSheet> {
  List<AutoApprovalRule>? _rules;
  bool _loading = true;
  bool _saving = false;
  bool _readOnly = false;

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
        });
      }
      return;
    }
    final rulesApi = api as HubRulesApi;
    final rules = await rulesApi.fetchRules();
    setState(() {
      _loading = false;
      _rules = rules ?? <AutoApprovalRule>[];
      // A null fetch means the hub was unreachable (offline / error):
      // keep whatever list we have, but forbid edits.
      _readOnly = rules == null;
    });
    if (rules == null) {
      _failToast('オフライン: 表示のみ');
    }
  }

  void _failToast(String message) {
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
      _failToast('このハブはルール管理に対応していません');
      return;
    }
    final rulesApi = api as HubRulesApi;
    setState(() => _saving = true);
    final ok = await rulesApi.saveRules(rules);
    setState(() => _saving = false);
    if (!ok) {
      _failToast('保存できませんでした（オフライン？）');
      return;
    }
    HapticFeedback.mediumImpact();
    if (mounted) Navigator.of(context).pop();
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

  Future<void> _add() async {
    final created = await showModalBottomSheet<AutoApprovalRule>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _RuleEditor(),
    );
    if (created == null || !mounted) return;
    HapticFeedback.mediumImpact();
    setState(() => _rules = [..._rules!, created]);
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 12, 16, 20 + bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Center(child: Icon(Icons.drag_handle, size: 16)),
            const SizedBox(height: 8),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '自動承認ルール',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                ),
                if (!_readOnly)
                  IconButton(
                    icon: const Icon(Icons.add),
                    tooltip: 'ルールを追加',
                    onPressed: _add,
                  ),
              ],
            ),
            const Text(
              '新しいカードにのみ適用されます。既に届いたカードは対象外です。',
              style: TextStyle(fontSize: 12, color: Colors.white54),
            ),
            if (_readOnly && !_loading) ...[
              const SizedBox(height: 8),
              const Text(
                'オフライン: 表示のみ',
                style: TextStyle(fontSize: 12, color: PopColors.orange),
              ),
            ],
            const SizedBox(height: 8),
            Flexible(
              child: _loading
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: CircularProgressIndicator(),
                      ),
                    )
                  : _rules!.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Center(
                            child: Text(
                              'ルールはまだありません',
                              style: TextStyle(
                                  fontSize: 13, color: Colors.white54),
                            ),
                          ),
                        )
                      : ListView(
                          shrinkWrap: true,
                          children: [
                            for (final rule in _rules!)
                              _RuleRow(
                                rule: rule,
                                readOnly: _readOnly,
                                onToggle: (v) => _toggle(rule.id, v),
                                onDelete: () => _delete(rule.id),
                              ),
                          ],
                        ),
            ),
            if (!_readOnly) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child:
                      Text(_saving ? '保存中…' : '保存'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RuleRow extends StatelessWidget {
  final AutoApprovalRule rule;
  final bool readOnly;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;

  const _RuleRow({
    required this.rule,
    required this.readOnly,
    required this.onToggle,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final detail = _describe(rule);
    return Card(
      color: PopColors.surface2,
      child: ListTile(
        title: Text(rule.id.isEmpty ? '(no id)' : rule.id,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
        subtitle: Text(detail,
            style: const TextStyle(fontSize: 12, color: Colors.white54)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
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
    );
  }
}

String _describe(AutoApprovalRule rule) {
  final parts = <String>[];
  if (rule.agent != null && rule.agent!.isNotEmpty) {
    parts.add('agent: ${rule.agent}');
  }
  if (rule.severity.isNotEmpty) parts.add('severity: ${rule.severity.join(',')}');
  if (rule.maxCost != null) parts.add('maxCost: ${rule.maxCost}');
  if (rule.groupKey != null && rule.groupKey!.isNotEmpty) {
    parts.add('group: ${rule.groupKey}');
  }
  if (rule.leaseMaxCount != null) parts.add('上限 ${rule.leaseMaxCount}件');
  if (rule.leaseUntil != null) parts.add('期限 ${rule.leaseUntil}');
  if (parts.isEmpty) return 'すべてに一致';
  return parts.join(' · ');
}

/// Simple rule composer: agent substring + severity multiselect +
/// maxCount text + enable switch. Completes with the new rule, or null
/// when dismissed.
class _RuleEditor extends StatefulWidget {
  const _RuleEditor();

  @override
  State<_RuleEditor> createState() => _RuleEditorState();
}

class _RuleEditorState extends State<_RuleEditor> {
  final TextEditingController _agent = TextEditingController();
  final TextEditingController _maxCount = TextEditingController();
  final Set<String> _severity = <String>{};
  bool _enabled = true;

  @override
  void dispose() {
    _agent.dispose();
    _maxCount.dispose();
    super.dispose();
  }

  void _submit() {
    final agent = _agent.text.trim();
    final maxCountRaw = _maxCount.text.trim();
    final maxCount =
        maxCountRaw.isEmpty ? null : int.tryParse(maxCountRaw);
    if (maxCountRaw.isNotEmpty && (maxCount == null || maxCount < 1)) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('上限は1以上の整数で入力してください')));
      return;
    }
    final id = 'rule_${DateTime.now().millisecondsSinceEpoch}';
    Navigator.of(context).pop(AutoApprovalRule(
      id: id,
      agent: agent.isEmpty ? null : agent,
      severity: _severity.toList(),
      leaseMaxCount: maxCount,
      enabled: _enabled,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 12, 16, 20 + bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Center(child: Icon(Icons.drag_handle, size: 16)),
            const SizedBox(height: 8),
            const Text('ルールを追加',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            TextField(
              controller: _agent,
              decoration: const InputDecoration(
                labelText: 'エージェント名（部分一致、空欄で全て）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            const Text('重要度（未選択で全て）',
                style: TextStyle(fontSize: 12, color: Colors.white54)),
            Wrap(
              spacing: 8,
              children: [
                for (final s in _severities)
                  FilterChip(
                    label: Text(s),
                    selected: _severity.contains(s),
                    onSelected: (on) => setState(() {
                      if (on) {
                        _severity.add(s);
                      } else {
                        _severity.remove(s);
                      }
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _maxCount,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '上限件数（空欄で無制限）',
                border: OutlineInputBorder(),
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('有効にする'),
              value: _enabled,
              onChanged: (v) => setState(() => _enabled = v),
            ),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _submit,
                child: const Text('追加'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
