// Coach — the day's strain target and ranked suggestions. Computed on the server.

import 'package:flutter/material.dart';

import '../../models/payloads.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';

class CoachScreen extends StatelessWidget {
  final CoachData coach;
  const CoachScreen({super.key, required this.coach});

  // Severity → colour: 3 urgent, 2 caution, 1 nudge, 0 affirming.
  Color _sevColor(int s) => switch (s) {
        3 => AppColors.bad,
        2 => AppColors.warn,
        1 => AppColors.coral,
        _ => AppColors.good,
      };
  IconData _catIcon(String c) => switch (c) {
        'recovery' => Ic.recovery,
        'sleep' => Ic.moon,
        'load' => Ic.strain,
        'health' => Ic.heart,
        _ => Ic.run,
      };

  @override
  Widget build(BuildContext context) {
    final tgt = coach.strainTarget;
    final plan = coach.plan;
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
              Text('Your plan', style: AppText.h1),
            ]),
            const SizedBox(height: Sp.x5),

            // Narrative.
            if (coach.summary.isNotEmpty)
              GlowCard(
                child: Row(children: [
                  AppIcon(Ic.info, size: 20, color: AppColors.coralDeep),
                  const SizedBox(width: Sp.x3),
                  Expanded(child: Text(coach.summary, style: AppText.title)),
                ]),
              ),
            const SizedBox(height: Sp.x4),

            // Strain target.
            if (tgt != null) _strainTarget(tgt),
            if (tgt != null) const SizedBox(height: Sp.x6),

            SectionHeader('What to do today'),
            if (plan.isEmpty)
              ProCard(
                child: Row(children: [
                  AppIcon(Ic.check, size: 22, color: AppColors.good),
                  const SizedBox(width: Sp.x3),
                  Expanded(
                      child: Text('Nothing flagged — carry on with your day.',
                          style: AppText.bodySoft)),
                ]),
              )
            else
              for (final s in plan) ...[
                _suggestion(s),
                const SizedBox(height: Sp.x3),
              ],

            const SizedBox(height: Sp.x4),
            Row(children: [
              AppIcon(Ic.shield, size: 14, color: AppColors.inkMuted),
              const SizedBox(width: Sp.x2),
              Expanded(
                child: Text(
                  'Built from your own data with simple rules. '
                  'Every suggestion shows why it fired.',
                  style: AppText.captionMuted,
                ),
              ),
            ]),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _strainTarget(({double value, double low, double high, String rationale}) t) {
    return ProCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          AppIcon(Ic.strain, size: 19, color: AppColors.coral),
          const SizedBox(width: Sp.x2),
          Text("Today's strain target", style: AppText.h2),
        ]),
        const SizedBox(height: Sp.x4),
        Row(crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic, children: [
          Text(t.value.toStringAsFixed(1), style: AppText.display.copyWith(color: AppColors.coral)),
          const SizedBox(width: Sp.x2),
          Padding(
            padding: const EdgeInsets.only(bottom: Sp.x2),
            child: Text('aim ${t.low.toStringAsFixed(0)}–${t.high.toStringAsFixed(0)} of 21',
                style: AppText.caption.copyWith(color: AppColors.inkMuted)),
          ),
        ]),
        const SizedBox(height: Sp.x3),
        // Target band on a 0..21 track.
        LayoutBuilder(builder: (context, c) {
          final w = c.maxWidth;
          return SizedBox(
            height: 10,
            child: Stack(children: [
              Container(decoration: BoxDecoration(
                  color: AppColors.surfaceAlt, borderRadius: BorderRadius.circular(R.pill))),
              Positioned(
                left: (t.low / 21) * w,
                width: ((t.high - t.low) / 21) * w,
                top: 0, bottom: 0,
                child: Container(decoration: BoxDecoration(
                    color: AppColors.coral, borderRadius: BorderRadius.circular(R.pill))),
              ),
            ]),
          );
        }),
        const SizedBox(height: Sp.x3),
        Text(t.rationale, style: AppText.caption),
      ]),
    );
  }

  Widget _suggestion(CoachSuggestion s) {
    final c = _sevColor(s.severity);
    return ProCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
                color: c.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(R.chip)),
            child: AppIcon(_catIcon(s.category), size: 18, color: c),
          ),
          const SizedBox(width: Sp.x3),
          Expanded(child: Text(s.title, style: AppText.title)),
        ]),
        const SizedBox(height: Sp.x3),
        Text(s.body, style: AppText.bodySoft),
        if (s.target != null) ...[
          const SizedBox(height: Sp.x3),
          Row(children: [
            AppIcon(Ic.strain, size: 15, color: AppColors.coralDeep),
            const SizedBox(width: 6),
            Text(s.target!, style: AppText.label.copyWith(color: AppColors.coralDeep)),
          ]),
        ],
        if (s.why.isNotEmpty) ...[
          const SizedBox(height: Sp.x4),
          Wrap(spacing: Sp.x2, runSpacing: Sp.x2, children: [
            for (final w in s.why) _whyChip(w),
          ]),
        ],
      ]),
    );
  }

  Widget _whyChip(({String label, String value, String? detail}) w) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: 6),
      decoration: BoxDecoration(
          color: AppColors.surfaceAlt, borderRadius: BorderRadius.circular(R.chip)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text('${w.label}: ', style: AppText.caption),
        Text(w.value, style: AppText.caption.copyWith(
            color: AppColors.ink, fontWeight: FontWeight.w700)),
        if (w.detail != null && w.detail!.isNotEmpty)
          Text('  ${w.detail}', style: AppText.captionMuted),
      ]),
    );
  }
}
