import 'package:flutter/material.dart';

import 'colors.dart';

/// Color-pop triage theme — warm dark chrome, amber CTA. The cards
/// themselves carry severity color (see PopColors / task_card_view).
final ThemeData triageTheme = ThemeData(
  useMaterial3: true,
  brightness: Brightness.dark,
  colorScheme: ColorScheme.fromSeed(
    seedColor: PopColors.amber,
    brightness: Brightness.dark,
    surface: PopColors.chrome,
  ),
  scaffoldBackgroundColor: PopColors.bg,
  appBarTheme: const AppBarTheme(
    backgroundColor: Colors.transparent,
    centerTitle: false,
    elevation: 0,
  ),
  snackBarTheme: const SnackBarThemeData(
    behavior: SnackBarBehavior.floating,
    backgroundColor: PopColors.chrome2,
  ),
);
