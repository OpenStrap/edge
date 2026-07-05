// Step goal — set a daily step target and see today's progress against it.
// The goal persists through AppState.updateProfile ('step_goal'); steps shown
// are today's estimate passed in by the caller. Presentation: design-system
// language (ArcGauge, ToggleChip presets, themed CTA); save logic untouched.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/local_repository.dart';
import '../../state/app_state.dart';
import '../design/design.dart';

class StepGoalScreen extends StatefulWidget {
  /// Today's step count (for the progress ring), if known.
  final int? steps;

  /// Current saved goal (null → client default).
  final int? goal;
  const StepGoalScreen({super.key, this.steps, this.goal});

  /// Client-side default when the user hasn't set one (mirrors the backend note).
  static const int defaultGoal = 8000;

  @override
  State<StepGoalScreen> createState() => _StepGoalScreenState();
}

class _StepGoalScreenState extends State<StepGoalScreen> {
  static const _presets = [5000, 8000, 10000, 12000, 15000];
  static const _step = 500;
  static const _min = 1000;
  static const _max = 50000;

  late int _goal;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _goal = (widget.goal ?? StepGoalScreen.defaultGoal).clamp(_min, _max);
  }

  void _set(int g) => setState(() => _goal = g.clamp(_min, _max));

  Future<void> _save() async {
    final app = context.read<AppState>();
    setState(() => _saving = true);
    try {
      // Routed through AppState so the LOCAL profile updates + listeners refresh.
      await app.updateProfile({'step_goal': _goal});
      if (!mounted) return;
      Navigator.of(context).pop(_goal);
    } on RepositoryException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't save goal: ${e.body}")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final steps = widget.steps ?? 0;
    final t = _goal > 0 ? (steps / _goal).clamp(0.0, 1.0).toDouble() : 0.0;
    final reached = steps >= _goal && steps > 0;
    final remaining = (_goal - steps).clamp(0, _goal);

    return AppScaffold(
      title: 'Step goal',
      actions: [
        const InfoDot(
          title: 'Step goal',
          body:
              'Steps are estimated on-device from your band\'s motion. The goal '
              'is just a target — change it any time.',
        ),
      ],
      children: [
        const SizedBox(height: Sp.x4),
        // Progress ring.
        Center(
          child: RepaintBoundary(
            child: ArcGauge(
              value: t,
              color: DomainAccent.steps,
              size: 200,
              stroke: 16,
              sweepFraction: 0.75,
              center: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('$steps', style: AppText.metric.copyWith(fontSize: 44)),
                  const SizedBox(height: 2),
                  Text('OF $_goal',
                      style: AppText.overline
                          .copyWith(color: AppColors.inkMuted)),
                ],
              ),
            ),
          ),
        ).dsEnter(),
        const SizedBox(height: Sp.x3),
        Center(
          child: reached
              ? const StatusChip('Goal reached', tone: ChipTone.positive)
              : Text('$remaining to go',
                  style: AppText.label.copyWith(color: AppColors.inkSoft)),
        ),
        const SizedBox(height: Sp.x6),

        SurfaceCard(
          entranceIndex: 1,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const TileHeader('Daily goal'),
              const SizedBox(height: Sp.x4),
              // Stepper row.
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  RoundIconButton(Ic.down,
                      bg: AppColors.surfaceAlt,
                      onTap: _saving ? null : () => _set(_goal - _step)),
                  Column(
                    children: [
                      Text('$_goal',
                          style: AppText.metric.copyWith(fontSize: 36)),
                      Text('STEPS / DAY',
                          style: AppText.overline
                              .copyWith(color: AppColors.inkMuted)),
                    ],
                  ),
                  RoundIconButton(Ic.up,
                      bg: AppColors.surfaceAlt,
                      onTap: _saving ? null : () => _set(_goal + _step)),
                ],
              ),
              const SizedBox(height: Sp.x4),
              // Presets.
              Wrap(
                spacing: Sp.x2,
                runSpacing: Sp.x2,
                alignment: WrapAlignment.center,
                children: [
                  for (final p in _presets)
                    ToggleChip(
                      '${(p / 1000).toStringAsFixed(p % 1000 == 0 ? 0 : 1)}k',
                      selected: p == _goal,
                      accent: DomainAccent.steps,
                      onTap: _saving ? null : () => _set(p),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: Sp.x6),

        // Save.
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.4, color: Colors.white))
                : const Text('Save goal'),
          ),
        ),
      ],
    );
  }
}
