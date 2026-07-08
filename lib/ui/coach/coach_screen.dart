// Coach — the day's strain target and ranked suggestions, on the design
// language: a quiet narrative hero, the strain target as a soft bento tile
// with the aim band, and each suggestion as a clean card whose "why" evidence
// reads as chips. Rule-based and deterministic — the honesty note lives
// behind the (i), not on the board.

import 'package:flutter/material.dart';

import '../../models/payloads.dart';
import '../design/design.dart';

class CoachScreen extends StatelessWidget {
  final CoachData coach;
  const CoachScreen({super.key, required this.coach});

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Your plan',
      subtitle: 'Built from your own data',
      actions: [
        InfoDot(
          title: 'How this plan is made',
          body:
              'Simple, deterministic rules over your own recovery, sleep and '
              'load — no AI, no server. Every suggestion shows the exact '
              'numbers that fired it.',
          methodNote: 'Rule-based · on-device · updates with each sync',
        ),
      ],
      children: [CoachPlanContent(coach: coach), const SizedBox(height: Sp.x8)],
    );
  }
}

/// The pure plan board — testable with a sample /coach payload.
class CoachPlanContent extends StatelessWidget {
  final CoachData coach;
  const CoachPlanContent({super.key, required this.coach});

  // Severity → colour: 3 urgent, 2 caution, 1 nudge, 0 affirming.
  Color _sevColor(int s) => switch (s) {
    3 => AppColors.bad,
    2 => AppColors.warn,
    1 => AppColors.accent,
    _ => AppColors.good,
  };
  /// Illustrated counterpart of [_catIcon] — the severity colour stays on the
  /// chip background (the art itself is never tinted).
  OsIcon _catOsIcon(String c) => switch (c) {
    'recovery' => OsIcon.recovery,
    'sleep' => OsIcon.sleep,
    'load' => OsIcon.bodyStrain,
    'health' => OsIcon.heart,
    _ => OsIcon.workouts,
  };

  @override
  Widget build(BuildContext context) {
    final tgt = coach.strainTarget;
    final plan = coach.plan;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Narrative — the one-line read on the day.
        if (coach.summary.isNotEmpty)
          SurfaceCard(
            level: 2,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(1),
                  decoration: BoxDecoration(
                    color: AppColors.accentSoft,
                    borderRadius: BorderRadius.circular(R.chip),
                  ),
                  child: OsAppIcon(OsIcon.today, size: 34),
                ),
                const SizedBox(width: Sp.x3),
                Expanded(
                  child: Text(
                    coach.summary,
                    style: AppText.title.copyWith(height: 1.35),
                  ),
                ),
              ],
            ),
          ).dsEnter(index: 0),

        // Strain target — a soft strain-domain tile with the aim band.
        if (tgt != null) ...[
          const SizedBox(height: Sp.x3),
          _StrainTargetTile(t: tgt).dsEnter(index: 1),
        ],

        const SizedBox(height: Sp.x6),
        const SectionHeader('What to do today'),
        if (plan.isEmpty)
          SurfaceCard(
            child: Row(
              children: [
                AppIcon(OsIcon.check, size: 22, color: AppColors.good),
                const SizedBox(width: Sp.x3),
                Expanded(
                  child: Text(
                    'Nothing flagged — carry on with your day.',
                    style: AppText.bodySoft,
                  ),
                ),
              ],
            ),
          ).dsEnter(index: 2)
        else
          for (var i = 0; i < plan.length; i++) ...[
            _SuggestionCard(
              s: plan[i],
              color: _sevColor(plan[i].severity),
              icon: _catOsIcon(plan[i].category),
            ).dsEnter(index: 2 + i),
            if (i != plan.length - 1) const SizedBox(height: Sp.x3),
          ],
      ],
    );
  }
}

class _StrainTargetTile extends StatelessWidget {
  final ({double value, double low, double high, String rationale}) t;
  const _StrainTargetTile({required this.t});

  @override
  Widget build(BuildContext context) {
    final accent = DomainAccent.strain;
    return BentoTile(
      tone: BentoTone.soft,
      accent: accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          TileHeader(
            "Today's strain target",
            trailing: InfoDot(
              title: 'Strain target',
              body:
                  'How hard to go today, on the 0–21 strain scale, given your '
                  'recovery and recent load. The band is the aim zone — the '
                  'number is its centre.',
              methodNote: t.rationale.isEmpty ? null : t.rationale,
            ),
          ),
          const SizedBox(height: Sp.x2),
          BigStat(
            value: t.value.toStringAsFixed(1),
            unit: 'of 21',
            caption:
                'aim ${t.low.toStringAsFixed(0)}–${t.high.toStringAsFixed(0)}',
            captionAccent: true,
          ),
          const SizedBox(height: Sp.x3),
          // The aim band on a 0..21 track.
          LayoutBuilder(
            builder: (context, c) {
              final w = c.maxWidth;
              return ClipRRect(
                borderRadius: BorderRadius.circular(R.pill),
                child: SizedBox(
                  height: 8,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: ColoredBox(color: AppColors.surfaceAlt),
                      ),
                      Positioned(
                        left: (t.low / 21).clamp(0.0, 1.0) * w,
                        width: ((t.high - t.low) / 21).clamp(0.0, 1.0) * w,
                        top: 0,
                        bottom: 0,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: accent,
                            borderRadius: BorderRadius.circular(R.pill),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  final CoachSuggestion s;
  final Color color;
  final OsIcon icon;
  const _SuggestionCard({
    required this.s,
    required this.color,
    required this.icon,
    });

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      padding: const EdgeInsets.all(Sp.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: EdgeInsets.all(Sp.x2),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(R.chip),
                ),
                child: OsAppIcon(icon, size: 34),
              ),
              const SizedBox(width: Sp.x3),
              Expanded(child: Text(s.title, style: AppText.title)),
            ],
          ),
          const SizedBox(height: Sp.x3),
          Text(s.body, style: AppText.bodySoft),
          if (s.target != null) ...[
            const SizedBox(height: Sp.x3),
            StatusChip(s.target!, tone: ChipTone.accent),
          ],
          if (s.why.isNotEmpty) ...[
            const SizedBox(height: Sp.x3),
            Wrap(
              spacing: Sp.x2,
              runSpacing: Sp.x2,
              children: [
                for (final w in s.why)
                  StatusChip(
                    '${w.label} ${w.value}'
                    '${(w.detail?.isNotEmpty ?? false) ? ' · ${w.detail}' : ''}',
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
