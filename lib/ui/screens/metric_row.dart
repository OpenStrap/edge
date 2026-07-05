// MetricRow + metric dictionary — the numbers-first building block for metric
// detail lists on the design language: icon chip + label, a big tabular value,
// and the "what this is" copy behind a quiet (i) InfoSheet instead of a
// paragraph under every row (glanceable first, explanations on demand).
// Group several in a MetricGroup (one SurfaceCard, hairline dividers).

import 'package:flutter/material.dart';

import '../design/design.dart';

/// One-line, honest explanation per metric key. Lives behind the (i) so users
/// can learn what they're looking at without the screen reading like a manual.
const Map<String, String> kMetricInfo = {
  'recovery': "How recovered you are — tonight's HRV vs your own baseline.",
  'hrv':
      'Beat-to-beat variability in sleep. Higher usually means better recovery.',
  'rmssd':
      'Beat-to-beat variability in sleep. Higher usually means better recovery.',
  'sdnn': 'Overall heart-rate variability across the night.',
  'lf_hf': 'Balance of stress-related (LF) vs rest (HF) activity.',
  'resting_hr': 'Your lowest heart rate while asleep — a core fitness marker.',
  'stress': 'Sympathetic activation read from your HRV (Baevsky index).',
  'strain': 'Cardiovascular load for the day, on a 0–21 scale.',
  'load': 'Recent (7d) vs habitual (28d) load. 0.8–1.3 is the sweet spot.',
  'fitness': 'Direction of your fitness from resting-HR and recovery trends.',
  'calories': 'Active energy burned, estimated from your heart rate.',
  'steps': 'Estimated steps from wrist motion.',
  'sleep': 'Time actually asleep last night.',
  'efficiency': 'Share of time in bed actually spent asleep.',
  'regularity': 'How consistent your sleep timing is, 0–100.',
  // 4-class wrist staging (estimate): Awake / Light / Deep / REM. Light & Deep
  // split NREM via heart rate + motion (no EEG); Deep is a low-confidence overlay.
  'light': 'Lighter non-REM sleep — the bulk of the night.',
  'deep':
      'Deep (slow-wave) non-REM — the body’s most restorative sleep. '
      'A low-confidence wrist estimate.',
  'nrem': 'Core (NREM) — non-REM sleep (Light + Deep combined).',
  'rem': 'Dreaming sleep — mental restoration and memory.',
  'nocturnal_dip':
      'How far your heart rate falls in sleep — a bigger dip is better.',
  'sleeping_hr': 'Average heart rate while you slept.',
  'resp': 'Breaths per minute, derived from heart-rate variability.',
  'spo2':
      'Overnight red/IR oxygen screen. Dips are relative to your own nightly baseline, not an absolute SpO₂%.',
  'skin_temp':
      'Skin temperature vs your personal overnight baseline. Relative (Δ), not an absolute thermometer.',
  'hrr60':
      'How fast your HR drops a minute after peak effort — fitness marker.',
  'illness':
      'A combined resting-HR / HRV / temperature signal that can flag early illness.',
  'debt': 'Sleep you owe from falling short of your need on recent nights.',
  'hrv_cv': 'How steady your nightly HRV is — lower, stable is better.',
  'readiness': 'A blend of HRV recovery and sleep — your day-ahead capacity.',
  'vo2max': 'Estimated aerobic fitness from your max vs resting heart rate.',
  'form': 'Freshness: fitness minus fatigue. Positive means well-rested.',
  'fatigue': 'Acute training load — recent fatigue (Banister).',
  'monotony': 'Sameness of daily strain — very high can raise injury risk.',
  'dip': 'How far your heart rate falls in sleep — a bigger dip is better.',
};

String? infoFor(String key) => kMetricInfo[key];

/// A single metric line: [icon chip] label (i) ........ big value unit [›]
/// The explanation opens in an InfoSheet from the (i) — the row itself stays
/// a clean number.
class MetricRow extends StatelessWidget {
  final IconData icon;

  /// Illustrated variant — takes precedence over [icon] inside the chip.
  /// Rendered at 38px (the art carries built-in transparent padding, so it
  /// needs a larger canvas than a stroke glyph to read at the same weight);
  /// the chip footprint grows to 40px vs the glyph chip's 35px.
  final OsIcon? osIcon;
  final Color? accent;
  final String label;
  final String? info;
  final String value;
  final String? unit;
  final Widget? valueTag; // e.g. a Tag chip beside the value
  final VoidCallback? onTap;
  const MetricRow({
    super.key,
    required this.icon,
    this.osIcon,
    required this.label,
    required this.value,
    this.info,
    this.unit,
    this.accent,
    this.valueTag,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = this.accent ?? AppColors.coral;
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            padding: EdgeInsets.all(osIcon != null ? 1 : 9),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(R.chip),
            ),
            child: osIcon != null
                ? OsAppIcon(osIcon!, size: 38)
                : AppIcon(icon, size: 17, color: accent),
          ),
          const SizedBox(width: Sp.x3),
          Flexible(
            child: Text(
              label,
              style: AppText.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (info != null)
            InfoDot(title: label, body: info)
          else
            const SizedBox(width: Sp.x3),
          const Spacer(),
          Flexible(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Flexible(
                  child: Text(
                    value,
                    style: AppText.metricSm.copyWith(fontSize: 19),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                  ),
                ),
                if (unit != null) ...[
                  const SizedBox(width: 3),
                  Text(unit!,
                      style: AppText.caption.copyWith(
                        color: AppColors.inkSoft,
                        fontWeight: FontWeight.w700,
                      )),
                ],
                if (valueTag != null) ...[
                  const SizedBox(width: Sp.x2),
                  valueTag!,
                ],
                if (onTap != null) ...[
                  const SizedBox(width: Sp.x2),
                  AppIcon(Ic.arrowRight, size: 16, color: AppColors.inkMuted),
                ],
              ],
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return row;
    return Pressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(R.cardSm),
      child: row,
    );
  }
}

/// A group of MetricRows in one card with hairline dividers between them.
class MetricGroup extends StatelessWidget {
  final List<Widget> rows;
  const MetricGroup(this.rows, {super.key});
  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      children.add(rows[i]);
      if (i < rows.length - 1) {
        children.add(
          Divider(height: 1, thickness: 1, color: AppColors.divider),
        );
      }
    }
    return SurfaceCard(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x2),
      child: Column(children: children),
    );
  }
}
