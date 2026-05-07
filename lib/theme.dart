import 'package:flutter/material.dart';

/// Whoopsie design tokens. Dark by default; the strap is most often used at night.
class WTheme {
  static const accent = Color(0xFF00FF94);
  static const accentMuted = Color(0xFF00B068);
  static const danger = Color(0xFFFF4D6D);
  static const warn = Color(0xFFFFB347);

  static const bg = Color(0xFF080A0C);
  static const card = Color(0xFF111418);
  static const cardElevated = Color(0xFF181C22);
  static const stroke = Color(0xFF22272E);
  static const text = Color(0xFFE8ECF1);
  static const textDim = Color(0xFF8B95A1);
  static const textMuted = Color(0xFF515A66);

  // Status zone colors (recovery / strain ranges)
  static const zoneGreen = Color(0xFF00FF94);
  static const zoneYellow = Color(0xFFFFC04D);
  static const zoneRed = Color(0xFFFF4D6D);
  static const zoneBlue = Color(0xFF4DA3FF);
  static const zonePurple = Color(0xFFB967FF);

  static ThemeData buildDark() {
    final scheme = ColorScheme.dark(
      primary: accent,
      onPrimary: Colors.black,
      surface: card,
      onSurface: text,
      surfaceContainerHighest: cardElevated,
      error: danger,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      textTheme: const TextTheme(
        bodyLarge: TextStyle(color: text, fontFamily: 'monospace'),
        bodyMedium: TextStyle(color: text, fontFamily: 'monospace'),
        bodySmall: TextStyle(color: textDim, fontFamily: 'monospace'),
        labelSmall: TextStyle(color: textMuted, fontFamily: 'monospace', letterSpacing: 1.4),
      ),
      cardTheme: const CardThemeData(
        color: card,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        titleTextStyle: TextStyle(
            fontFamily: 'monospace',
            color: text,
            fontWeight: FontWeight.w600,
            fontSize: 18),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: card,
        indicatorColor: accent.withValues(alpha: 0.15),
        elevation: 0,
        labelTextStyle: WidgetStatePropertyAll(
          const TextStyle(fontFamily: 'monospace', fontSize: 11, color: text),
        ),
        iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
            color: s.contains(WidgetState.selected) ? accent : textDim, size: 22)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.black,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: const TextStyle(
              fontFamily: 'monospace', fontWeight: FontWeight.w600, letterSpacing: 0.4),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: card,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: stroke),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: stroke),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: accent),
        ),
        hintStyle: const TextStyle(color: textMuted, fontFamily: 'monospace'),
      ),
      dividerColor: stroke,
    );
  }

  // Helpers
  static Color zoneFor(double normalized) {
    // 0..1 → red(<0.33), yellow(0.33-0.66), green(>0.66)
    if (normalized >= 0.66) return zoneGreen;
    if (normalized >= 0.33) return zoneYellow;
    return zoneRed;
  }
}
