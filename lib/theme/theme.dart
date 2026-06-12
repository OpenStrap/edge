// OpenStrap v2 theme — Space Grotesk display + Inter body, ember-coral on paper.
// `AppText` is the type scale (replaces the old AppType). Numbers use Space
// Grotesk with tabular figures; body/labels use Inter.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'tokens.dart';

/// Type scale. Display + numerics → Space Grotesk; body/labels → Inter.
class AppText {
  AppText._();

  static const _tnum = [FontFeature.tabularFigures()];

  // ── Display / numerics (Space Grotesk) ──
  static TextStyle get hero => GoogleFonts.spaceGrotesk(
        fontSize: 64, fontWeight: FontWeight.w700, height: 0.98,
        letterSpacing: -2, color: AppColors.ink, fontFeatures: _tnum);
  static TextStyle get display => GoogleFonts.spaceGrotesk(
        fontSize: 44, fontWeight: FontWeight.w700, height: 1.0,
        letterSpacing: -1.2, color: AppColors.ink, fontFeatures: _tnum);
  static TextStyle get metric => GoogleFonts.spaceGrotesk(
        fontSize: 30, fontWeight: FontWeight.w700, height: 1.0,
        letterSpacing: -0.6, color: AppColors.ink, fontFeatures: _tnum);
  static TextStyle get metricSm => GoogleFonts.spaceGrotesk(
        fontSize: 22, fontWeight: FontWeight.w700, height: 1.0,
        letterSpacing: -0.3, color: AppColors.ink, fontFeatures: _tnum);

  // ── Headings (Space Grotesk) ──
  static TextStyle get h1 => GoogleFonts.spaceGrotesk(
        fontSize: 28, fontWeight: FontWeight.w700, height: 1.05,
        letterSpacing: -0.6, color: AppColors.ink);
  static TextStyle get h2 => GoogleFonts.spaceGrotesk(
        fontSize: 20, fontWeight: FontWeight.w700, height: 1.1,
        letterSpacing: -0.3, color: AppColors.ink);

  // ── Body / labels (Inter) ──
  static TextStyle get title => GoogleFonts.inter(
        fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.ink);
  static TextStyle get body => GoogleFonts.inter(
        fontSize: 14.5, fontWeight: FontWeight.w400, height: 1.45,
        color: AppColors.ink);
  static TextStyle get bodySoft => GoogleFonts.inter(
        fontSize: 14.5, fontWeight: FontWeight.w400, height: 1.45,
        color: AppColors.inkSoft);
  static TextStyle get label => GoogleFonts.inter(
        fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.inkSoft,
        letterSpacing: 0.1);
  static TextStyle get caption => GoogleFonts.inter(
        fontSize: 12, fontWeight: FontWeight.w500, color: AppColors.inkSoft);
  static TextStyle get captionMuted => GoogleFonts.inter(
        fontSize: 12, fontWeight: FontWeight.w500, color: AppColors.inkMuted);
  static TextStyle get overline => GoogleFonts.inter(
        fontSize: 11.5, fontWeight: FontWeight.w700, letterSpacing: 1.4,
        color: AppColors.inkMuted);
}

ThemeData buildOpenStrapTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.coral,
    brightness: Brightness.light,
  ).copyWith(
    surface: AppColors.surface,
    primary: AppColors.coral,
    onPrimary: Colors.white,
    secondary: AppColors.coralDeep,
  );

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.bg,
    dividerColor: AppColors.divider,
    splashColor: AppColors.coral.withValues(alpha: 0.08),
    highlightColor: AppColors.coral.withValues(alpha: 0.05),
    textTheme: GoogleFonts.interTextTheme().apply(
      bodyColor: AppColors.ink,
      displayColor: AppColors.ink,
    ),
  );

  return base.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.bg,
      surfaceTintColor: Colors.transparent,
      foregroundColor: AppColors.ink,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: AppText.h2,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: Sp.x5, vertical: Sp.x4),
      hintStyle: AppText.body.copyWith(color: AppColors.inkMuted),
      labelStyle: AppText.bodySoft,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(R.cardSm),
        borderSide: const BorderSide(color: AppColors.divider),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(R.cardSm),
        borderSide: const BorderSide(color: AppColors.divider),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(R.cardSm),
        borderSide: const BorderSide(color: AppColors.coral, width: 2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.coral,
        foregroundColor: Colors.white,
        disabledBackgroundColor: AppColors.inkMuted.withValues(alpha: 0.35),
        minimumSize: const Size(0, 56),
        elevation: 0,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.pill)),
        textStyle: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.ink,
        minimumSize: const Size(0, 56),
        side: const BorderSide(color: AppColors.divider, width: 1.5),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.pill)),
        textStyle: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.coralDeep,
        textStyle: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.ink,
      contentTextStyle: GoogleFonts.inter(color: AppColors.onNight),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.chip)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(R.card)),
      ),
    ),
  );
}
