// Per-user, per-activity calibration of the strap's live 100 Hz pedometer.
//
// WHAT THIS SCREEN IS FOR. The strap counts steps off its own 100 Hz IMU
// (`pedometer()` in analytics), and the count is a residual off on a real wrist
// in ways that depend on the wearer. Analytics asks for exactly this correction
// in its own `StepParams.gain` docstring: "Measure it against ground truth, per
// user, and store it with the user; never bake a population constant back in
// here."
//
// THE WEARER COUNTS, THE BAND DOES NOT. A gait routine cannot end when the band
// reaches the target: `rawSteps` would be the target by construction and every
// wearer would fit a gain of exactly 1.0 forever. So the screen asks the wearer
// to count their own steps and shows the band's live count as FEEDBACK — the gap
// between the two is the measurement they came for.
//
// Household movement is the other family, and the one that pays: at the wrist,
// arm work out-accelerates walking, which is why these devices emit 22-27 false
// steps per minute during dishes and driving (O'Connell 2017). Its reference is
// the PHONE, because nobody counts steps while doing chores, and a pocket-carried
// device is simply a better sensor for this one quantity
// (`lib/health/phone_pedometer.dart`). The correction there comes out LOW — and
// deliberately never zero, because a household routine does contain real steps.
//
// WHAT THIS SCREEN MUST NOT DO. `app_state.dart` records that a previous guided
// step calibration was removed because its only reader had been deleted and it
// "told the user their walk had taught the app something when nothing read the
// result". This one has a reader — `_bankGaitRuns` and the session checkpoint
// both bank through `creditedStepsForRun` — and this screen must not claim a
// correction took effect until that save has actually returned.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../compute/step_calibration_fit.dart';
import '../../data/db.dart';
import '../../health/phone_pedometer.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../screens/metric_detail.dart' show detailLinkRow, detailScaffold;
import '../ui2.dart';

class StepCalibrationScreen extends StatefulWidget {
  const StepCalibrationScreen({super.key});

  @override
  State<StepCalibrationScreen> createState() => _StepCalibrationScreenState();
}

class _StepCalibrationScreenState extends State<StepCalibrationScreen> {
  final Map<StepCategory, LiveStepGainProfile?> _profiles = {};

  /// ONE instance for the screen's lifetime. The ticker runs once a second for
  /// three minutes, and a fresh `PhonePedometer` per tick would mean 180 objects
  /// and 180 platform-channel queries for a value read at most twice a routine.
  final PhonePedometer _pedometer = PhonePedometer();
  CalibrationSession? _session;
  Timer? _ticker;
  DateTime? _routineStart;

  /// The phone sensor's running total when the household routine began, on a
  /// platform that has one. Read after a flush so earlier steps are excluded.
  Future<int?>? _startRaw;

  /// What the last routine produced, in the wearer's words. Never set before a
  /// save has returned: a message is a claim, and an unclaimed one is the exact
  /// failure the previous calibration shipped.
  String? _outcome;

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadProfiles());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _loadProfiles() async {
    for (final c in StepCategory.values) {
      _profiles[c] = await LocalDb.liveStepGainProfile(c);
    }
    if (mounted) setState(() {});
  }

  /// Starting is busy while the phone side is being prepared; a second tap
  /// must not start a second routine on top of it.
  bool _starting = false;

  Future<void> _start(StepCategory category) async {
    if (_starting) return;
    final app = context.read<AppState>();
    _ticker?.cancel();
    setState(() {
      _starting = true;
      _outcome = null;
    });
    final begun = await beginCalibrationRoutine(
      category: category,
      // Ask BEFORE the routine, not after: a household routine refused at the
      // end for a permission the wearer was never asked for blames the wrong
      // thing.
      ensurePhoneAccess: _pedometer.ensureAccess,
      runningTotalPlatform: defaultTargetPlatform == TargetPlatform.android,
      startTotal: _pedometer.flushedTotal,
      bandTotalNow: () => app.liveStrapRawSteps,
      nowMs: () => DateTime.now().millisecondsSinceEpoch,
    );
    if (!mounted) return;
    final l = AppLocalizations.of(context);
    setState(() {
      _starting = false;
      _session = begun.session;
      _routineStart = begun.session == null ? null : DateTime.now();
      _startRaw = Future.value(begun.startTotal);
      _outcome = switch (begun.refusal) {
        null => null,
        RoutineStartRefusal.noPhoneAccess => l?.stepCalNoPhoneAccess ??
            'This routine needs your phone\u2019s step counter, and access '
                'was not granted. It is the reference for household movement.',
        RoutineStartRefusal.phoneNotReady => l?.stepCalPhoneNotReady ??
            'Your phone\u2019s step counter did not answer. Try again in a '
                'moment.',
      };
    });
    if (begun.session != null) {
      _ticker = Timer.periodic(Motion.tick, (_) => _tick());
    }
  }

  void _tick() {
    final s = _session;
    if (!mounted || s == null) return;
    final app = context.read<AppState>();
    s.observe(
      bandTotal: app.liveStrapRawSteps,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    // The household family's reference is the phone. Read it as the routine
    // runs rather than only at the end, so a permission failure surfaces while
    // the wearer is still standing there instead of after three minutes.
    if (s.category.referenceIsPhone) unawaited(_readPhone(s));
    setState(() {});
  }


  /// Sequence of phone reads started. Only the MOST RECENTLY STARTED read may
  /// write a value: on Android a query can outlive the next tick, and without
  /// this the older interval lands last and replaces the newer count.
  int _phoneReadSeq = 0;

  Future<void> _readPhone(CalibrationSession s) async {
    final start = _routineStart;
    if (start == null) return;
    final seq = ++_phoneReadSeq;
    try {
      final steps = await _pedometer.stepsBetween(start, DateTime.now());
      // A read that a later read has already superseded must not land.
      if (seq != _phoneReadSeq) return;
      // A null or -1 answer is the phone saying "I did not cover that interval",
      // which is not a zero. Leaving the reference absent makes `finish()` refuse
      // the run rather than fit a 0.0 gain from a phone on a table.
      if (steps != null && steps >= 0) s.setPhoneSteps(steps);
    } catch (_) {
      // Absent reference, not a fabricated one. finish() reports it.
    }
  }

  /// The household routine's reference through its END, or false when it
  /// cannot be had — in which case an earlier partial read must not stand in.
  ///
  /// Android: the sensor's running total at end minus at start, each after a
  /// flush. Exact, where a range query prorates 5-minute bins. Elsewhere (iOS
  /// has no running total, and its interval query is exact) one final query.
  Future<bool> _finalPhoneRead(CalibrationSession s) async {
    // A periodic read still in flight must not land on top of this one.
    ++_phoneReadSeq;
    final start = _routineStart;
    if (start == null) return false;
    final app = context.read<AppState>();
    final steps = await routinePhoneReference(
      runningTotalPlatform: defaultTargetPlatform == TargetPlatform.android,
      startTotal: await _startRaw,
      flush: _pedometer.flushPending,
      total: _pedometer.rawCount,
      interval: (end) => _pedometer.stepsBetween(start, end),
      now: DateTime.now,
      // The band's count stops where the phone's reference stops.
      markEnd: (end) => s.hold(
        bandTotal: app.liveStrapRawSteps,
        nowMs: end.millisecondsSinceEpoch,
      ),
    );
    if (steps == null) return false;
    s.setPhoneSteps(steps);
    return true;
  }

  void _cancel() {
    _ticker?.cancel();
    setState(() {
      _session = null;
      _routineStart = null;
      _outcome = null;
    });
  }

  Future<int?> _askCounted(int target) async {
    final l = AppLocalizations.of(context);
    final ctrl = TextEditingController(text: '$target');
    final out = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(l?.stepCalHowManyCounted ?? 'How many steps did you count?'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(),
            child: Text(l?.stepCalCancel ?? 'Cancel'),
          ),
          TextButton(
            onPressed: () {
              final n = int.tryParse(ctrl.text.trim());
              if (n != null && n > 0) Navigator.of(c).pop(n);
            },
            child: Text(l?.stepCalFinish ?? 'Done'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    return out;
  }

  Future<void> _finish() async {
    final s = _session;
    // `_busy` guards re-entry: the awaited final read leaves the buttons live,
    // and a second tap would finish a session that is already finished.
    if (s == null || _busy) return;
    // Gait: the wearer is the reference, so ask what they counted rather than
    // assume they reached the target. Cancelling keeps the routine running.
    int? counted;
    if (!s.category.referenceIsPhone) {
      // The walk ends at the tap, not when the question is answered.
      s.hold(
        bandTotal: context.read<AppState>().liveStrapRawSteps,
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );
      counted = await _askCounted(s.targetSteps);
      if (!mounted) return;
      if (counted == null) {
        s.resume();
        return;
      }
    }
    _ticker?.cancel();
    // Locked BEFORE the read, not after it.
    setState(() => _busy = true);
    // One final read, so the reference covers the WHOLE routine instead of
    // whatever the last tick happened to see — and so it is taken while the
    // wearer is still standing there, which is the difference between a measured
    // reference and a refused routine.
    if (s.category.referenceIsPhone) {
      // Android delivers step counts in batches up to a minute late; without a
      // flush the last stretch of the routine is missing from its reference.
      if (!await _finalPhoneRead(s)) s.clearPhoneSteps();
    }
    // §4.5: `context` may not be used after an await without this.
    if (!mounted) return;
    final out = s.finish(countedSteps: counted);
    final l = AppLocalizations.of(context);

    if (out.bandSilent) {
      setState(() {
        _busy = false;
        _session = null;
        _outcome = l?.stepCalNoSignal ?? 'The band recorded nothing during that routine.';
      });
      return;
    }
    if (out.refusal != null) {
      setState(() {
        _busy = false;
        _session = null;
        _outcome = _describeRefusal(out.refusal!, l);
      });
      return;
    }

    final app = context.read<AppState>();
    try {
      final profile = await LocalDb.bankLiveStepCalibrationRun(
        out.run!,
        runTs: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
      // Only after the save returned: a walk already in progress would otherwise
      // bank with the previous gain.
      app.invalidateLiveStepCalibration();
      // The run is stored from here on. A failed reload of the rows below is
      // not a failed save: reporting it as one invites a retry that stores the
      // same routine twice.
      // The bank's own result is the saved category's profile, so that row
      // is current even if the reload of the others fails.
      _profiles[out.run!.category] = profile;
      try {
        await _loadProfiles();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _busy = false;
        _session = null;
        _routineStart = null;
        _outcome = _describeOutcome(out.run!, profile, l);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _session = null;
        _routineStart = null;
        _outcome =
            '${l?.stepCalSaveFailed ?? 'Could not save that calibration.'} ($e)';
      });
    }
  }

  /// Every refusal is a claim about the ROUTINE, and the wearer is told which —
  /// a silent no-op that leaves them believing their walk taught the app
  /// something is the failure this screen exists to avoid.
  String _describeRefusal(StepRunRejection r, AppLocalizations? l) =>
      switch (r) {
        StepRunRejection.noReferenceSteps =>
          l?.stepCalNoPhone ??
              'Your phone counted no steps while you did that. Keep it in your '
                  'pocket next time — it is the reference for household movement.',
        StepRunRejection.rawTooSmall =>
          l?.stepCalBandQuiet ??
              'The band saw almost no movement. It is worth checking the strap is '
                  'worn snugly and streaming.',
        StepRunRejection.expectedTooSmall =>
          l?.stepCalTooShort ??
              'That routine was too short to measure against. Walk the full '
                  'count.',
        StepRunRejection.rawExceedsExpectedByTooMuch =>
          l?.stepCalMismatch ??
              'The band counted far more than you did. Something other than '
                  'walking was being picked up.',
        StepRunRejection.referenceWrongSource =>
          l?.stepCalWrongSource ?? 'That routine used the wrong reference.',
        StepRunRejection.nonFiniteFeature =>
          l?.stepCalBadData ?? 'That routine produced unreadable sensor data.',
        StepRunRejection.ratioOutsideGainRange =>
          l?.stepCalRatioOutOfRange ??
              'Your count and the band\u2019s are too far apart to use. Repeat '
                  'the routine and walk the full count.',
        StepRunRejection.cadenceOutsideGaitRange =>
          l?.stepCalCadenceOutOfRange ??
              'The band could not find a walking rhythm in that routine. Start '
                  'walking right after you press start and keep a steady pace.',
        StepRunRejection.routineTooShort =>
          l?.stepCalRoutineTooShort ??
              'That routine ended before the timer finished. Keep going until '
                  'it completes.',
      };

  String _describeOutcome(
    StepCalibrationRun run,
    LiveStepGainProfile profile,
    AppLocalizations? l,
  ) {
    // Signed, so a reduction reads as one: -12% is a different claim from 12%.
    final pct = ((profile.gain - 1) * 100).round();
    if (run.category.isGait) {
      return l?.stepCalDoneGait(run.expectedSteps, run.rawSteps, pct) ??
          'Saved. You counted ${run.expectedSteps} steps and the band saw '
              '${run.rawSteps}. From now on this kind of walking is corrected '
              'by $pct%.';
    }
    return l?.stepCalDoneHousehold(
          run.expectedSteps,
          run.rawSteps,
          profile.gain.toStringAsFixed(2),
        ) ??
        'Saved. Your phone counted ${run.expectedSteps} steps of the '
            '${run.rawSteps} the band saw. Household movement is now scaled to '
            '${profile.gain.toStringAsFixed(2)}.';
  }

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    final s = _session;
    return detailScaffold(
      c,
      l?.stepCalTitle ?? 'Step calibration',
      s == null ? _overview(c, l) : _running(c, l, s),
    );
  }

  List<Widget> _overview(BuildContext c, AppLocalizations? l) {
    final p = P.of(c);
    return [
      Text(
        l?.stepCalIntro ??
            'Your strap counts steps off its own motion sensor, and how far off '
                'it is depends on you. These routines measure that. Nothing '
                'leaves your phone.',
        style: F.cap.copyWith(color: p.ink2, height: 1.5),
      ),
      if (_outcome != null) ...[
        const SizedBox(height: S.x4),
        _feedback(c, _outcome!),
      ],
      const SizedBox(height: S.x4),
      for (final category in StepCategory.values) ...[
        detailLinkRow(
          c,
          _iconFor(category),
          _titleFor(category, l),
          _subtitleFor(category, l),
          () => _start(category),
        ),
        const SizedBox(height: S.x3),
      ],
    ];
  }

  List<Widget> _running(BuildContext c, AppLocalizations? l, CalibrationSession s) {
    final p = P.of(c);
    final isHousehold = s.category.referenceIsPhone;
    return [
      Text(
        _guideFor(s.category, l),
        style: F.cap.copyWith(color: p.ink2, height: 1.5),
      ),
      const SizedBox(height: S.x5),
      // The band's LIVE count, labelled as the band's — never as progress the
      // wearer should trust as their own count.
      Center(
        child: Text(
          '${s.bandRawSteps}',
          style: F.display.copyWith(color: p.ink),
        ),
      ),
      const SizedBox(height: S.x2),
      Center(
        child: Text(
          // Counts the number shown above it, so languages that inflect the
          // noun by count can agree with it.
          l?.stepCalBandSeen(s.bandRawSteps) ?? 'steps the band has seen',
          style: F.cap.copyWith(color: p.ink2),
        ),
      ),
      const SizedBox(height: S.x4),
      ClipRRect(
        borderRadius: R.rSm,
        child: LinearProgressIndicator(
          value: s.progress,
          minHeight: 6,
          backgroundColor: p.track,
          valueColor: AlwaysStoppedAnimation<Color>(p.ink),
        ),
      ),
      const SizedBox(height: S.x2),
      Text(
        isHousehold
            ? (l?.stepCalElapsed ?? 'Keep going — this one is timed.')
            : (l?.stepCalCountYourself(s.targetSteps) ??
                'Count your own steps. Stop when you reach ${s.targetSteps}.'),
        style: F.cap.copyWith(color: p.ink2),
      ),
      const SizedBox(height: S.x6),
      Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _busy ? null : _cancel,
              child: Text(l?.stepCalCancel ?? 'Cancel'),
            ),
          ),
          const SizedBox(width: S.x3),
          Expanded(
            child: FilledButton(
              onPressed: (_busy || !s.canFinish) ? null : _finish,
              child: Text(l?.stepCalFinish ?? 'Done'),
            ),
          ),
        ],
      ),
      if (!s.canFinish) ...[
        const SizedBox(height: S.x2),
        Text(
          isHousehold
              ? (l?.stepCalKeepMoving ??
                  'Nothing recorded yet — keep the phone on you and keep moving.')
              : (l?.stepCalKeepWalking ??
                  'Nothing recorded yet — start walking with the strap snug.'),
          style: F.cap.copyWith(color: p.ink2),
        ),
      ],
    ];
  }

  Widget _feedback(BuildContext c, String text) {
    final p = P.of(c);
    return Container(
      padding: const EdgeInsets.all(S.x4),
      decoration: BoxDecoration(
        color: p.ink3.withValues(alpha: 0.15),
        borderRadius: R.rMd,
      ),
      child: Text(text, style: F.cap.copyWith(color: p.ink, height: 1.5)),
    );
  }

  IconData _iconFor(StepCategory category) => switch (category) {
        StepCategory.slow => LucideIcons.footprints,
        StepCategory.brisk => LucideIcons.personStanding,
        StepCategory.jog => LucideIcons.activity,
        StepCategory.everyday => LucideIcons.house,
      };

  String _titleFor(StepCategory category, AppLocalizations? l) =>
      switch (category) {
        StepCategory.slow => l?.stepCalSlowTitle ?? 'Slow walk',
        StepCategory.brisk => l?.stepCalBriskTitle ?? 'Brisk walk',
        StepCategory.jog => l?.stepCalJogTitle ?? 'Jog',
        StepCategory.everyday => l?.stepCalEverydayTitle ?? 'Around the house',
      };

  String _subtitleFor(StepCategory category, AppLocalizations? l) {
    final profile = _profiles[category];
    final state = profile?.isCalibrated ?? false
        ? (l?.stepCalCalibrated(profile!.nRuns) ??
            'Calibrated — counted ${profile!.nRuns} times')
        : (l?.stepCalNotCalibrated ?? 'Not calibrated yet');
    return '$state · ${_guideShort(category, l)}';
  }

  String _guideShort(StepCategory category, AppLocalizations? l) =>
      switch (category) {
        StepCategory.slow =>
          l?.stepCalSlowSub ?? 'walk slowly, phone in your pocket',
        StepCategory.brisk => l?.stepCalBriskSub ?? 'walk at your usual pace',
        StepCategory.jog => l?.stepCalJogSub ?? 'jog steadily',
        StepCategory.everyday =>
          l?.stepCalEverydaySub ?? 'tidy up for three minutes, phone in pocket',
      };

  String _guideFor(StepCategory category, AppLocalizations? l) =>
      switch (category) {
        StepCategory.slow =>
          l?.stepCalSlowGuide ??
              'Walk slowly and evenly, strap snug. Count 100 steps yourself.',
        StepCategory.brisk =>
          l?.stepCalBriskGuide ??
              'Walk at your normal pace. Count 100 steps yourself.',
        StepCategory.jog =>
          l?.stepCalJogGuide ?? 'Jog steadily. Count 100 steps yourself.',
        StepCategory.everyday =>
          l?.stepCalEverydayGuide ??
              'Do ordinary things around the house — carry, lift, tidy — with '
                  'your phone in your pocket. Three minutes. Do not pace '
                  'deliberately.',
      };
}

/// Why a calibration routine did not start.
enum RoutineStartRefusal { noPhoneAccess, phoneNotReady }

/// Start a routine in the order that keeps its two references aligned:
/// phone access first, then (on Android, for a household routine) a starting
/// phone total from a COMPLETED flush, and only then the band baseline and the
/// routine's clock. Taking the band baseline first would let the phone's
/// starting total settle after the routine had begun, so the two counts would
/// cover different spans.
@visibleForTesting
Future<({CalibrationSession? session, int? startTotal, RoutineStartRefusal? refusal})>
    beginCalibrationRoutine({
  required StepCategory category,
  required Future<bool> Function() ensurePhoneAccess,
  required bool runningTotalPlatform,
  required Future<int?> Function() startTotal,
  required int Function() bandTotalNow,
  required int Function() nowMs,
}) async {
  int? total;
  if (category.referenceIsPhone) {
    if (!await ensurePhoneAccess()) {
      return (session: null, startTotal: null, refusal: RoutineStartRefusal.noPhoneAccess);
    }
    if (runningTotalPlatform) {
      total = await startTotal();
      if (total == null) {
        return (session: null, startTotal: null, refusal: RoutineStartRefusal.phoneNotReady);
      }
    }
  }
  final session = CalibrationSession(category: category)
    ..start(bandBaseline: bandTotalNow(), nowMs: nowMs());
  return (session: session, startTotal: total, refusal: null);
}

