// Domain accents — one tasteful accent per health domain (the refs' bento
// cards each carry their own hue; the app stops leaning on a single coral for
// everything). Every colour resolves per-mode so both themes stay premium:
// light gets saturated-but-calm tones on paper, dark gets slightly lifted
// versions that read on char without turning neon.
//
// Use `DomainAccent.sleep` etc. wherever a card/visual belongs to a domain;
// keep `AppColors.accent` (ember coral) for brand moments + the heart domain.

import 'package:flutter/widgets.dart';

import '../../theme/tokens.dart';

class DomainAccent {
  DomainAccent._();

  /// Heart / cardio — the brand ember coral.
  static Color get heart => AppColors.coral;

  /// Recovery / readiness — confident green.
  static Color get recovery => AppColors.good;

  /// Sleep — calm indigo (never cold blue; sits well on paper and char).
  static Color get sleep => AppColors.isDark
      ? const Color(0xFF9D8CFF)
      : const Color(0xFF6C5CE7);

  /// Strain / training load — warm amber.
  static Color get strain =>
      AppColors.isDark ? const Color(0xFFF7B53A) : const Color(0xFFE8930C);

  /// Movement / steps — restrained teal.
  static Color get steps =>
      AppColors.isDark ? const Color(0xFF3ECFC0) : const Color(0xFF0E9E92);

  /// Energy / calories — the refs' confident orange card.
  static Color get calories =>
      AppColors.isDark ? const Color(0xFFFF9D57) : const Color(0xFFF97316);

  /// Respiration / oxygen — soft slate blue.
  static Color get oxygen => AppColors.loadDetraining;

  /// Stress / arousal — kept on warn amber-rose.
  static Color get stress =>
      AppColors.isDark ? const Color(0xFFF07A8A) : const Color(0xFFD9526B);

  /// Menstrual cycle — rose-plum (distinct from stress rose and heart coral;
  /// calm on paper, lifted on char).
  static Color get cycle =>
      AppColors.isDark ? const Color(0xFFE08BC0) : const Color(0xFFB2467F);

  /// Deeper plum companion for the cycle domain (ovulation/luteal marks).
  static Color get cyclePlum =>
      AppColors.isDark ? const Color(0xFFB48BE0) : const Color(0xFF7C4A9E);

  /// Sleep-stage palette (Awake / REM / Light / Deep) — one source for every
  /// hypnogram + stage bar. Light keeps the warm tone the app already ships.
  static Color get stageAwake => AppColors.warn;
  static Color get stageRem => sleep;
  static Color get stageLight => kLightStageColor;
  static Color get stageDeep =>
      AppColors.isDark ? const Color(0xFF7B6CD9) : const Color(0xFF4A3EB8);
}
