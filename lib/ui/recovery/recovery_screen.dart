// Recovery detail — the readiness score broken into resting HR, sleep, and
// quality. Not HRV-based.

import 'package:flutter/material.dart';

import '../../models/payloads.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';
import '../kit/charts.dart';

class RecoveryScreen extends StatelessWidget {
  final num? readiness;
  final double confidence;
  final List<CoachContributor> contributors;
  const RecoveryScreen({
    super.key,
    required this.readiness,
    required this.confidence,
    required this.contributors,
  });

  @override
  Widget build(BuildContext context) {
    final r = readiness;
    final t = r == null ? double.nan : (r / 100).clamp(0.0, 1.0).toDouble();
    final color = t.isNaN ? AppColors.inkMuted : AppColors.scoreColor(t);
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: Sp.screen),
          children: [
            const SizedBox(height: Sp.x4),
            Row(children: [
              RoundIconButton(Ic.arrowLeft, onTap: () => Navigator.maybePop(context)),
              const SizedBox(width: Sp.x3),
              Text('Recovery', style: AppText.h1),
            ]),
            const SizedBox(height: Sp.x5),

            // Hero ring.
            GlowCard(
              padding: const EdgeInsets.symmetric(vertical: Sp.x7, horizontal: Sp.x5),
              child: Center(
                child: RingStat(
                  t: t, color: color, size: 196, stroke: 16,
                  center: Column(mainAxisSize: MainAxisSize.min, children: [
                    if (r == null) metricDash(44)
                    else Text(r.round().toString(),
                        style: AppText.display.copyWith(color: color)),
                    const SizedBox(height: Sp.x2),
                    Text('READINESS', style: AppText.overline),
                  ]),
                ),
              ),
            ),
            const SizedBox(height: Sp.x3),
            Row(children: [
              const AppIcon(Ic.info, size: 14, color: AppColors.inkMuted),
              const SizedBox(width: Sp.x2),
              Expanded(child: Text(
                'Estimated — not HRV-based. This firmware does not expose '
                'beat-to-beat intervals, so recovery is derived from resting HR, '
                'sleep and consistency.', style: AppText.captionMuted)),
            ]),
            const SizedBox(height: Sp.x6),

            SectionHeader('What shaped it'),
            if (contributors.isEmpty)
              ProCard(child: Text('Not enough data yet to break this down.',
                  style: AppText.bodySoft))
            else
              for (final c in contributors) ...[
                _contributor(c),
                const SizedBox(height: Sp.x3),
              ],
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _contributor(CoachContributor c) {
    // impact is signed points; negative = cost. Magnitude → bar width (max ~50).
    final cost = c.impact < -0.5;
    final color = cost ? AppColors.bad : AppColors.good;
    final mag = (c.impact.abs() / 50).clamp(0.0, 1.0);
    return ProCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(c.label, style: AppText.title)),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: Sp.x2, vertical: 3),
            decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(R.pill)),
            child: Text(
              '${c.impact >= 0 ? '+' : '−'}${c.impact.abs().toStringAsFixed(0)} pts',
              style: AppText.caption.copyWith(color: color, fontWeight: FontWeight.w700),
            ),
          ),
        ]),
        const SizedBox(height: Sp.x3),
        // impact bar (centered baseline: cost left/red, support right/green).
        ClipRRect(
          borderRadius: BorderRadius.circular(R.pill),
          child: LinearProgressIndicator(
            value: mag,
            minHeight: 7,
            backgroundColor: AppColors.surfaceAlt,
            valueColor: AlwaysStoppedAnimation(color),
          ),
        ),
        const SizedBox(height: Sp.x3),
        Row(children: [
          if (c.value != null)
            Text(_fmt(c.key, c.value!), style: AppText.label),
          if (c.baseline != null) ...[
            const SizedBox(width: Sp.x2),
            Text('vs ${_fmt(c.key, c.baseline!)} baseline', style: AppText.captionMuted),
          ],
        ]),
        const SizedBox(height: Sp.x2),
        Text(c.note, style: AppText.bodySoft),
      ]),
    );
  }

  String _fmt(String key, num v) {
    switch (key) {
      case 'rhr':
        return '${v.round()} bpm';
      case 'sleep_debt':
        return '${(v / 60).floor()}h ${(v % 60).round()}m';
      case 'sleep_quality':
        return '${v.round()}%';
      default:
        return v.toString();
    }
  }
}
