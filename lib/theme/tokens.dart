// Design tokens — OpenStrap v2 "Ember on Paper".
// Warm off-white surfaces, near-black ink, a single confident coral accent.
// Big tabular numbers (Space Grotesk) over clean body (Inter) — see theme.dart.
// The honesty system (confidence dots, est./relative/beta labels) is preserved.

import 'package:flutter/material.dart';

/// Palette — warm paper + coral.
class AppColors {
  AppColors._();

  // Surfaces.
  static const bg = Color(0xFFF4F1EC); // warm paper background
  static const surface = Color(0xFFFFFFFF); // cards
  static const surfaceAlt = Color(0xFFECE7DF); // inset / skeleton base
  static const surfaceSunk = Color(0xFFEDE9E1); // subtle wells
  static const cool = Color(0xFFE7EBF5); // cool secondary section (ref #3 blue)
  static const coolInk = Color(0xFF2B3350); // ink on the cool surface
  static const divider = Color(0xFFE6E0D6);

  // Ink.
  static const ink = Color(0xFF16130F); // near-black, warm
  static const inkSoft = Color(0xFF6B6157); // secondary
  static const inkMuted = Color(0xFFA59C90); // tertiary / placeholders

  // Dark hero surfaces (device card, splash overlays).
  static const night = Color(0xFF181613);
  static const nightAlt = Color(0xFF24211D);
  static const onNight = Color(0xFFF4F1EC);
  static const onNightSoft = Color(0xFFA8A096);

  // Accent — ember coral.
  static const coral = Color(0xFFFF5A36);
  static const coralDeep = Color(0xFFE8431F);
  static const coralSoft = Color(0xFFFFE7DF); // tint fill
  static const coralInk = Color(0xFF7A2A16); // ink on coralSoft

  // Status (used sparingly — coral stays the hero).
  static const good = Color(0xFF2BB673);
  static const goodSoft = Color(0xFFDBF3E7);
  static const warn = Color(0xFFF5A623);
  static const warnSoft = Color(0xFFFBEBCF);
  static const bad = Color(0xFFE5484D);
  static const badSoft = Color(0xFFFAE0E0);

  // Confidence dot.
  static const confHigh = good;
  static const confMid = warn;
  static const confLow = Color(0xFFC9C0B4);

  // Load (ACWR) bands.
  static const loadDetraining = Color(0xFF7CA8F0);
  static const loadOptimal = good;
  static const loadCaution = warn;
  static const loadHigh = bad;

  /// Coral→deep-coral glow gradient pair.
  static const glow1 = Color(0xFFFF7A4D);
  static const glow2 = Color(0xFFFF3D1F);

  /// Color band for a normalized 0..1 score. Coral-forward: low scores trend
  /// deep, high scores vivid; green reserved for genuinely strong.
  static Color scoreColor(double t) {
    if (t.isNaN) return confLow;
    if (t >= 0.75) return good;
    if (t >= 0.45) return coral;
    return coralDeep;
  }

  static Color confidenceColor(double c) {
    if (c >= 0.75) return confHigh;
    if (c >= 0.4) return confMid;
    return confLow;
  }
}

/// Spacing — 4-pt grid.
class Sp {
  Sp._();
  static const x1 = 4.0;
  static const x2 = 8.0;
  static const x3 = 12.0;
  static const x4 = 16.0;
  static const x5 = 20.0;
  static const x6 = 24.0;
  static const x7 = 28.0;
  static const x8 = 32.0;
  static const x10 = 40.0;
  static const screen = 20.0; // generous side gutter
}

/// Radii — soft, generous (modern rounded cards).
class R {
  R._();
  static const card = 28.0;
  static const cardSm = 20.0;
  static const chip = 14.0;
  static const pill = 999.0;
}

/// Soft warm elevation. Light theme leans on gentle shadow, not borders.
class Shadows {
  Shadows._();
  static const card = [
    BoxShadow(color: Color(0x14201A12), blurRadius: 24, offset: Offset(0, 10)),
    BoxShadow(color: Color(0x0A201A12), blurRadius: 3, offset: Offset(0, 1)),
  ];
  static const lift = [
    BoxShadow(color: Color(0x1F201A12), blurRadius: 32, offset: Offset(0, 16)),
  ];
  static const coral = [
    BoxShadow(color: Color(0x40FF5A36), blurRadius: 28, offset: Offset(0, 12)),
  ];
}

/// Motion.
class Motion {
  Motion._();
  static const fast = Duration(milliseconds: 180);
  static const med = Duration(milliseconds: 320);
  static const slow = Duration(milliseconds: 520);
  static const ring = Duration(milliseconds: 1000);
  static const curve = Curves.easeOutCubic;
  static const emphatic = Curves.easeOutQuint;
}
