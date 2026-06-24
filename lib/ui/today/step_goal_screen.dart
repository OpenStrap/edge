// Step goal — set a daily step target and see today's progress against it.
// Steps themselves are the authoritative IMU pedometer count (server-side); this
// screen only sets users.step_goal (PATCH /profile) and renders progress.
// "Ember on Paper" design: warm bg, coral/good accent, big tabular numbers.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/local_repository.dart';
import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';
import '../kit/charts.dart';

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

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: Sp.screen),
          children: [
            const SizedBox(height: Sp.x4),
            _topBar(),
            const SizedBox(height: Sp.x6),

            // Progress ring.
            Center(
              child: RingStat(
                t: t,
                color: AppColors.good,
                size: 196,
                stroke: 16,
                center: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('$steps',
                        style: AppText.metric.copyWith(fontSize: 44)),
                    const SizedBox(height: 2),
                    Text('of $_goal steps',
                        style: AppText.caption
                            .copyWith(color: AppColors.inkSoft)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: Sp.x5),
            Center(
              child: reached
                  ? Tag('goal reached', color: AppColors.good)
                  : Text('$remaining to go',
                      style: AppText.label.copyWith(color: AppColors.inkSoft)),
            ),
            const SizedBox(height: Sp.x7),

            const SectionHeader('Daily goal'),
            ProCard(
              child: Column(
                children: [
                  // Stepper row.
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      RoundIconButton(Ic.down,
                          bg: AppColors.surfaceAlt,
                          onTap: _saving ? null : () => _set(_goal - _step)),
                      Column(
                        children: [
                          Text('$_goal', style: AppText.metric.copyWith(fontSize: 36)),
                          Text('steps / day',
                              style: AppText.caption
                                  .copyWith(color: AppColors.inkSoft)),
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
                      for (final p in _presets) _presetChip(p),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: Sp.x6),

            // Save.
            _saveButton(),
            const SizedBox(height: Sp.x4),
            Text(
              'Steps are counted on-device from motion and finalized server-side. '
              'The goal is just a target — change it any time.',
              style: AppText.caption.copyWith(color: AppColors.inkMuted),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _presetChip(int p) {
    final sel = p == _goal;
    return GestureDetector(
      onTap: _saving ? null : () => _set(p),
      child: AnimatedContainer(
        duration: Motion.fast,
        padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x2),
        decoration: BoxDecoration(
          color: sel ? AppColors.ink : AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(R.pill),
        ),
        child: Text(
          '${(p / 1000).toStringAsFixed(p % 1000 == 0 ? 0 : 1)}k',
          style: AppText.label.copyWith(
            color: sel ? AppColors.onNight : AppColors.inkSoft,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _saveButton() {
    return Material(
      color: AppColors.coral,
      borderRadius: BorderRadius.circular(R.pill),
      child: InkWell(
        borderRadius: BorderRadius.circular(R.pill),
        onTap: _saving ? null : _save,
        child: Container(
          height: 54,
          alignment: Alignment.center,
          child: _saving
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.4, color: AppColors.onNight),
                )
              : Text('Save goal',
                  style: AppText.label.copyWith(
                      color: AppColors.onNight, fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }

  Widget _topBar() => Row(children: [
        RoundIconButton(Ic.arrowLeft,
            onTap: () => Navigator.of(context).maybePop()),
        const SizedBox(width: Sp.x3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Step goal', style: AppText.h1),
              Text('Set your daily target',
                  style: AppText.caption.copyWith(color: AppColors.inkSoft)),
            ],
          ),
        ),
      ]);
}
