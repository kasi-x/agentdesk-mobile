import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../services/pairing.dart';
import '../services/task_repository.dart';
import 'widgets/practice_screen.dart';
import 'widgets/rules_sheet.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  static Route<void> route() =>
      MaterialPageRoute<void>(builder: (_) => const SettingsScreen());

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _url;
  late final TextEditingController _token;
  late final TextEditingController _pair;
  String? _status;
  String? _pairStatus;
  bool _pairing = false;

  @override
  void initState() {
    super.initState();
    final config = context.read<TaskRepository>().config;
    _url = TextEditingController(text: config.hubUrl);
    _token = TextEditingController(text: config.clientToken);
    _pair = TextEditingController();
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    _pair.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final repo = context.read<TaskRepository>();
    final config = HubConfig(hubUrl: _url.text.trim(), clientToken: _token.text.trim());
    await repo.applyConfig(config);
    if (!mounted) return;
    setState(() => _status = '保存しました。接続を再確立しています…');
  }

  /// Pair a device (I-808): paste the pairing URL or 6-char code shown
  /// on another screen, redeem it, and switch to the issued device token.
  Future<void> _redeemPairing() async {
    final repo = context.read<TaskRepository>();
    setState(() {
      _pairing = true;
      _pairStatus = null;
    });
    final outcome = await redeemPairing(
      input: _pair.text,
      fallbackHubUrl: repo.config.hubUrl,
    );
    if (!mounted) return;
    setState(() => _pairing = false);
    if (!outcome.ok) {
      setState(() => _pairStatus = outcome.error ?? '失敗しました');
      return;
    }
    final hubUrl = outcome.hubUrl ?? repo.config.hubUrl;
    await repo.applyConfig(
        HubConfig(hubUrl: hubUrl, clientToken: outcome.token!));
    _pair.clear();
    if (!mounted) return;
    setState(() => _pairStatus =
        'ペアリングしました${outcome.user != null ? '（${outcome.user}）' : ''}');
  }

  static String _hm(int minutes) =>
      '${(minutes ~/ 60).toString().padLeft(2, '0')}:'
      '${(minutes % 60).toString().padLeft(2, '0')}';

  Future<void> _pickQuietBound(bool start) async {
    final repo = context.read<TaskRepository>();
    final current = start ? repo.quietStart : repo.quietEnd;
    final initial = TimeOfDay(
        hour: (current ?? (start ? 1320 : 420)) ~/ 60,
        minute: (current ?? (start ? 1320 : 420)) % 60);
    final picked =
        await showTimePicker(context: context, initialTime: initial);
    if (picked == null || !mounted) return;
    final minutes = picked.hour * 60 + picked.minute;
    await repo.setQuietHours(
      start: start ? minutes : (repo.quietStart ?? 1320),
      end: start ? (repo.quietEnd ?? 420) : minutes,
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Hub URL',
              hintText: 'https://agentdesk-hub.example.workers.dev',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _token,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Client token',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _save,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            child: const Text('Save & reconnect'),
          ),
          if (_status != null) ...[
            const SizedBox(height: 12),
            Text(_status!, style: const TextStyle(fontSize: 12, color: Colors.white54)),
          ],
          const Divider(height: 40),
          Text(
            'おやすみ時間',
            style: Theme.of(context)
                .textTheme
                .labelLarge
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          const Text(
            'この時間帯は critical 以外のカードを隠します',
            style: TextStyle(fontSize: 12, color: Colors.white54),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _pickQuietBound(true),
                  child: Text(context
                          .watch<TaskRepository>()
                          .quietStart !=
                      null
                      ? '開始 ${_hm(context.watch<TaskRepository>().quietStart!)}'
                      : '開始 --:--'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _pickQuietBound(false),
                  child: Text(context
                          .watch<TaskRepository>()
                          .quietEnd !=
                      null
                      ? '終了 ${_hm(context.watch<TaskRepository>().quietEnd!)}'
                      : '終了 --:--'),
                ),
              ),
            ],
          ),
          if (context.watch<TaskRepository>().quietStart != null) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: () async {
                await context.read<TaskRepository>().setQuietHours();
                setState(() {});
              },
              child: const Text('おやすみ時間を解除'),
            ),
          ],
          const Divider(height: 40),
          Text(
            'QRペアリング',
            style: Theme.of(context)
                .textTheme
                .labelLarge
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          const Text(
            '別端末に表示されたペアリングURLか6文字コードを貼り付け',
            style: TextStyle(fontSize: 12, color: Colors.white54),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _pair,
            decoration: const InputDecoration(
              labelText: 'ペアリングURL / コード',
              hintText: 'https://…?code=ABC123 または ABC123',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _pairing ? null : _redeemPairing,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            child: Text(_pairing ? 'ペアリング中…' : 'ペアリングする'),
          ),
          if (_pairStatus != null) ...[
            const SizedBox(height: 12),
            Text(_pairStatus!,
                style: const TextStyle(fontSize: 12, color: Colors.white54)),
          ],
          const Divider(height: 40),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.rule_outlined),
            title: const Text('自動承認ルール'),
            subtitle: const Text('新しいカードにのみ適用・上限付きで自動承認'),
            onTap: () => RulesSheet.show(context),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.school_outlined),
            title: const Text('練習モード'),
            subtitle: const Text('偽のカード5枚でジェスチャーを体験'),
            onTap: () =>
                Navigator.of(context).push(PracticeScreen.route()),
          ),
        ],
      ),
    );
  }
}
