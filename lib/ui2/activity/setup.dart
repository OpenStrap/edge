// Set the session up, then start it.
//
// One screen, and only the decisions this activity can honour: the GPS row is
// not offered to an indoor bike. The privacy toggle is offered to everything
// and defaults on for the entries that carry `private` — same posture Apple
// Health takes, and the copy says exactly what it does.
//
// THERE IS NO GOAL PICKER. There used to be — Open / Time / Distance /
// Calories, with a minutes stepper under Time — and not one of the four
// reached the session: `LiveDraft` has no goal field, no live screen mentions
// a target, and nothing alerts when one is met. Its only real effect was that
// the calorie line quoted '45 min', a duration the user had not chosen and
// could not see anywhere else on the screen. A control that changes nothing is
// not a simpler control, it is a promise. The estimate is a RATE now, on the
// same thirty-minute basis the picker's rows use, so the two screens compare.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/app_localizations.dart';
import '../grammar.dart';
import '../theme.dart';
import 'catalogue.dart';
import 'live.dart';

/// The window the calorie estimate is quoted over — the same one
/// [ActivityRow] uses in the picker, so a row and this screen agree.
const _estimateMin = 30;

class ActivitySetup extends StatefulWidget {
  final Activity a;
  final double? weightKg;

  /// The app behind the screen — the feed, the session lifecycle, the band's
  /// real connection state and the user's own lifting history.
  final ActivityHost host;

  const ActivitySetup(
    this.a, {
    super.key,
    this.weightKg,
    this.host = ActivityHost.none,
  });

  @override
  State<ActivitySetup> createState() => _ActivitySetupState();
}

class _ActivitySetupState extends State<ActivitySetup> {
  late bool private = widget.a.private;

  // Interval config — only read for Track.interval. Defaults match the old
  // hardcoded 45/30/8 CrossFit assumption, which every interval activity
  // (Jump rope, Kettlebell, HIIT, Circuit training too) used to be stuck
  // with regardless of what it actually was.
  int _workSec = 45;
  int _restSec = 30;
  int _rounds = 8;

  bool _starting = false;
  bool _refused = false;

  /// Open the session in the app FIRST, then the screen. The screen used to
  /// be pushed on its own, so a "live" workout ran its own clock while the
  /// app recorded nothing and `sessions` gained no row.
  Future<void> _start() async {
    if (_starting) return;
    setState(() => _starting = true);
    final start = widget.host.onStart;
    final ok = start == null || await start(widget.a);
    if (!mounted) return;
    setState(() {
      _starting = false;
      _refused = !ok;
    });
    if (!ok) return;
    final interval = widget.a.track == Track.interval;
    // The draft opens with the session, not with the screen: everything the
    // user types from here belongs to the session, and has to survive the
    // screen being minimised or the process being killed.
    if (start != null) {
      LiveDraft.begin(widget.a,
          private: private,
          weightKg: widget.weightKg,
          workSec: interval ? _workSec : null,
          restSec: interval ? _restSec : null,
          rounds: interval ? _rounds : null);
    }
    await Navigator.of(context).pushReplacement(MaterialPageRoute(
      // Passed straight through too, not just via the draft above: a caller
      // with no `host.onStart` (the design gallery preview) skips the draft
      // entirely, and without this the interval picked here would be
      // silently discarded in favour of 45/30/8.
      builder: (_) => liveFor(widget.a,
          private: private,
          weightKg: widget.weightKg,
          host: widget.host,
          intervalWorkSec: interval ? _workSec : null,
          intervalRestSec: interval ? _restSec : null,
          intervalRounds: interval ? _rounds : null),
    ));
  }

  /// Back into the session that is already running. The refusal used to be a
  /// dead end: "finish that one first", with no way to reach the one screen
  /// that can finish it.
  void _resume() {
    final d = LiveDraft.current;
    final a = d == null ? null : activityByName(d.activityKey);
    if (a == null) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => liveFor(a,
          private: d!.private, weightKg: d.weightKg, host: widget.host),
    ));
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final a = widget.a;
    final est = a.kcal(widget.weightKg, _estimateMin);

    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(a.name),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
              children: [
                Center(
                  child: Column(children: [
                    Container(
                      width: 84,
                      height: 84,
                      decoration: BoxDecoration(
                          color: p.wash(a.color), shape: BoxShape.circle),
                      child: Icon(a.icon, size: 38, color: p.on(a.color)),
                    ),
                    const SizedBox(height: S.x4),
                    Text(a.name, style: F.t2.copyWith(color: p.ink)),
                    const SizedBox(height: S.x1),
                    Text(_trackLabel(a.track, l),
                        textAlign: TextAlign.center,
                        style: F.cap.copyWith(color: p.ink3)),
                  ]),
                ),
                const SizedBox(height: S.x8),
                Surface(
                  pad: const EdgeInsets.symmetric(horizontal: S.x4),
                  child: Column(children: [
                    if (a.gps) ...[
                      // No tick. Nothing here has asked for location yet, and
                      // an unconditional green check claimed a fix that a
                      // permission dialog had not even been shown for.
                      _row(
                          p,
                          LucideIcons.mapPin,
                          l?.activitySetupRouteLabel ?? 'Route',
                          l?.activitySetupRouteDetail ??
                              'Recorded if location is available, and kept '
                                  'on this phone',
                          null),
                      Divider(color: p.line, height: 1),
                    ],
                    _row(
                        p,
                        LucideIcons.heartPulse,
                        l?.activitySetupHeartRateLabel ?? 'Heart rate',
                        widget.host.bandConnected
                            ? (l?.activitySetupBandConnected ??
                                'Band connected')
                            : (l?.activitySetupNoBandConnected ??
                                'No band connected'),
                        widget.host.bandConnected),
                    Divider(color: p.line, height: 1),
                    _toggle(
                        p,
                        LucideIcons.lock,
                        l?.activitySetupPrivateLabel ?? 'Private session',
                        l?.activitySetupPrivateDetail ??
                            'Hidden from summaries and exports',
                        private,
                        () => setState(() => private = !private),
                        l),
                  ]),
                ),
                if (a.track == Track.interval) ...[
                  const SizedBox(height: S.x4),
                  Surface(
                    pad: const EdgeInsets.symmetric(
                        horizontal: S.x4, vertical: S.x2),
                    child: Column(children: [
                      _stepper(
                          p,
                          l,
                          l?.activitySetupWorkLabel ?? 'Work',
                          '${_workSec}s',
                          () => setState(
                              () => _workSec = (_workSec - 5).clamp(5, 999)),
                          () => setState(
                              () => _workSec = (_workSec + 5).clamp(5, 999))),
                      Divider(color: p.line, height: 1),
                      _stepper(
                          p,
                          l,
                          l?.activitySetupRestLabel ?? 'Rest',
                          '${_restSec}s',
                          () => setState(
                              () => _restSec = (_restSec - 5).clamp(5, 999)),
                          () => setState(
                              () => _restSec = (_restSec + 5).clamp(5, 999))),
                      Divider(color: p.line, height: 1),
                      _stepper(
                          p,
                          l,
                          l?.activitySetupRoundsLabel ?? 'Rounds',
                          '$_rounds',
                          () => setState(
                              () => _rounds = (_rounds - 1).clamp(1, 99)),
                          () => setState(
                              () => _rounds = (_rounds + 1).clamp(1, 99))),
                    ]),
                  ),
                ],
                const SizedBox(height: S.x4),
                Surface(
                  elevation: 0,
                  color: p.card2,
                  child: Row(children: [
                    Expanded(
                      child: Text(
                          a.met == null
                              ? (l?.activitySetupNoMetEstimate ??
                                  'No estimate up front: no published MET '
                                      'applies to a session that names no '
                                      'activity. Calories come from your '
                                      'heart rate instead — when your age, '
                                      'weight and sex are set, and your '
                                      'resting and maximum rates are '
                                      'measured rather than assumed.')
                              : est == null
                                  ? (l?.activitySetupCaloriesNeedWeight ??
                                      'Calories need your weight.')
                                  : (l?.activitySetupCalorieEstimate(
                                          est,
                                          _estimateMin,
                                          a.met!.toStringAsFixed(1)) ??
                                      'About $est kcal per $_estimateMin min, '
                                          'from ${a.met!.toStringAsFixed(1)} '
                                          'MET and your weight.'),
                          style: F.cap.copyWith(color: p.ink3, height: 1.5)),
                    ),
                  ]),
                ),
                if (_refused) ...[
                  const SizedBox(height: S.x4),
                  StatusCard(
                    l?.activitySetupSessionRunningTitle ??
                        'A session is already running',
                    l?.activitySetupSessionRunningBody ??
                        'Only one can be live at a time.',
                    fix: LiveDraft.current == null
                        ? ''
                        : (l?.activitySetupOpenRunningSession ??
                            'Open the running session'),
                    onFix: LiveDraft.current == null ? null : _resume,
                    icon: LucideIcons.circleAlert,
                  ),
                ],
                const SizedBox(height: S.x8),
                BigButton(l?.activitySetupStart ?? 'Start',
                    icon: LucideIcons.play,
                    color: a.color,
                    onTap: _starting ? null : _start),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  /// What this session will actually produce. Distance and pace are promised
  /// only where a route can be recorded — a treadmill was being sold "distance
  /// and pace" that nothing in this app can measure indoors.
  String _trackLabel(Track t, AppLocalizations? l) => switch (t) {
        Track.sets =>
          l?.activitySetupTrackSets ?? 'Sets, reps and load — logged by you',
        Track.distance when widget.a.gps =>
          l?.activitySetupTrackDistanceGps ?? 'Distance, pace and heart rate',
        Track.distance || Track.duration =>
          l?.activitySetupTrackTime ?? 'Time and heart rate',
        Track.interval =>
          l?.activitySetupTrackInterval ?? 'Rounds and heart rate',
        Track.stillness =>
          l?.activitySetupTrackStillness ?? 'Time, breathing and heart rate',
      };

  /// [on] null means "not known yet" — no glyph at all, rather than a tick
  /// or a cross, both of which are claims.
  Widget _row(P p, IconData i, String n, String s, bool? on) => Padding(
        padding: const EdgeInsets.symmetric(vertical: S.x3),
        child: Row(children: [
          Icon(i, size: 17, color: p.ink2),
          const SizedBox(width: S.x3),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(n, style: F.body.copyWith(color: p.ink)),
                  Text(s, style: F.over.copyWith(color: p.ink3)),
                ]),
          ),
          if (on != null)
            Icon(on ? LucideIcons.circleCheck : LucideIcons.circleSlash,
                size: 20, color: on ? p.on(C.green) : p.line),
        ]),
      );

  Widget _stepper(P p, AppLocalizations? l, String label, String value,
          VoidCallback down, VoidCallback up) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: S.x3),
        child: Row(children: [
          Expanded(child: Text(label, style: F.body.copyWith(color: p.ink))),
          counterButton(p, LucideIcons.minus, p.ink2,
              l?.activityLiveDecrease(label) ?? '$label down', down,
              size: 32),
          SizedBox(
              width: 56,
              child: Text(value,
                  textAlign: TextAlign.center,
                  style: F.body.copyWith(color: p.ink))),
          counterButton(p, LucideIcons.plus, p.ink,
              l?.activityLiveIncrease(label) ?? '$label up', up,
              size: 32),
        ]),
      );

  Widget _toggle(P p, IconData i, String n, String s, bool on,
          VoidCallback onTap, AppLocalizations? l) =>
      Pressable(
        semanticLabel:
            '$n, ${on ? (l?.stateOn ?? 'On') : (l?.stateOff ?? 'Off')}',
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: S.x3),
          child: Row(children: [
            Icon(i, size: 17, color: p.ink2),
            const SizedBox(width: S.x3),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(n, style: F.body.copyWith(color: p.ink)),
                    Text(s, style: F.over.copyWith(color: p.ink3)),
                  ]),
            ),
            AnimatedContainer(
              duration: motion(context, Motion.base),
              width: 44,
              height: 26,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                  color: on ? p.fill(C.green) : p.track,
                  borderRadius: R.rPill),
              child: AnimatedAlign(
                duration: motion(context, Motion.base),
                alignment:
                    on ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                      color: p.inkOnFill, shape: BoxShape.circle),
                ),
              ),
            ),
          ]),
        ),
      );
}
