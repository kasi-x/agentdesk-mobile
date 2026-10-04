import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../services/task_repository.dart';

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
  String? _status;

  @override
  void initState() {
    super.initState();
    final config = context.read<TaskRepository>().config;
    _url = TextEditingController(text: config.hubUrl);
    _token = TextEditingController(text: config.clientToken);
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final repo = context.read<TaskRepository>();
    final config = HubConfig(hubUrl: _url.text.trim(), clientToken: _token.text.trim());
    await repo.applyConfig(config);
    if (!mounted) return;
    setState(() => _status = '保存しました。接続を再確立しています…');
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
        ],
      ),
    );
  }
}
