// Step calibration — a short guided open-road walk that teaches the band YOUR
// walking signature (real 100 Hz pedometer → personal cadence + refEnmo). Once
// calibrated, the 1 Hz all-day step estimate is anchored to you instead of a
// guess. 1 Hz can't count steps directly (Nyquist); this is what makes the
// estimate trustworthy.
//
// Presentation: design-system language (ArcGauge progress, StateCard-style
// finish, themed CTA). The calibration start/finish/cancel logic is untouched.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../design/design.dart';

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
    if (!mounted) return;
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
    if (cadence == null) {
      // used to just silently fall through here - gauge would reset with
      // nothing telling the user their walk didn't save. reusing the same
      // _error/StateCard the start-failure path already has, "try again"
      // re-arms a fresh walk which is the right recovery either way.
      setState(() {
        _saving = false;
        _error = "That walk wasn't steady enough to learn from — try again "
            'on flatter, less crowded ground.';
      });
      return;
    }
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

    return AppScaffold(
      title: 'Calibrate steps',
      subtitle: 'A short walk teaches your stride',
      actions: [
        const InfoDot(
          title: 'Why calibrate',
          body:
              'A brief walk with the app open lets the band\'s real pedometer '
              'learn your personal cadence, which anchors the all-day step '
              'estimate to you.',
          bullets: [
            'Walk on flat, open ground at your normal pace.',
            'Keep the phone on you and the app open.',
            'Avoid stairs, crowds and stops.',
          ],
        ),
      ],
      children: [
        if (_error != null)
          StateCard(
            icon: OsIcon.run,
            title: "Couldn't start calibration",
            message: _error!,
            actionLabel: 'Try again',
            onAction: () {
              setState(() => _error = null);
              _start();
            },
          )
        else if (done)
          _doneCard()
        else ...[
          const SizedBox(height: Sp.x4),
          Center(
            child: RepaintBoundary(
              child: ArcGauge(
                value: t,
                color: DomainAccent.steps,
                size: 200,
                stroke: 16,
                sweepFraction: 0.75,
                animate: false, // live-driven — no reveal sweep fighting updates
                center: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('$steps', style: AppText.metric.copyWith(fontSize: 44)),
                  const SizedBox(height: 2),
                  Text('OF $_target',
                      style:
                          AppText.overline.copyWith(color: AppColors.inkMuted)),
                ]),
              ),
            ),
          ).dsEnter(),
          const SizedBox(height: Sp.x3),
          Center(
            child: ready
                ? const StatusChip('Ready to save', tone: ChipTone.positive)
                : Text(_started ? 'Keep walking…' : 'Starting…',
                    style: AppText.label.copyWith(color: AppColors.inkSoft)),
          ),
          const SizedBox(height: Sp.x6),
          SurfaceCard(
            entranceIndex: 1,
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const TileHeader('How to calibrate'),
                  const SizedBox(height: Sp.x3),
                  Text(
                      'Walk on flat, open ground at your normal pace with the '
                      'app open. We count ~$_target real steps to learn your '
                      'stride and cadence.',
                      style: AppText.bodySoft),
                ]),
          ),
          const SizedBox(height: Sp.x6),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: ready && !_saving ? _save : null,
              child: _saving
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.4, color: Colors.white))
                  : const Text('Save calibration'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _doneCard() => SurfaceCard(
        level: 2,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.all(Sp.x3),
              decoration: BoxDecoration(
                color: AppColors.positiveSoft,
                shape: BoxShape.circle,
              ),
              child: AppIcon(OsIcon.check, size: 22, color: AppColors.positive),
            ),
            const SizedBox(width: Sp.x3),
            Text('Calibrated', style: AppText.h2),
          ]),
          const SizedBox(height: Sp.x4),
          BigStat(
            value: _learnedCadence!.toStringAsFixed(0),
            unit: 'steps/min',
            label: 'Your cadence',
            caption: 'Sharper every time you walk with the app open',
          ),
          const SizedBox(height: Sp.x5),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('Done'),
            ),
          ),
        ]),
      ).dsCelebrate();
}
