// Muted paper-like palette shared by sheet + graph views.
import 'package:flutter/material.dart';

class PaperTheme {
  static const paper = Color(0xFFE9E2D3);
  static const paperDark = Color(0xFFDCD4BE);
  static const surface = Color(0xFFDDD6C2);
  static const card = Color(0xFFD6CDB4);
  static const ink = Color(0xFF3E3A31);
  static const inkSoft = Color(0xFF6B6455);
  static const line = Color(0xFFA9A08B);
  static const lineThin = Color(0xFFB7AE97);
  static const chip = Color(0xFFCFC5AB);
  static const chipHover = Color(0xFFC4B998);

  static ThemeData theme() {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF8A8171),
      brightness: Brightness.light,
    ).copyWith(
      surface: paper,
      primary: const Color(0xFF6B6455),
      secondary: const Color(0xFF7A7261),
    );
    return ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: paper,
      appBarTheme: const AppBarTheme(
        backgroundColor: paperDark,
        foregroundColor: ink,
        elevation: 0,
      ),
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: ink,
        selectionColor: Color(0xFFC9BFA6),
        selectionHandleColor: inkSoft,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: InputBorder.none,
      ),
    );
  }
}
