import 'package:flutter/material.dart';

class WhoopColors {
  static const background  = Color(0xFF050505);
  static const surface     = Color(0xFF111111);
  static const card        = Color(0xFF1A1A1A);
  static const cardBorder  = Color(0xFF2A2A2A);
  static const primary     = Color(0xFFE53935);   // WHOOP red
  static const primaryDim  = Color(0x33E53935);
  static const accent      = Color(0xFFFF6B35);   // orange accent
  static const green       = Color(0xFF4CAF50);
  static const textPrimary = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xFF888888);
  static const textDim     = Color(0xFF444444);
  static const divider     = Color(0xFF222222);
}

final appTheme = ThemeData(
  colorScheme: const ColorScheme.dark(
    surface: WhoopColors.background,
    primary: WhoopColors.primary,
    secondary: WhoopColors.accent,
    onSurface: WhoopColors.textPrimary,
  ),
  scaffoldBackgroundColor: WhoopColors.background,
  cardColor: WhoopColors.card,
  dividerColor: WhoopColors.divider,
  useMaterial3: true,
  fontFamily: 'Roboto',
  textTheme: const TextTheme(
    displayLarge: TextStyle(
      color: WhoopColors.textPrimary,
      fontSize: 96,
      fontWeight: FontWeight.w200,
      letterSpacing: -2,
    ),
    displayMedium: TextStyle(
      color: WhoopColors.textPrimary,
      fontSize: 60,
      fontWeight: FontWeight.w300,
    ),
    headlineLarge: TextStyle(
      color: WhoopColors.textPrimary,
      fontSize: 32,
      fontWeight: FontWeight.w600,
    ),
    headlineMedium: TextStyle(
      color: WhoopColors.textPrimary,
      fontSize: 24,
      fontWeight: FontWeight.w500,
    ),
    titleLarge: TextStyle(
      color: WhoopColors.textPrimary,
      fontSize: 20,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.5,
    ),
    titleMedium: TextStyle(
      color: WhoopColors.textSecondary,
      fontSize: 14,
      fontWeight: FontWeight.w500,
      letterSpacing: 1.2,
    ),
    bodyLarge: TextStyle(color: WhoopColors.textPrimary, fontSize: 16),
    bodyMedium: TextStyle(color: WhoopColors.textSecondary, fontSize: 14),
    labelSmall: TextStyle(
      color: WhoopColors.textSecondary,
      fontSize: 10,
      letterSpacing: 1.5,
      fontWeight: FontWeight.w600,
    ),
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: WhoopColors.background,
    elevation: 0,
    centerTitle: false,
    titleTextStyle: TextStyle(
      color: WhoopColors.textPrimary,
      fontSize: 20,
      fontWeight: FontWeight.w600,
    ),
    iconTheme: IconThemeData(color: WhoopColors.textPrimary),
  ),
  elevatedButtonTheme: ElevatedButtonThemeData(
    style: ElevatedButton.styleFrom(
      backgroundColor: WhoopColors.primary,
      foregroundColor: WhoopColors.textPrimary,
      minimumSize: const Size.fromHeight(56),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: 1),
    ),
  ),
);
