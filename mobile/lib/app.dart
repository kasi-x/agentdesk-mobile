import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'config.dart';
import 'services/task_repository.dart';
import 'ui/theme.dart';
import 'ui/triage_screen.dart';

class AgentDeskApp extends StatelessWidget {
  final HubConfig config;
  final TaskRepository repository;

  const AgentDeskApp({
    super.key,
    required this.config,
    required this.repository,
  });

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<TaskRepository>.value(
      value: repository,
      child: MaterialApp(
        title: 'AgentDesk',
        theme: triageTheme,
        home: const TriageScreen(),
      ),
    );
  }
}
