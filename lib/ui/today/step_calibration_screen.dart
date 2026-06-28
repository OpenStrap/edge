// Step calibration — a short guided open-road walk that teaches the band YOUR
// walking signature (real 100 Hz pedometer → personal cadence + refEnmo). Once
// calibrated, the 1 Hz all-day step estimate is anchored to you instead of a
// guess. 1 Hz can't count steps directly (Nyquist); this is what makes the
// estimate trustworthy.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';
import '../kit/charts.dart';

class StepCalibrationScreen extends StatefulWidget {
  const StepCalibrationScreen({super.key});
  @override
  State<StepCalibrationScreen> createState() => _StepCalibrationScreenState();
}

class _StepCalibrationScreenState extends State<StepCalibrationScreen> {
  // walk target = base + buffer so the AN-2554 confirm-gate settles.
  final int _target =
      AppState.stepCalTargetSteps + AppState.stepCalBuffer; // e.g. 250
  bool _started = false;
  bool _saving = false;
  double? _learnedCadence;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    try {
      await context.read<AppState>().startStepCalibration();
      if (mounted) setState(() => _started = true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final cadence = await context.read<AppState>().finishStepCalibration();
    if (!mounted) return;
    setState(() {
      _saving = false;
      _learnedCadence = cadence;
    });
  }

  @override
  void dispose() {
    // If we leave without saving, stop the stream + drop the partial walk.
    if (_learnedCadence == null) {
      context.read<AppState>().cancelStepCalibration();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final steps = context.select<AppState, int>((a) => a.liveSteps);
    final done = _learnedCadence != null;
    final t = (_target > 0 ? steps / _target : 0.0).clamp(0.0, 1.0).toDouble();
    final ready = steps >= _target;

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
            if (_error != null)
              ProCard(
                child: Text(_error!, style: AppText.captionMuted),
              )
            else if (done)
              _doneCard()
            else ...[
              Center(
                child: RingStat(
                  t: t,
                  color: AppColors.good,
                  size: 196,
                  stroke: 16,
                  center: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text('$steps', style: AppText.metric.copyWith(fontSize: 44)),
                    const SizedBox(height: 2),
                    Text('of $_target steps',
                        style: AppText.caption.copyWith(color: AppColors.inkSoft)),
                  ]),
                ),
              ),
              const SizedBox(height: Sp.x5),
              Center(
                child: ready
                    ? Tag('ready to save', color: AppColors.good)
                    : Text(_started ? 'Keep walking…' : 'Starting…',
                        style: AppText.label.copyWith(color: AppColors.inkSoft)),
              ),
              const SizedBox(height: Sp.x6),
              ProCard(
                child:
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('How to calibrate', style: AppText.label),
                  const SizedBox(height: Sp.x2),
                  Text(
                      'Walk on flat, open ground at your normal pace with the phone '
                      'on you and the app open. We count ~$_target real steps to '
                      'learn your stride + cadence. Avoid stairs, crowds and stops.',
                      style: AppText.captionMuted),
                ]),
              ),
              const SizedBox(height: Sp.x6),
              _saveButton(ready),
            ],
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _doneCard() => ProCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            AppIcon(Ic.run, size: 20, color: AppColors.good),
            const SizedBox(width: Sp.x2),
            Text('Calibrated', style: AppText.h2),
          ]),
          const SizedBox(height: Sp.x3),
          Text(
              'Learned cadence ≈ ${_learnedCadence!.toStringAsFixed(0)} steps/min. '
              'Your all-day step estimate is now anchored to your walk — it will '
              'get sharper each time you walk with the app open.',
              style: AppText.captionMuted),
          const SizedBox(height: Sp.x4),
          _pill('Done', AppColors.coral, () => Navigator.of(context).maybePop()),
        ]),
      );

  Widget _saveButton(bool ready) {
    final enabled = ready && !_saving;
    return _pill(
      _saving ? '' : 'Save calibration',
      enabled ? AppColors.coral : AppColors.inkSoft.withValues(alpha: 0.4),
      enabled ? _save : null,
      busy: _saving,
    );
  }

  Widget _pill(String label, Color color, VoidCallback? onTap, {bool busy = false}) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(R.pill),
      child: InkWell(
        borderRadius: BorderRadius.circular(R.pill),
        onTap: onTap,
        child: Container(
          height: 54,
          alignment: Alignment.center,
          child: busy
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.4, color: AppColors.onNight))
              : Text(label,
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
              Text('Calibrate steps', style: AppText.h1),
              Text('A short walk teaches your stride',
                  style: AppText.caption.copyWith(color: AppColors.inkSoft)),
            ],
          ),
        ),
      ]);
}
