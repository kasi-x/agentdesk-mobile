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
        // I-1004 a11y: honor OS text scaling but clamp so a 200% scale
        // doesn't shatter the card layout — labels still grow 60%.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: MediaQuery.textScalerOf(context)
                .clamp(minScaleFactor: 0.85, maxScaleFactor: 1.6),
          ),
          child: child!,
        ),
        home: const TriageScreen(),
      ),
    );
  }
}
