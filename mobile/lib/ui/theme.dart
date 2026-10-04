import 'package:flutter/material.dart';

/// Dark, calm triage theme — cards carry the color, chrome stays quiet.
final ThemeData triageTheme = ThemeData(
  useMaterial3: true,
  brightness: Brightness.dark,
  colorScheme: ColorScheme.fromSeed(
    seedColor: const Color(0xFF5B8DEF),
    brightness: Brightness.dark,
    surface: const Color(0xFF171B22),
  ),
  scaffoldBackgroundColor: const Color(0xFF101318),
  appBarTheme: const AppBarTheme(
    backgroundColor: Colors.transparent,
    centerTitle: false,
    elevation: 0,
  ),
  snackBarTheme: const SnackBarThemeData(
    behavior: SnackBarBehavior.floating,
    backgroundColor: Color(0xFF232936),
  ),
);
