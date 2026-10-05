import 'package:flutter/material.dart';

import 'colors.dart';

/// Calm-iOS triage theme — neutral elevated surfaces, blue accent.
/// Cards carry only the necessary information; color is meaning.
final ThemeData triageTheme = ThemeData(
  useMaterial3: true,
  brightness: Brightness.dark,
  colorScheme: ColorScheme.fromSeed(
    seedColor: PopColors.blue,
    brightness: Brightness.dark,
    surface: PopColors.surface,
  ),
  scaffoldBackgroundColor: PopColors.bg,
  appBarTheme: const AppBarTheme(
    backgroundColor: Colors.transparent,
    centerTitle: false,
    elevation: 0,
  ),
  snackBarTheme: const SnackBarThemeData(
    behavior: SnackBarBehavior.floating,
    backgroundColor: PopColors.surface2,
  ),
);
