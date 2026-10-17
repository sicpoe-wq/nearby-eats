import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  static ThemeData build(Brightness b) {
    final scheme = ColorScheme.fromSeed(
        seedColor: const Color(0xFFFF6B35), brightness: b);
    final base = ThemeData(useMaterial3: true, colorScheme: scheme);
    return base.copyWith(
      textTheme: GoogleFonts.interTextTheme(base.textTheme),
      appBarTheme: const AppBarTheme(centerTitle: false),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerHigh,
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(28), borderSide: BorderSide.none),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      ),
    );
  }
}
