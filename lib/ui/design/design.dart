// OpenStrap design system — ONE import for the screen rollout.
//
//   import '../design/design.dart';
//
// New primitives live in this directory; proven kit components (honesty tags,
// skeletons, state cards, delta chips, icons, section headers…) are re-exported
// so `design.dart` is the single vocabulary a migrated screen needs. Tokens
// (colors/type/spacing/elevation/motion) come from theme/tokens.dart +
// theme/theme.dart as always.
//
// Review every component on-device: Profile → Developer → Design gallery.

// ── New design-system primitives ──
export 'ai_hero.dart';
export 'app_scaffold.dart';
export 'arc_gauge.dart';
export 'bento.dart';
export 'big_stat.dart';
export 'controls.dart';
export 'domains.dart';
export 'hypnogram.dart';
export 'info_sheet.dart';
export 'metric_card.dart';
export 'motion.dart';
export 'nav_pill.dart';
export 'orbit_score.dart';
export 'pressable.dart';
export 'radial_heatmap.dart';
export 'recap_card.dart';
export 'ring_week.dart';
export 'rows.dart';
export 'spark.dart';
export 'state_chips.dart';
export 'surface.dart';

// ── Carried forward from the kit (reused/upgraded, not duplicated) ──
export '../kit/kit.dart';
export '../kit/charts.dart';
export '../kit/skeleton.dart';
export '../kit/state_card.dart';

// ── Tokens + type, so one import themes a screen ──
export '../../theme/theme.dart';
export '../../theme/tokens.dart';
