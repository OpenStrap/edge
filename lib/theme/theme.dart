// OpenStrap theme — ONE type family (Manrope), ember-coral on paper (day) or
// char (night). `AppText` is the type scale; every numeric/metric style carries
// tabular figures so big numbers align and count-ups don't jitter. Text colours
// resolve through the live `AppColors` getters, so the type scale follows the
// active mode for free.
//
// Why Manrope: a single family must do three jobs here — hero numerals with
// real presence (w800, tight tracking), dense small labels that stay legible,
// and body copy that reads effortlessly. Manrope covers 200–800 with true
// tabular figures, so the whole app speaks one voice (the old Space Grotesk +
// Inter pairing is consolidated away).
//
// `buildOpenStrapTheme(palette)` builds a full ThemeData from an explicit
// [Palette] (not the live getters) so the light + dark ThemeData objects are
// each internally consistent regardless of which mode is currently active.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'page_transitions.dart';
import 'tokens.dart';

/// Type scale — one family (Manrope). Numerics carry tabular figures.
/// Colours come from the live [AppColors] getters → they track the active mode.
class AppText {
  AppText._();

  static const _tnum = [FontFeature.tabularFigures()];

  // ── Display / numerics — heavy, tight, tabular ──
  static TextStyle get hero => GoogleFonts.manrope(
    fontSize: 64,
    fontWeight: FontWeight.w800,
    height: 0.98,
    letterSpacing: -2.4,
    color: AppColors.ink,
    fontFeatures: _tnum,
  );
  static TextStyle get display => GoogleFonts.manrope(
    fontSize: 44,
    fontWeight: FontWeight.w800,
    height: 1.0,
    letterSpacing: -1.4,
    color: AppColors.ink,
    fontFeatures: _tnum,
  );
  static TextStyle get metric => GoogleFonts.manrope(
    fontSize: 30,
    fontWeight: FontWeight.w800,
    height: 1.0,
    letterSpacing: -0.7,
    color: AppColors.ink,
    fontFeatures: _tnum,
  );
  static TextStyle get metricSm => GoogleFonts.manrope(
    fontSize: 22,
    fontWeight: FontWeight.w800,
    height: 1.0,
    letterSpacing: -0.35,
    color: AppColors.ink,
    fontFeatures: _tnum,
  );

  // ── Headings ──
  static TextStyle get h1 => GoogleFonts.manrope(
    fontSize: 28,
    fontWeight: FontWeight.w800,
    height: 1.05,
    letterSpacing: -0.7,
    color: AppColors.ink,
  );
  static TextStyle get h2 => GoogleFonts.manrope(
    fontSize: 20,
    fontWeight: FontWeight.w700,
    height: 1.1,
    letterSpacing: -0.35,
    color: AppColors.ink,
  );

  // ── Body / labels ──
  static TextStyle get title => GoogleFonts.manrope(
    fontSize: 16,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.15,
    color: AppColors.ink,
  );
  static TextStyle get body => GoogleFonts.manrope(
    fontSize: 14.5,
    fontWeight: FontWeight.w500,
    height: 1.45,
    color: AppColors.ink,
  );
  static TextStyle get bodySoft => GoogleFonts.manrope(
    fontSize: 14.5,
    fontWeight: FontWeight.w500,
    height: 1.45,
    color: AppColors.inkSoft,
  );
  static TextStyle get label => GoogleFonts.manrope(
    fontSize: 13,
    fontWeight: FontWeight.w700,
    color: AppColors.inkSoft,
    letterSpacing: 0.1,
  );
  static TextStyle get caption => GoogleFonts.manrope(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    color: AppColors.inkSoft,
  );
  static TextStyle get captionMuted => GoogleFonts.manrope(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    color: AppColors.inkMuted,
  );
  static TextStyle get overline => GoogleFonts.manrope(
    fontSize: 11,
    fontWeight: FontWeight.w800,
    letterSpacing: 1.5,
    color: AppColors.inkMuted,
  );
}

/// Build the full theme from an explicit [Palette] so light/dark are each
/// self-consistent. Call with [kLightPalette] / [kDarkPalette].
ThemeData buildOpenStrapTheme(Palette p) {
  final scheme =
      ColorScheme.fromSeed(
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
    textTheme: GoogleFonts.manropeTextTheme().apply(
      bodyColor: p.ink,
      displayColor: p.ink,
    ),
    // Page transitions live HERE (not in a custom PageRouteBuilder) so pushed
    // routes stay MaterialPageRoutes: iOS keeps the native slide transition
    // AND the interactive edge-swipe-back gesture; Android-likes get the
    // app's shared-axis fade-through. See page_transitions.dart.
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: SharedAxisPageTransitionsBuilder(),
        TargetPlatform.fuchsia: SharedAxisPageTransitionsBuilder(),
        TargetPlatform.linux: SharedAxisPageTransitionsBuilder(),
        TargetPlatform.windows: SharedAxisPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
      },
    ),
  );

  return base.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: p.bg,
      surfaceTintColor: Colors.transparent,
      foregroundColor: p.ink,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: GoogleFonts.manrope(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        height: 1.1,
        letterSpacing: -0.35,
        color: p.ink,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surface,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Sp.x5,
        vertical: Sp.x4,
      ),
      hintStyle: GoogleFonts.manrope(
        fontSize: 14.5,
        fontWeight: FontWeight.w500,
        color: p.inkMuted,
      ),
      labelStyle: GoogleFonts.manrope(
        fontSize: 14.5,
        fontWeight: FontWeight.w500,
        color: p.inkSoft,
      ),
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
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(R.pill),
        ),
        textStyle: GoogleFonts.manrope(
          fontSize: 16,
          fontWeight: FontWeight.w800,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.ink,
        minimumSize: const Size(0, 56),
        side: BorderSide(color: p.divider, width: 1.5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(R.pill),
        ),
        textStyle: GoogleFonts.manrope(
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.coralDeep,
        textStyle: GoogleFonts.manrope(
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.isDark ? p.surfaceAlt : AppColors.night,
      contentTextStyle: GoogleFonts.manrope(color: AppColors.onNight),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(R.chip),
      ),
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
