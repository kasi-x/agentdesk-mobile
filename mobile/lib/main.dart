import 'package:flutter/material.dart';

import 'app.dart';
import 'config.dart';
import 'services/task_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = await HubConfig.load();
  final repository = TaskRepository(config: config);
  // Offline decisions from previous sessions are queued before the
  // first frame; the 500ms cold-start budget is spent on this plus
  // the snapshot render (NFR-1.2).
  await repository.restoreQueue();
  runApp(AgentDeskApp(config: config, repository: repository));
}
