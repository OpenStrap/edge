// OpenStrap theme — Space Grotesk display + Inter body, ember-coral on paper
// (day) or char (night). `AppText` is the type scale; numbers use Space Grotesk
// with tabular figures, body/labels use Inter. Text colours resolve through the
// live `AppColors` getters, so the type scale follows the active mode for free.
//
// `buildOpenStrapTheme(palette)` builds a full ThemeData from an explicit
// [Palette] (not the live getters) so the light + dark ThemeData objects are
// each internally consistent regardless of which mode is currently active.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'tokens.dart';

/// Type scale. Display + numerics → Space Grotesk; body/labels → Inter.
/// Colours come from the live [AppColors] getters → they track the active mode.
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

/// Build the full theme from an explicit [Palette] so light/dark are each
/// self-consistent. Call with [kLightPalette] / [kDarkPalette].
ThemeData buildOpenStrapTheme(Palette p) {
  final scheme = ColorScheme.fromSeed(
    seedColor: p.coral,
    brightness: p.brightness,
  ).copyWith(
    surface: p.surface,
    onSurface: p.ink,
    primary: p.coral,
    onPrimary: Colors.white,
    secondary: p.coralDeep,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: p.brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.bg,
    dividerColor: p.divider,
    splashColor: p.coral.withValues(alpha: 0.08),
    highlightColor: p.coral.withValues(alpha: 0.05),
    textTheme: GoogleFonts.interTextTheme().apply(
      bodyColor: p.ink,
      displayColor: p.ink,
    ),
  );

  return base.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: p.bg,
      surfaceTintColor: Colors.transparent,
      foregroundColor: p.ink,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: GoogleFonts.spaceGrotesk(
          fontSize: 20, fontWeight: FontWeight.w700, height: 1.1,
          letterSpacing: -0.3, color: p.ink),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surface,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: Sp.x5, vertical: Sp.x4),
      hintStyle: GoogleFonts.inter(
          fontSize: 14.5, fontWeight: FontWeight.w400, color: p.inkMuted),
      labelStyle: GoogleFonts.inter(
          fontSize: 14.5, fontWeight: FontWeight.w400, color: p.inkSoft),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(R.cardSm),
        borderSide: BorderSide(color: p.divider),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(R.cardSm),
        borderSide: BorderSide(color: p.divider),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(R.cardSm),
        borderSide: BorderSide(color: p.coral, width: 2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.coral,
        foregroundColor: Colors.white,
        disabledBackgroundColor: p.inkMuted.withValues(alpha: 0.35),
        minimumSize: const Size(0, 56),
        elevation: 0,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.pill)),
        textStyle: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.ink,
        minimumSize: const Size(0, 56),
        side: BorderSide(color: p.divider, width: 1.5),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.pill)),
        textStyle: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.coralDeep,
        textStyle: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.isDark ? p.surfaceAlt : AppColors.night,
      contentTextStyle: GoogleFonts.inter(color: AppColors.onNight),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.chip)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(R.card)),
      ),
    ),
  );
}
