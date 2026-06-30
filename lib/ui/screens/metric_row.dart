// MetricRow + metric dictionary — the polished, breathing building block for every metric
// detail. Icon chip + label + a one-line "what this is" + value, with real
// padding. Group several in a MetricGroup (one ProCard, hairline dividers). This is
// what makes the new screens read like the hand-written ones instead of flat lists.

import 'package:flutter/material.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';

/// One-line, honest explanation per metric key. Shown under the label so users
/// learn what they're looking at without leaving the screen.
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

/// A single metric line: [icon chip] label + description ........ value unit [›]
class MetricRow extends StatelessWidget {
  final IconData icon;
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
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: Sp.x3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top line: icon chip + label .......... value unit [tag] [›]
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(R.chip),
                ),
                child: AppIcon(icon, size: 17, color: accent),
              ),
              const SizedBox(width: Sp.x3),

              Expanded(
                child: Text(
                  label,
                  style: AppText.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),

              const SizedBox(width: Sp.x3),

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
                      Text(unit!, style: AppText.caption),
                    ],
                    if (valueTag != null) ...[
                      const SizedBox(width: Sp.x2),
                      valueTag!,
                    ],
                    if (onTap != null) ...[
                      const SizedBox(width: Sp.x2),
                      AppIcon(
                        Ic.arrowRight,
                        size: 16,
                        color: AppColors.inkMuted,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          // Description on its OWN full-width line (indented under the chip) so it
          // never gets squeezed/cut by the value column.
          if (info != null) ...[
            const SizedBox(height: Sp.x2),
            Padding(
              padding: const EdgeInsets.only(left: 38), // chip width + gap
              child: Text(info!, style: AppText.captionMuted),
            ),
          ],
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(
      borderRadius: BorderRadius.circular(R.cardSm),
      onTap: onTap,
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
    for (int i = 0; i < rows.length; i++) {
      children.add(rows[i]);
      if (i < rows.length - 1) {
        children.add(
          Divider(height: 1, thickness: 1, color: AppColors.divider),
        );
      }
    }
    return ProCard(child: Column(children: children));
  }
}
