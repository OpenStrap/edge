// The live screens.
//
// Same interaction grammar — one shell, one clock, one pause/stop control —
// with a completely different middle. That difference is the point of the
// file: what the user is asked for depends on what nothing can measure.
//
//   MEASURED    route, journey, power        nothing to type; sensors do it
//   ENTERED     strength                     load, reps, RPE, rest
//               laps                         + LAP, pool length, stroke
//               flow                         pose, hold, breath
//               match                        score
//               interval                     rounds run themselves
//
// Nothing in here invents a measurement. [LiveFeed] is the seam to the band —
// every field nullable, and an absent one renders as a StatusCard rather than
// a zero. Calories are the one derived number, and they are derived from the
// activity's published MET and the user's weight (never from nothing), which
// is why they carry estimated confidence everywhere they appear.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

// The permission enum only — a pure value type, no geolocator call from this
// file. The rule this file keeps is no AppState and no LocalDb: the live
// screens describe a session, the caller owns it. Prefs is a synchronous
// key/value façade, not the app.
import '../../gps/gps_source.dart' show GpsPermissionStatus;
import '../../l10n/app_localizations.dart';
import '../../state/prefs.dart';
import '../../state/units_controller.dart';
import '../screens/home_screen.dart' show unitsOf;
import '../charts.dart';
import '../grammar.dart';
import '../paint_activity.dart';
import '../theme.dart';
import 'catalogue.dart';
import 'summary.dart';

/// What the band and the phone know right now. Read once per tick.
///
/// There is no `watts`: nothing in this stack measures power (see [Arch]).
class LiveFeed {
  final int? hr;

  /// Spike-suppressed session peak, from the same accumulator the finished
  /// session banks — not `max(hr seen by this screen)`.
  final int? maxHr;
  final int? zone; // 1..5
  final int? calories;
  final double? strain;
  final double? distanceKm;
  final int? steps;
  final List<double> zoneMinutes; // five, Z1..Z5

  /// The stamp on the set [zoneMinutes] is binned with, and the ceiling it is
  /// 100 % of — `LiveWorkoutState.zoneSet`, pinned at session start. Carried so
  /// the summary this screen hands over on stop describes the same anchors the
  /// live bar was drawn against.
  final String? zoneSource;
  final num? zoneMaxHr;

  /// Per-minute mean heart rate for the session so far, DENSE — one slot per
  /// session minute, `null` where the band recorded nothing.
  ///
  /// It has to carry the holes: `ActivityResult.hr` is `List<double?>` and the
  /// painter breaks its line at a null, so a compacted list here drew a band
  /// dropout as continuous and shifted every later reading earlier.
  ///
  /// The average of this IS the session average — a single instantaneous
  /// sample is not.
  final List<double?> hrCurve;
  final List<Offset> route;

  /// Whether a route recorder is actually running and taking fixes. The
  /// catalogue's `gps` flag says an activity DESERVES a route; only this says
  /// one is being recorded.
  final bool gpsActive;

  /// Why no route is being recorded, when the reason is a location permission
  /// the user can still fix. Null when nothing is wrong. Without this a denied
  /// permission simply produced no map and no sentence.
  final GpsPermissionStatus? routeIssue;

  /// What to do about [routeIssue] — re-ask, or open Settings. It rides on the
  /// feed because the feed is the one thing every live screen already has, and
  /// the caller owns which of the two it is.
  final VoidCallback? onFixRoute;

  /// Whether the band is connected right now. An absent heart rate means one
  /// thing when the band is streaming and something else entirely when it
  /// dropped ten minutes ago.
  final bool bandConnected;

  const LiveFeed({
    this.hr,
    this.maxHr,
    this.zone,
    this.calories,
    this.strain,
    this.distanceKm,
    this.steps,
    this.zoneMinutes = const [],
    this.zoneSource,
    this.zoneMaxHr,
    this.hrCurve = const [],
    this.route = const [],
    this.gpsActive = false,
    this.routeIssue,
    this.onFixRoute,
    this.bandConnected = false,
  });

  static const none = LiveFeed();

  /// Mean of the per-minute curve — the session's real average heart rate,
  /// null until a full minute has been folded in.
  /// Over the minutes that HAVE a reading. A dropout must not be averaged in
  /// as a zero, and it must not divide by minutes that measured nothing.
  int? get avgHr {
    final v = [for (final x in hrCurve) ?x];
    if (v.isEmpty) return null;
    return (v.reduce((a, b) => a + b) / v.length).round();
  }
}

typedef LiveFeedSource = LiveFeed Function();

/// Ends the session the app started: stops the live engine, persists what the
/// user typed against the session id, and returns the result ENRICHED with
/// whatever the stores now hold (the GPS route, above all).
///
/// It returns a result rather than taking one so this file stays free of
/// `AppState` and `LocalDb` — the live screens describe a session, the caller
/// owns it. A screen built without one still runs; it just does not persist,
/// which is exactly what the widget tests want.
typedef SessionFinish = Future<ActivityResult> Function(ActivityResult draft);

/// Starts a session in the app before the live screen opens. Returns false if
/// the app refused (one is already running).
typedef SessionStart = Future<bool> Function(Activity a);

/// Previous and best set for one exercise — the two references a lifter
/// actually uses. Absent for a lift they have never logged.
class SetHistory {
  final LoggedSet? previous, best;
  const SetHistory({this.previous, this.best});
}

/// Everything the activity screens need FROM the app, in one object.
///
/// Picker → setup → live is three constructors deep, and every one of these
/// used to be an optional parameter that no caller passed — which is how the
/// setup screen ended up saying "No band connected" while the band was
/// streaming. One object, threaded once, and a default that is honest about
/// having no app behind it (tests, previews).
class ActivityHost {
  /// The band and phone, read once per tick.
  final LiveFeedSource? feed;

  /// Opens a real session in the app. False means it refused — one is
  /// already running — and the live screen must not open.
  final SessionStart? onStart;

  /// Closes it, persists what was typed, and enriches the result.
  final SessionFinish? onFinish;

  /// Banks the sets logged SO FAR, on every change. A typed set is the one
  /// thing in a session that no sensor can reproduce, so it is written the
  /// moment it exists rather than at finish — the whole log used to live in
  /// widget state until the user pressed stop.
  final void Function(List<LoggedSet> sets)? onSets;

  /// Previous and best set per exercise key, from the user's own log.
  final Map<String, SetHistory> history;

  /// Whether the band is connected right now.
  final bool bandConnected;

  const ActivityHost({
    this.feed,
    this.onStart,
    this.onFinish,
    this.onSets,
    this.history = const {},
    this.bandConnected = false,
  });

  /// No app behind the screens: they still render, nothing is persisted.
  static const none = ActivityHost();
}

// ══════════════ THE SESSION, ABOVE THE ROUTE ══════════════

/// The running session's own state, held above the screen that draws it.
///
/// The live screen used to own every byte of a session. The header's
/// "Minimise" called `Navigator.maybePop` and an iOS back-swipe did the same,
/// so the sets, laps and score the user had typed died with the route while
/// `AppState.activeWorkout` stayed open — after which the app refused every
/// further workout and offered no way back into the one it was holding.
///
/// The entries live here instead, mirrored into Prefs on every change: a
/// minimised session outlives its route, and a killed process loses the
/// screen rather than the typing. [begin] is called by whoever starts the
/// session (setup), [clear] by whoever ends it. A screen built without a
/// draft — a test, a preview — simply has nothing to restore and nothing to
/// save, which is exactly the old behaviour.
class LiveDraft {
  static const _key = 'live.session_draft';

  /// The catalogue key of the activity being done, so the bar that reopens a
  /// minimised session knows which screen to build.
  final String activityKey;
  final bool private;
  final double? weightKg;
  final DateTime startedAt;

  /// Interval config chosen on the setup screen — null for every archetype
  /// but [Track.interval], where 45/30/8 used to be a constant nothing let
  /// the user change.
  final int? workSec;
  final int? restSec;
  final int? rounds;

  /// Seconds banked in earlier pauses, and when the current pause began. The
  /// clock is wall time minus these, so it stays true across a long
  /// background spell or a relaunch instead of counting screen-on seconds.
  int pausedSec;
  DateTime? pausedAt;

  /// The archetype's own entries — sets, laps, score. Opaque here: whichever
  /// screen wrote a key is the one that reads it back.
  final Map<String, Object?> data;

  LiveDraft._(this.activityKey,
      {required this.startedAt,
      this.private = false,
      this.weightKg,
      this.workSec,
      this.restSec,
      this.rounds,
      this.pausedSec = 0,
      this.pausedAt,
      Map<String, Object?>? data})
      : data = data ?? <String, Object?>{};

  static LiveDraft? _current;
  static bool _loaded = false;

  /// The session in progress, or null. Read from Prefs once per process, so a
  /// relaunch after a kill still finds a workout that was never finished.
  static LiveDraft? get current {
    if (!_loaded) {
      _loaded = true;
      _current = _decode(Prefs.getString(_key, ''));
    }
    return _current;
  }

  /// Open a draft for a session the app has just accepted.
  static LiveDraft begin(Activity a,
      {bool private = false,
      double? weightKg,
      int? workSec,
      int? restSec,
      int? rounds}) {
    _loaded = true;
    _current = LiveDraft._(a.typeKey,
        startedAt: DateTime.now(),
        private: private,
        weightKg: weightKg,
        workSec: workSec,
        restSec: restSec,
        rounds: rounds);
    _save();
    return _current!;
  }

  /// Drop the in-memory copy WITHOUT touching what was written. The next read
  /// comes off Prefs again — which is what a relaunch after a kill does, and
  /// the only way to test that the entries actually survive one.
  @visibleForTesting
  static void debugForget() {
    _loaded = false;
    _current = null;
  }

  /// The session is over (or was never really there).
  static void clear() {
    _loaded = true;
    _current = null;
    Prefs.setString(_key, '');
  }

  /// Wall-clock seconds this session has been running, pauses removed.
  int get elapsedSec {
    final now = DateTime.now();
    final inPause = pausedAt == null ? 0 : now.difference(pausedAt!).inSeconds;
    final v = now.difference(startedAt).inSeconds - pausedSec - inPause;
    return v < 0 ? 0 : v;
  }

  void setPaused(bool on) {
    if (on) {
      pausedAt ??= DateTime.now();
    } else if (pausedAt != null) {
      pausedSec += DateTime.now().difference(pausedAt!).inSeconds;
      pausedAt = null;
    }
    _save();
  }

  /// Record one of the archetype's entries. Written straight through — the
  /// point of the draft is that nothing waits for a "save".
  void put(String key, Object? value) {
    data[key] = value;
    _save();
  }

  static void _save() {
    final d = _current;
    if (d == null) return Prefs.setString(_key, '');
    Prefs.setString(
        _key,
        jsonEncode({
          'a': d.activityKey,
          'private': d.private,
          'weight': d.weightKg,
          'work_sec': d.workSec,
          'rest_sec': d.restSec,
          'rounds': d.rounds,
          'start': d.startedAt.millisecondsSinceEpoch,
          'paused_sec': d.pausedSec,
          'paused_at': d.pausedAt?.millisecondsSinceEpoch,
          'data': d.data,
        }));
  }

  static LiveDraft? _decode(String raw) {
    if (raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return null;
      final key = m['a'];
      final start = m['start'];
      if (key is! String || start is! num) return null;
      return LiveDraft._(
        key,
        startedAt: DateTime.fromMillisecondsSinceEpoch(start.toInt()),
        private: m['private'] == true,
        weightKg: (m['weight'] as num?)?.toDouble(),
        workSec: (m['work_sec'] as num?)?.toInt(),
        restSec: (m['rest_sec'] as num?)?.toInt(),
        rounds: (m['rounds'] as num?)?.toInt(),
        pausedSec: (m['paused_sec'] as num?)?.toInt() ?? 0,
        pausedAt: (m['paused_at'] as num?) == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                (m['paused_at'] as num).toInt()),
        data: (m['data'] as Map?)?.cast<String, Object?>(),
      );
    } catch (_) {
      // A draft we cannot read is a draft we do not have.
      return null;
    }
  }
}

/// The live screen for [a]. One switch, nine archetypes, six screens — route,
/// journey, power and basic all measure rather than ask, so they share one.
Widget liveFor(
  Activity a, {
  bool private = false,
  double? weightKg,
  ActivityHost host = ActivityHost.none,

  /// Explicit interval config, from the setup screen that just chose it.
  /// Null falls back to [LiveDraft.current] (a resume/minimise, where the
  /// screen that reopens the session never chose anything itself) and then
  /// to the old 45/30/8 defaults.
  int? intervalWorkSec,
  int? intervalRestSec,
  int? intervalRounds,
}) {
  final p = private || a.private;
  final feed = host.feed;
  final history = host.history;
  final onFinish = host.onFinish;
  return switch (archOf(a)) {
    Arch.strength => LiveStrength(a,
        feed: feed,
        weightKg: weightKg,
        history: history,
        private: p,
        onFinish: onFinish,
        onSets: host.onSets),
    Arch.laps => LiveSwim(a,
        feed: feed, weightKg: weightKg, private: p, onFinish: onFinish),
    Arch.flow => LiveFlow(a,
        feed: feed, weightKg: weightKg, private: p, onFinish: onFinish),
    Arch.match => LiveMatch(a,
        feed: feed, weightKg: weightKg, private: p, onFinish: onFinish),
    Arch.interval => LiveInterval(a,
        feed: feed,
        weightKg: weightKg,
        private: p,
        onFinish: onFinish,
        workSec: intervalWorkSec ?? LiveDraft.current?.workSec ?? 45,
        restSec: intervalRestSec ?? LiveDraft.current?.restSec ?? 30,
        rounds: intervalRounds ?? LiveDraft.current?.rounds ?? 8),
    _ => LiveMeasured(a,
        feed: feed, weightKg: weightKg, private: p, onFinish: onFinish),
  };
}

// ══════════════ THE SHELL ══════════════

class LiveShell extends StatefulWidget {
  final Activity a;
  final String subtitle;
  final bool private;
  final double? weightKg;

  /// The archetype's middle. Rebuilt every tick with elapsed seconds, unless
  /// [bodyFollowsClock] says it has nothing that changes with the clock.
  final Widget Function(BuildContext c, int elapsed) body;

  /// Whether [body] shows anything that moves with the clock or the band.
  /// False builds it once per rebuild of this shell and leaves the 1 Hz tick
  /// alone: a strength session is entirely typed, so ticking redrew a set list
  /// that cannot have changed, once a second, for the length of the workout.
  final bool bodyFollowsClock;

  /// Anything pinned above the transport controls — the strength logger's
  /// "Log set", for instance. It gets no clock: it is rebuilt when the screen
  /// that owns it changes, not on the tick.
  final Widget Function(BuildContext c)? footer;

  /// What this session became, built when the user stops it.
  final ActivityResult Function(int elapsed) result;

  /// Hands the finished session to the app to be persisted, and takes back
  /// whatever the stores can add to it. Absent in tests and previews.
  final SessionFinish? onFinish;

  const LiveShell(
    this.a, {
    super.key,
    required this.body,
    required this.result,
    this.bodyFollowsClock = true,
    this.subtitle = '',
    this.private = false,
    this.weightKg,
    this.footer,
    this.onFinish,
  });

  @override
  State<LiveShell> createState() => LiveShellState();
}

class LiveShellState extends State<LiveShell> {
  /// Seeded from the draft, so reopening a minimised session — or relaunching
  /// after a kill — carries on from where the session actually is rather than
  /// from zero.
  ///
  /// A listenable rather than a field behind `setState`: the tick used to
  /// rebuild and re-lay-out this whole screen once a second for the length of
  /// a workout — header, transport controls and all — when the only thing that
  /// moves is the middle.
  late final ValueNotifier<int> clock =
      ValueNotifier<int>(LiveDraft.current?.elapsedSec ?? 0);
  int get elapsed => clock.value;
  late bool paused = LiveDraft.current?.pausedAt != null;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    // The session clock is real time, not motion: it runs whether or not the
    // platform wants animation, and it stops in dispose so nothing outlives
    // the screen. With a draft it is READ from wall time rather than counted
    // in ticks — a screen that was backgrounded for ten minutes must not come
    // back ten minutes behind the session it is drawing.
    _t = Timer.periodic(Motion.tick, (_) {
      if (!mounted) return;
      final d = LiveDraft.current;
      if (d != null) {
        clock.value = d.elapsedSec;
      } else if (!paused) {
        clock.value++;
      }
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    clock.dispose();
    super.dispose();
  }

  bool _finishing = false;

  Future<void> finish() async {
    // Stopping twice would stop the app's session twice and save the strength
    // log twice; the second tap must do nothing at all.
    if (_finishing) return;
    _finishing = true;
    _t?.cancel();
    final draft = widget.result(elapsed);
    // The app writes the session, flushes the GPS tail and hands back what it
    // could add. A failure here must still land the user on their summary —
    // losing the screen is worse than losing the enrichment.
    var result = draft;
    // A throw here is `stopWorkout` or the strength write failing, which means
    // the session is NOT in the database. The summary still opens, because
    // losing the screen is worse — but it is told, so it can say so and offer
    // the retry instead of drawing a plausible summary of nothing.
    final onFinish = widget.onFinish;
    Future<ActivityResult> Function()? retrySave;
    try {
      result = await onFinish?.call(draft) ?? draft;
    } catch (_) {
      result = draft;
      retrySave = onFinish == null ? null : () => onFinish(draft);
    }
    // The session is over: no draft to reopen, and no resume bar.
    LiveDraft.clear();
    if (!mounted) return;
    // Everything under the summary belongs to setting this session up —
    // picker, setup, the live screen itself. Back from a summary used to land
    // on "choose an activity", immediately after finishing one.
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(
        // `justFinished` — TS-09's prompt is asked here and only here. On a
        // failed write `result` is the draft, which carries no session id, so
        // the prompt does not appear over a session that is not in the
        // database.
        builder: (_) => ActivitySummary(result,
            weightKg: widget.weightKg,
            onRetrySave: retrySave,
            justFinished: true),
      ),
      (r) => r.isFirst,
    );
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final a = widget.a;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x5),
            child: Row(children: [
              // A real minimise: the session lives on [LiveDraft], not on this
              // route, so leaving the screen — by this chevron, by Android
              // back, or by an iOS edge-swipe — puts it away rather than
              // destroying it. The bar above the tab bar brings it back.
              Pressable(
                semanticLabel: l?.activityLiveMinimiseLabel ?? 'Minimise',
                onTap: () => Navigator.maybePop(c),
                child:
                    Icon(LucideIcons.chevronDown, size: 24, color: p.ink3),
              ),
              Expanded(
                child: Column(children: [
                  Text(a.name.toUpperCase(),
                      style: F.over.copyWith(color: p.on(a.color)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  if (widget.subtitle.isNotEmpty)
                    Text(widget.subtitle,
                        style: F.over.copyWith(color: p.ink3),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                ]),
              ),
              if (widget.private)
                Icon(LucideIcons.lock, size: 18, color: p.ink3)
              else
                const SizedBox(width: S.x5),
            ]),
          ),
          Expanded(
            // The tick reaches the body and stops there. A body that does not
            // follow the clock is handed through as `child`, which is the same
            // widget instance on every tick — so its whole subtree is skipped
            // rather than rebuilt — and the parts of it that DO move once a
            // second ask for the tick themselves, through [LiveTick].
            child: _LiveClock(
              clock,
              child: Builder(
                builder: (bc) => ValueListenableBuilder<int>(
                  valueListenable: clock,
                  child: widget.bodyFollowsClock
                      ? null
                      : widget.body(bc, clock.value),
                  builder: (bc2, e, child) => ListView(
                    padding: const EdgeInsets.fromLTRB(S.x5, 0, S.x5, S.x4),
                    children: [child ?? widget.body(bc2, e)],
                  ),
                ),
              ),
            ),
          ),
          if (widget.footer != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: S.x5),
              child: widget.footer!(c),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(S.x5, S.x4, S.x5, S.x5),
            child: Row(children: [
              // A control with no callback is announced as content and does
              // nothing when activated. Locking the screen is not implemented,
              // so the affordance is not drawn.
              const SizedBox(width: 54),
              const SizedBox(width: S.x4),
              Expanded(
                child: Pressable(
                  semanticLabel: paused
                      ? (l?.activityLiveResumeLabel ?? 'Resume')
                      : (l?.activityLivePauseLabel ?? 'Pause'),
                  onTap: () => setState(() {
                    paused = !paused;
                    LiveDraft.current?.setPaused(paused);
                  }),
                  child: Container(
                    height: 60,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                        color: p.fill(a.color), borderRadius: R.rLg),
                    child: Icon(
                        paused ? LucideIcons.play : LucideIcons.pause,
                        size: 25,
                        color: p.inkOnFill),
                  ),
                ),
              ),
              const SizedBox(width: S.x4),
              _round(p, LucideIcons.square, p.card2, p.on(C.red),
                  l?.activityLiveFinishSessionLabel ?? 'Finish session',
                  finish),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _round(P p, IconData i, Color bg, Color fg, String label,
          VoidCallback? onTap) =>
      Pressable(
        semanticLabel: label,
        onTap: onTap,
        child: Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
          child: Icon(i, size: 20, color: fg),
        ),
      );
}

/// The shell's clock, offered to the body without subscribing anyone to it.
/// Looked up with `getInheritedWidgetOfExactType` (see [LiveTick]) rather than
/// depended on, because depending on it is the 1 Hz whole-screen rebuild this
/// exists to avoid.
class _LiveClock extends InheritedWidget {
  final ValueNotifier<int> clock;
  const _LiveClock(this.clock, {required super.child});

  @override
  bool updateShouldNotify(_LiveClock old) => old.clock != clock;
}

/// The one part of a body that does follow the clock, in a body that mostly
/// does not. Outside a [LiveShell] it builds once at zero, which is what a
/// preview or a widget test wants.
class LiveTick extends StatelessWidget {
  final Widget Function(BuildContext c, int elapsed) builder;
  const LiveTick(this.builder, {super.key});

  @override
  Widget build(BuildContext c) {
    final clock = c.getInheritedWidgetOfExactType<_LiveClock>()?.clock;
    return clock == null
        ? builder(c, 0)
        : ValueListenableBuilder<int>(
            valueListenable: clock,
            builder: (bc, e, _) => builder(bc, e));
  }
}

// ══════════════ SHARED PIECES ══════════════

/// The one big number. [F.n48] and no bigger — a display size that only
/// exists on one screen is how seven type steps became forty.
/// Speak a transition. A haptic reaches a wrist and nothing else — the two
/// moments a paced session actually has to announce (rest is over, work
/// begins) were buzz-only, so a screen-reader user driving an interval workout
/// had no signal at all.
void say(BuildContext c, String what) =>
    SemanticsService.sendAnnouncement(View.of(c), what, TextDirection.ltr);

/// [ExcludeSemantics] because it is rebuilt every second for the length of a
/// workout: left in the tree it re-announces itself at 1 Hz, which makes a
/// screen reader unusable for exactly as long as the session lasts. The
/// elapsed time is on the shell's own label; the moments worth hearing are
/// announced explicitly (see [say]).
Widget bigNum(P p, String v, String unit) => ExcludeSemantics(
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Flexible(
            child: Text(v,
                style: F.n48.copyWith(color: p.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis)),
        if (unit.isNotEmpty) ...[
          const SizedBox(width: S.x2),
          Text(unit, style: F.t2.copyWith(color: p.ink3)),
        ],
      ],
    ));

/// Up to three supporting numbers. A stat with nothing behind it is omitted,
/// never rendered as a dash — and an entirely empty row is no row.
Widget statRow(P p, List<(String, String)> items) => items.isEmpty
    ? const SizedBox.shrink()
    : Row(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) Container(width: 1, height: 36, color: p.line),
          Expanded(
            child: Column(children: [
              Text(items[i].$1, style: F.n24.copyWith(color: p.ink)),
              const SizedBox(height: S.x1),
              Text(items[i].$2,
                  style: F.over.copyWith(color: p.ink3),
                  textAlign: TextAlign.center),
            ]),
          ),
        ],
      ],
      );

Widget counterButton(P p, IconData i, Color col, String label,
        VoidCallback onTap,
        {double size = 56}) =>
    Pressable(
      semanticLabel: label,
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: p.card2, shape: BoxShape.circle),
        child: Icon(i, size: size * .42, color: col),
      ),
    );

/// The live heart-rate block, or an honest absence.
class LiveHeart extends StatelessWidget {
  final LiveFeed feed;
  const LiveHeart(this.feed, {super.key});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    if (feed.hr == null) {
      // One card used to cover both, and it told a user whose band had
      // dropped mid-session to adjust the fit of a band that was not there.
      return feed.bandConnected
          ? StatusCard(
              l?.activityLiveNoHrYetTitle ?? 'No heart rate yet',
              l?.activityLiveNoHrYetBody ??
                  'The band is connected but has not reported a beat, so it '
                      'needs to be snug, a finger-width above the wrist bone.',
              icon: LucideIcons.heartPulse,
            )
          : StatusCard(
              l?.activityLiveNoHrTitle ?? 'No heart rate',
              l?.activityLiveNoHrBody ??
                  'The band is not connected, so nothing is arriving for '
                      'this session.',
              icon: LucideIcons.heartPulse,
            );
    }
    final z = feed.zone;
    return Column(children: [
      // A Wrap, not a Row: the beat, its unit and the zone pill fit one line
      // at a normal text size and overflowed the live screen by 64 px at an
      // accessibility one. Two lines is the honest answer; a clipped heart
      // rate on a screen the user is exercising in front of is not.
      Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: S.x2,
        runSpacing: S.x1,
        children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(LucideIcons.heart, size: 18, color: p.on(C.red)),
            const SizedBox(width: S.x2),
            Text('${feed.hr}', style: F.n24.copyWith(color: p.ink)),
            const SizedBox(width: S.x1),
            Text(l?.activityLiveBpmUnit ?? 'bpm',
                style: F.cap.copyWith(color: p.ink3)),
          ]),
          if (z != null)
            // The zone's OWN colour, the one the bar underneath paints it in. A
            // fixed green said "zone 5" and "zone 1" in the same breath.
            Pill(l?.activityLiveZoneLabel(z) ?? 'Zone $z',
                ZoneBar.pigment[(z - 1).clamp(0, 4)]),
        ],
      ),
      if (feed.zoneMinutes.length == 5) ...[
        const SizedBox(height: S.x4),
        ChartFrame(
          title: l?.activityLiveTimeInZonesTitle ?? 'TIME IN ZONES',
          unit: 'minutes',
          height: 10,
          legend: [
            for (var i = 0; i < 5; i++)
              ('Z${i + 1} · ${feed.zoneMinutes[i].round()}m', ZoneBar.cols(p)[i]),
          ],
          child: CustomPaint(
              size: Size.infinite,
              painter: ZoneBar(_fractions(feed.zoneMinutes), p)),
        ),
      ],
    ]);
  }

  static List<double> _fractions(List<double> mins) {
    final total = mins.fold<double>(0, (a, b) => a + b);
    if (total <= 0) return const [0, 0, 0, 0, 0];
    return [for (final m in mins) m / total];
  }
}

/// Why this session is being recorded without a route, and the one thing that
/// would fix it. The session keeps running either way — a missing map is not a
/// reason to stop a run — but it is named rather than left blank.
Widget? _routeIssueCard(
    BuildContext c, GpsPermissionStatus? issue, VoidCallback? onFix) {
  final l = AppLocalizations.of(c);
  return switch (issue) {
    null => null,
    // Title and action, no body. The body was cut as slop; the AFFORDANCE is
    // not slop — denied is the one branch a user can actually resolve from
    // here, and dropping the whole card left them with a missing map and no
    // way to fix it.
    GpsPermissionStatus.denied => StatusCard(
        l?.activityLiveNoRouteNotAllowedTitle ??
            'No route: location not allowed',
        '',
        fix: l?.activityLiveAllowLocation ?? 'Allow location',
        onFix: onFix,
        icon: LucideIcons.mapPin,
      ),
    GpsPermissionStatus.serviceOff => StatusCard(
        l?.activityLiveNoRouteOffTitle ?? 'No route: location is off',
        l?.activityLiveNoRouteOffBody ??
            'Location services are off on this phone, so no fixes are '
                'arriving.',
        fix: l?.activityLiveTurnOnLocation ?? 'Turn on location',
        onFix: onFix,
        icon: LucideIcons.mapPin,
      ),
    GpsPermissionStatus.deniedForever => StatusCard(
        l?.activityLiveNoRouteNotAllowedTitle ??
            'No route: location not allowed',
        l?.activityLiveDeniedForeverBody ??
            'Location is denied for this app, which only Settings can '
                'change.',
        fix: l?.activityLiveOpenSettings ?? 'Open Settings',
        onFix: onFix,
        icon: LucideIcons.mapPin,
      ),
    // `granted` cannot reach here: it is never stored as an issue.
    _ => StatusCard(
        l?.activityLiveNoRouteFailedTitle ?? 'No route: location failed',
        l?.activityLiveNoRouteFailedBody ??
            'The phone returned an error when asked for a fix.',
        fix: l?.activityLiveTryAgain ?? 'Try again',
        onFix: onFix,
        icon: LucideIcons.mapPin,
      ),
  };
}

/// MET-derived calories for the elapsed time, or the feed's own figure when
/// the band produced one. Null when body weight is unknown — the whole point
/// of the MET formula is that it needs a mass.
int? _kcal(Activity a, LiveFeed feed, double? weightKg, int elapsed) =>
    feed.calories ?? a.kcal(weightKg, (elapsed / 60).round());

/// The distance/pace pair plus the common three-up, in the user's units.
///
/// PACE IS OMITTED, never dashed, when there isn't one yet: at the start of a
/// run a few metres of GPS jitter divided into real elapsed time reads as
/// something like 1000 min/km, which [UnitsController.formatPace] refuses by
/// returning null. A stat that has no value is not drawn.
List<Widget> _distanceStats(BuildContext ctx, P p, LiveFeed f, Activity a,
    double? weightKg, int elapsed) {
  final u = unitsOf(ctx);
  final km = f.distanceKm;
  final meters = km == null ? null : km * 1000;
  final value = meters == null
      ? null
      : (u == null ? meters / 1000 : u.distanceValue(meters));
  final unit = u?.distanceUnit ?? 'km';
  final pacePerUnit = (meters == null || meters <= 0)
      ? null
      : UnitsController.formatPace(
          elapsed / (u == null ? meters / 1000 : u.distanceValue(meters)));
  return [
    statRow(p, [
      if (value != null) (value.toStringAsFixed(2), unit),
      if (pacePerUnit != null) (pacePerUnit, '/$unit'),
      ..._commonStats(ctx, a, f, weightKg, elapsed),
    ].take(3).toList()),
  ];
}

/// "5.24 km" / "3.25 mi" for a distance already known to exist.
String _distanceText(BuildContext c, double km) {
  final u = unitsOf(c);
  return u == null
      ? '${km.toStringAsFixed(2)} km'
      : u.distance(km * 1000)!; // non-null in, non-null out
}

String _distanceUnit(BuildContext c) => unitsOf(c)?.distanceUnit ?? 'km';

/// Display text for a swim stroke — [key] stays the canonical English value
/// stored on the session (see [LiveSwim]'s `strokes` and [_baseResult]'s
/// `stroke:`); only what the user reads is translated.
String _strokeLabel(BuildContext c, String key) {
  final l = AppLocalizations.of(c);
  return switch (key) {
    'Free' => l?.activityLiveStrokeFree ?? 'Free',
    'Back' => l?.activityLiveStrokeBack ?? 'Back',
    'Breast' => l?.activityLiveStrokeBreast ?? 'Breast',
    'Fly' => l?.activityLiveStrokeFly ?? 'Fly',
    _ => key,
  };
}

/// Display text for a yoga pose — [key] stays the canonical English value
/// stored in [LiveFlow]'s `poses` and passed to [_baseResult]'s `poses:`.
String _poseLabel(BuildContext c, String key) {
  final l = AppLocalizations.of(c);
  return switch (key) {
    'Mountain' => l?.activityLivePoseMountain ?? 'Mountain',
    'Forward fold' => l?.activityLivePoseForwardFold ?? 'Forward fold',
    'Plank' => l?.activityLivePosePlank ?? 'Plank',
    'Warrior II' => l?.activityLivePoseWarriorTwo ?? 'Warrior II',
    'Triangle' => l?.activityLivePoseTriangle ?? 'Triangle',
    'Chair' => l?.activityLivePoseChair ?? 'Chair',
    'Pigeon' => l?.activityLivePosePigeon ?? 'Pigeon',
    'Bridge' => l?.activityLivePoseBridge ?? 'Bridge',
    "Child's pose" => l?.activityLivePoseChildsPose ?? "Child's pose",
    'Savasana' => l?.activityLivePoseSavasana ?? 'Savasana',
    _ => key,
  };
}

/// The three-up row every live screen ends with.
List<(String, String)> _commonStats(
    BuildContext c, Activity a, LiveFeed feed, double? weightKg, int elapsed) {
  final l = AppLocalizations.of(c);
  final kcal = _kcal(a, feed, weightKg, elapsed);
  return [
    if (kcal != null) ('$kcal', l?.activityLiveKcalEstUnit ?? 'kcal · est'),
    if (feed.strain != null)
      (feed.strain!.toStringAsFixed(1), l?.activityLiveStrainUnit ?? 'strain'),
    if (feed.steps != null) ('${feed.steps}', l?.activityLiveStepsUnit ?? 'steps'),
  ];
}

ActivityResult _baseResult(
  Activity a,
  LiveFeed feed,
  double? weightKg,
  int elapsed,
  bool private, {
  StrengthLog strength = StrengthLog.empty,
  List<int> lapSecs = const [],
  int? poolLengthM,
  String? stroke,
  List<IntervalRound> rounds = const [],
  List<String> poses = const [],
  List<(int, int)> gameScore = const [],
}) =>
    ActivityResult(
      a,
      // When the session was really started. Derived from the elapsed clock
      // only without a draft (tests, previews) — and that derivation is wrong
      // for a paused session, which began earlier than `now - elapsed`.
      //
      // `Motion.tick * elapsed` rather than a literal: theme.dart is the only
      // file allowed to spell a Duration, and one second times N seconds is
      // exactly what this is.
      start: LiveDraft.current?.startedAt ??
          DateTime.now().subtract(Motion.tick * elapsed),
      duration: Motion.tick * elapsed,
      private: private,
      // The AVERAGE, from the per-minute curve. This used to be `feed.hr` —
      // the single instantaneous sample that happened to be on screen when
      // the user pressed stop, labelled "Avg HR" on the summary.
      avgHr: feed.avgHr,
      maxHr: feed.maxHr,
      calories: _kcal(a, feed, weightKg, elapsed),
      strain: feed.strain,
      hr: feed.hrCurve,
      zoneMinutes: feed.zoneMinutes,
      zoneSource: feed.zoneSource,
      zoneMaxHr: feed.zoneMaxHr,
      // The same count the live screen has printed all session, carried onto
      // the summary it hands over to. Null stays null: `stopWorkout` only banks
      // `sessions.steps` when there is one, so an unmeasured session reads the
      // same before and after it is stored.
      steps: feed.steps,
      route: feed.route,
      distanceKm: feed.distanceKm,
      strength: strength,
      lapSecs: lapSecs,
      poolLengthM: poolLengthM,
      stroke: stroke,
      rounds: rounds,
      poses: poses,
      gameScore: gameScore,
    );

// ══════════════ MEASURED — route, journey, power, basic ══════════════

class LiveMeasured extends StatelessWidget {
  final Activity a;
  final LiveFeedSource? feed;
  final double? weightKg;
  final bool private;
  final SessionFinish? onFinish;

  const LiveMeasured(this.a,
      {super.key,
      this.feed,
      this.weightKg,
      this.private = false,
      this.onFinish});

  @override
  Widget build(BuildContext c) {
    return LiveShell(
      a,
      private: private,
      weightKg: weightKg,
      onFinish: onFinish,
      result: (elapsed) =>
          _baseResult(a, feed?.call() ?? LiveFeed.none, weightKg, elapsed,
              private),
      body: (ctx, elapsed) {
        final p = P.of(ctx);
        final l = AppLocalizations.of(ctx);
        final f = feed?.call() ?? LiveFeed.none;
        return Column(children: [
          const SizedBox(height: S.x6),
          Text(l?.activityLiveDurationHeader ?? 'DURATION',
              style: F.over.copyWith(color: p.ink3)),
          const SizedBox(height: S.x3),
          bigNum(p, clock(elapsed), ''),
          // Only once fixes are actually arriving. The catalogue's `gps` flag
          // says a route is WORTH recording, not that one is being recorded —
          // it claimed "GPS ACTIVE" with location denied.
          if (f.gpsActive) ...[
            const SizedBox(height: S.x3),
            Pill(l?.activityLiveRecordingRoute ?? 'Recording route', C.green,
                icon: LucideIcons.mapPin),
          ] else if (_routeIssueCard(ctx, f.routeIssue, f.onFixRoute)
              case final card?) ...[
            const SizedBox(height: S.x4),
            card,
          ],
          const SizedBox(height: S.x8),
          // The user's own unit system, not km hardcoded. `unitsOf` is null in
          // a golden, and the metric fallback there is what the store holds.
          ..._distanceStats(ctx, p, f, a, weightKg, elapsed),
          const SizedBox(height: S.x8),
          LiveHeart(f),
          if (f.route.length > 1) ...[
            const SizedBox(height: S.x5),
            ChartFrame(
              title: l?.activityLiveRouteSoFarTitle ?? 'ROUTE SO FAR',
              unit: _distanceUnit(ctx),
              height: 150,
              footnote: f.distanceKm == null
                  ? (l?.activityLiveRouteFootnoteNoDistance ??
                      'Start pinned; distance appears once the fixes settle.')
                  : (l?.activityLiveRouteFootnoteWithDistance(
                          _distanceText(ctx, f.distanceKm!)) ??
                      '${_distanceText(ctx, f.distanceKm!)} from the fixes '
                          'recorded so far.'),
              child: ClipRRect(
                borderRadius: R.rLg,
                child: Container(
                  color: p.card2,
                  child: CustomPaint(
                      size: Size.infinite,
                      painter: RouteMap(f.route,
                          slow: p.on(a.color),
                          fast: p.on(a.color),
                          pinStart: p.on(C.green),
                          pinEnd: p.on(C.red),
                          pinInk: p.card)),
                ),
              ),
            ),
          ],
          if (private) ...[
            const SizedBox(height: S.x5),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(LucideIcons.lock, size: 12, color: p.ink3),
              const SizedBox(width: S.x1),
              Text(l?.activityLivePrivateSession ?? 'Private session',
                  style: F.over.copyWith(color: p.ink3)),
            ]),
          ],
        ]);
      },
    );
  }
}

// ══════════════ STRENGTH — everything here is typed ══════════════

class LiveStrength extends StatefulWidget {
  final Activity a;
  final LiveFeedSource? feed;
  final double? weightKg;
  final bool private;
  final Map<String, SetHistory> history;
  final SessionFinish? onFinish;

  /// Banks the log on every change. See [ActivityHost.onSets].
  final void Function(List<LoggedSet>)? onSets;

  const LiveStrength(this.a,
      {super.key,
      this.feed,
      this.weightKg,
      this.private = false,
      this.history = const {},
      this.onFinish,
      this.onSets});

  @override
  State<LiveStrength> createState() => _LiveStrengthState();
}

class _LiveStrengthState extends State<LiveStrength> {
  /// The exercises this session has touched, in the order they were added.
  final plan = <String>['bench_press'];
  int index = 0;

  double kg = 40;
  int reps = 8;
  int rpe = 7;
  bool bodyweight = false;

  final logged = <LoggedSet>[];

  static const restTarget = 90;

  /// A listenable rather than a field behind `setState`, for the same reason
  /// [LiveShellState.clock] is one: the countdown ticks once a second for a
  /// minute and a half between sets, and putting it behind `setState` rebuilt
  /// this state, and with it the whole [LiveShell] — header, transport,
  /// footer, body — when the only thing that moved was the ring.
  ///
  /// `setState` still runs at the ZERO CROSSING, where the screen genuinely
  /// changes shape: the footer flips back to Log set and the body back to the
  /// entry pad.
  final restLeft = ValueNotifier<int>(0);
  Timer? _rest;

  @override
  void initState() {
    super.initState();
    _restore();
    _seedFromHistory();
  }

  @override
  void dispose() {
    _rest?.cancel();
    restLeft.dispose();
    super.dispose();
  }

  /// Sets logged before this screen was rebuilt — the session was minimised,
  /// or the process was killed and relaunched. Nothing measures a bench press,
  /// so these bytes cannot be recovered from anywhere else.
  void _restore() {
    final saved = LiveDraft.current?.data['sets'];
    if (saved is! List) return;
    for (final e in saved) {
      if (e is! Map) continue;
      final k = e['k'];
      if (k is! String) continue;
      logged.add(LoggedSet(
        k,
        (e['reps'] as num?)?.toInt() ?? 0,
        loadKg: (e['kg'] as num?)?.toDouble(),
        rpe: (e['rpe'] as num?)?.toInt(),
        restSec: (e['rest'] as num?)?.toInt(),
        at: DateTime.fromMillisecondsSinceEpoch((e['at'] as num?)?.toInt() ?? 0),
      ));
      if (!plan.contains(k)) plan.add(k);
    }
    if (logged.isNotEmpty) index = plan.indexOf(logged.last.exerciseKey);
  }

  /// Write the log through — to the draft, so minimising cannot lose it, and
  /// to the app, which banks it against the open session row. Called on every
  /// change rather than at finish: `saveStrengthSets` replaces by sequence, so
  /// re-sending the whole log is the same rows every time.
  void _persist() {
    LiveDraft.current?.put('sets', [
      for (final s in logged)
        {
          'k': s.exerciseKey,
          'reps': s.reps,
          'kg': s.loadKg,
          'rpe': s.rpe,
          'rest': s.restSec,
          'at': s.at.millisecondsSinceEpoch,
        },
    ]);
    widget.onSets?.call(List.of(logged));
  }

  String get key => plan[index];
  ExerciseDef? get def => exerciseByKey(key);
  List<LoggedSet> get setsHere =>
      [for (final s in logged) if (s.exerciseKey == key) s];
  StrengthLog get log => StrengthLog(logged);

  /// Open each exercise at what the user did last time. Nothing to go on →
  /// leave the stepper where it is rather than guessing a load.
  void _seedFromHistory() {
    final prev = widget.history[key]?.previous;
    if (prev == null) return;
    setState(() {
      bodyweight = prev.loadKg == null;
      kg = prev.loadKg ?? kg;
      reps = prev.reps;
    });
  }

  void logSet() {
    HapticFeedback.mediumImpact();
    final now = DateTime.now();
    // The rest ACTUALLY taken before this set, not the 90 s target — the
    // target is what the timer counted down, the gap is what happened.
    final prior = logged.isEmpty ? null : logged.last.at;
    setState(() {
      logged.add(LoggedSet(key, reps,
          loadKg: bodyweight ? null : kg,
          rpe: rpe,
          restSec: prior == null ? null : now.difference(prior).inSeconds,
          at: now));
    });
    restLeft.value = restTarget;
    _persist();
    _rest?.cancel();
    _rest = Timer.periodic(Motion.tick, (t) {
      if (!mounted) return;
      restLeft.value--;
      if (restLeft.value <= 0) {
        t.cancel();
        // The one tick the shell has to see — see [restLeft].
        setState(() {});
        HapticFeedback.mediumImpact();
        // A buzz is not a message. The rest-over moment was reachable only by
        // feeling the watch, or by watching a number nobody was told to watch.
        say(context,
            AppLocalizations.of(context)?.activityLiveRestOverAnnounce ??
                'Rest over');
      }
    });
  }

  void goExercise(int i) {
    if (i < 0 || i >= plan.length) return;
    _rest?.cancel();
    restLeft.value = 0;
    setState(() => index = i);
    _seedFromHistory();
  }

  Future<void> addExercise() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      // A sheet does not consult `pageTransitionsTheme`, so reduced motion has
      // to be handed to it here or the panel slides up at full duration.
      sheetAnimationStyle: sheetMotion(context),
      backgroundColor: P.of(context).card,
      shape: const RoundedRectangleBorder(borderRadius: R.rXl),
      builder: (c) {
        final p = P.of(c);
        final l = AppLocalizations.of(c);
        return SafeArea(
          child: ListView(shrinkWrap: true, children: [
            Padding(
              padding: const EdgeInsets.all(S.x4),
              child: Text(l?.activityLiveAddExerciseTitle ?? 'Add exercise',
                  style: F.head.copyWith(color: p.ink)),
            ),
            for (final e in exerciseLibrary)
              Pressable(
                onTap: () => Navigator.pop(c, e.key),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: S.x4, vertical: S.x3),
                  child: Row(children: [
                    Expanded(
                        child: Text(e.label,
                            style: F.body.copyWith(color: p.ink))),
                    Text(e.muscles.keys.first,
                        style: F.over.copyWith(color: p.ink3)),
                  ]),
                ),
              ),
          ]),
        );
      },
    );
    if (picked == null) return;
    setState(() {
      if (!plan.contains(picked)) plan.add(picked);
      index = plan.indexOf(picked);
    });
    _seedFromHistory();
  }

  @override
  Widget build(BuildContext c) {
    final volume = log.volumeKg;
    final l = AppLocalizations.of(c);
    return LiveShell(
      widget.a,
      subtitle: volume == null
          ? (l?.activityLiveSetsCountSubtitle(log.setCount) ??
              '${log.setCount} SETS')
          : (l?.activityLiveVolumeSetsSubtitle(grouped(volume), log.setCount) ??
              '${grouped(volume)} KG · ${log.setCount} SETS'),
      private: widget.private,
      weightKg: widget.weightKg,
      onFinish: widget.onFinish,
      result: (elapsed) => _baseResult(widget.a,
          widget.feed?.call() ?? LiveFeed.none, widget.weightKg, elapsed,
          widget.private,
          strength: log),
      footer: (ctx) => restLeft.value > 0
          ? Row(children: [
              Expanded(
                child: BigButton('+30s',
                    color: C.teal,
                    soft: true,
                    // No `setState`: nothing on the shell changes shape while
                    // the countdown stays above zero, and the ring listens.
                    onTap: () => restLeft.value += 30),
              ),
              const SizedBox(width: S.x3),
              Expanded(
                child: BigButton(
                    AppLocalizations.of(ctx)?.activityLiveSkipRest ??
                        'Skip rest',
                    icon: LucideIcons.skipForward,
                    color: C.teal,
                    onTap: () {
                      _rest?.cancel();
                      restLeft.value = 0;
                      setState(() {});
                    }),
              ),
            ])
          : BigButton(AppLocalizations.of(ctx)?.activityLiveLogSet ?? 'Log set',
              icon: LucideIcons.plus, color: C.purple, onTap: logSet),
      // Nothing here is measured: the sets, reps and load are typed, and the
      // one live thing on the screen is the heart-rate block, which asks for
      // the tick itself.
      bodyFollowsClock: false,
      body: (ctx, _) => _body(ctx),
    );
  }

  Widget _body(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final volume = log.volumeKg;
    final hist = widget.history[key];
    return Column(children: [
      // running totals — the numbers that actually matter here
      Row(children: [
        Expanded(
            child: _total(
                p,
                volume == null ? (l?.activityLiveBwAbbrev ?? 'BW') : grouped(volume),
                volume == null
                    ? (l?.activityLiveBodyweightOnly ?? 'bodyweight only')
                    : (l?.activityLiveKgVolumeUnit ?? 'kg volume'))),
        Container(width: 1, height: 26, color: p.line),
        Expanded(child: _total(p, '${log.setCount}', l?.activityLiveSetsUnit ?? 'sets')),
        Container(width: 1, height: 26, color: p.line),
        Expanded(child: _total(p, '${log.repCount}', l?.activityLiveRepsUnit ?? 'reps')),
      ]),
      const SizedBox(height: S.x5),

      // exercise navigation
      Row(children: [
        Pressable(
          semanticLabel: l?.activityLivePreviousExercise ?? 'Previous exercise',
          onTap: () => goExercise(index - 1),
          child: Icon(LucideIcons.chevronLeft,
              size: 20, color: index == 0 ? p.line : p.ink3),
        ),
        Expanded(
          child: Column(children: [
            Text(
                l?.activityLiveExerciseOf(index + 1, plan.length) ??
                    'EXERCISE ${index + 1} OF ${plan.length}',
                style: F.over.copyWith(color: p.ink3)),
            const SizedBox(height: S.x1),
            Text(def?.label ?? key,
                textAlign: TextAlign.center,
                style: F.t2.copyWith(color: p.ink)),
          ]),
        ),
        Pressable(
          semanticLabel: l?.activityLiveNextExercise ?? 'Next exercise',
          onTap: () => index == plan.length - 1
              ? addExercise()
              : goExercise(index + 1),
          child: Icon(
              index == plan.length - 1
                  ? LucideIcons.plus
                  : LucideIcons.chevronRight,
              size: 20,
              color: p.ink3),
        ),
      ]),
      const SizedBox(height: S.x4),

      // set dots — one per set logged for this exercise, plus the one in hand
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(setsHere.length + 1, (i) {
          final filled = i < setsHere.length;
          return Container(
            margin: const EdgeInsets.symmetric(horizontal: S.x1),
            width: filled ? 11 : 9,
            height: filled ? 11 : 9,
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: filled ? p.on(C.purple) : null,
                border:
                    filled ? null : Border.all(color: p.line, width: 1.6)),
          );
        }),
      ),
      const SizedBox(height: S.x2),
      // Tabular: this counts up mid-lift, and proportional digits made the
      // label shuffle sideways on every set.
      Text(l?.activityLiveSetNumber(setsHere.length + 1) ??
              'Set ${setsHere.length + 1}',
          style: F.cap.copyWith(
              color: p.ink3,
              fontFeatures: const [FontFeature.tabularFigures()])),
      const SizedBox(height: S.x6),

      if (restLeft.value > 0)
        ValueListenableBuilder<int>(
          valueListenable: restLeft,
          builder: (_, _, _) => _rest_(p, c),
        )
      else
        ..._entry(p, c),

      const SizedBox(height: S.x6),
      if (setsHere.isNotEmpty) ...[
        Align(
            alignment: Alignment.centerLeft,
            child: Text(l?.activityLiveThisExerciseLabel ?? 'THIS EXERCISE',
                style: F.over.copyWith(color: p.ink3))),
        const SizedBox(height: S.x3),
        Surface(
          pad: const EdgeInsets.symmetric(horizontal: S.x4),
          child: Column(children: [
            for (var i = 0; i < setsHere.length; i++) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: S.x3),
                child: Row(children: [
                  Container(
                    width: 24,
                    height: 24,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                        color: p.wash(C.purple), borderRadius: R.rSm),
                    child: Text('${i + 1}',
                        style: F.over.copyWith(color: p.on(C.purple))),
                  ),
                  const SizedBox(width: S.x3),
                  Expanded(
                    child: Text(
                        setsHere[i].loadKg == null
                            ? (l?.activityLiveRepsBodyweightRow(
                                    setsHere[i].reps) ??
                                '${setsHere[i].reps} reps · bodyweight')
                            : '${_fmt(setsHere[i].loadKg!)} kg × '
                                '${setsHere[i].reps}',
                        style: F.body.copyWith(color: p.ink)),
                  ),
                  if (setsHere[i].rpe != null)
                    Text('RPE ${setsHere[i].rpe}',
                        style: F.cap.copyWith(color: p.ink3)),
                  if (setsHere[i].volume != null) ...[
                    const SizedBox(width: S.x3),
                    Text('${grouped(setsHere[i].volume!)} kg',
                        style: F.cap.copyWith(
                            color: p.ink2, fontWeight: FontWeight.w600)),
                  ],
                ]),
              ),
              if (i < setsHere.length - 1) Divider(color: p.line, height: 1),
            ],
          ]),
        ),
        const SizedBox(height: S.x5),
      ],

      // references
      if (hist?.previous != null || hist?.best != null) ...[
        Row(children: [
          Expanded(
              child: _ref(c, p, l?.activityLivePreviousLabel ?? 'Previous',
                  hist?.previous)),
          const SizedBox(width: S.x3),
          Expanded(
              child: _ref(c, p, l?.activityLiveBestLabel ?? 'Best',
                  hist?.best, gold: true)),
        ]),
        const SizedBox(height: S.x5),
      ],
      LiveTick((_, _) => LiveHeart(widget.feed?.call() ?? LiveFeed.none)),
    ]);
  }

  List<Widget> _entry(P p, BuildContext c) {
    final l = AppLocalizations.of(c);
    return [
        _stepper(
            c,
            p,
            l?.activityLiveWeightLabel ?? 'WEIGHT',
            bodyweight ? (l?.activityLiveBwAbbrev ?? 'BW') : _fmt(kg),
            bodyweight ? '' : 'kg',
            () => setState(() =>
                kg = (kg - (def?.step ?? 2.5)).clamp(0, 500).toDouble()),
            () => setState(() => kg = kg + (def?.step ?? 2.5))),
        const SizedBox(height: S.x3),
        Pressable(
          onTap: () => setState(() => bodyweight = !bodyweight),
          child: Text(
              bodyweight
                  ? (l?.activityLiveBodyweightExcludedNote ??
                      'Bodyweight — left out of volume')
                  : (l?.activityLiveLogAsBodyweight ?? 'Log as bodyweight'),
              style: F.cap.copyWith(color: p.on(C.purple))),
        ),
        const SizedBox(height: S.x5),
        _stepper(c, p, l?.activityLiveRepsLabel ?? 'REPS', '$reps', '',
            () => setState(() => reps = (reps - 1).clamp(1, 100)),
            () => setState(() => reps = reps + 1)),
        const SizedBox(height: S.x5),
        Align(
            alignment: Alignment.centerLeft,
            child: Text(l?.activityLiveEffortRpeHeader ?? 'EFFORT (RPE)',
                style: F.over.copyWith(color: p.ink3))),
        const SizedBox(height: S.x3),
        Row(
          children: List.generate(5, (i) {
            final v = i + 6; // Borg CR-10 reps-in-reserve range
            final on = rpe == v;
            const cols = [C.green, C.teal, C.blue, C.orange, C.red];
            return Expanded(
              child: Pressable(
                semanticLabel: 'RPE $v',
                onTap: () => setState(() => rpe = v),
                child: Container(
                  margin: EdgeInsets.only(right: i == 4 ? 0 : S.x2),
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                      color: on ? p.fill(cols[i]) : p.wash(cols[i]),
                      borderRadius: R.rMd),
                  child: Text('$v',
                      style: F.head.copyWith(
                          color: on ? p.inkOnFill : p.on(cols[i]))),
                ),
              ),
            );
          }),
        ),
      ];
  }

  Widget _rest_(P p, BuildContext c) {
    final l = AppLocalizations.of(c);
    return Column(children: [
        Text(l?.activityLiveRestingHeader ?? 'RESTING',
            style: F.over.copyWith(color: p.on(C.teal))),
        const SizedBox(height: S.x3),
        SizedBox(
          width: 170,
          height: 170,
          child: Stack(alignment: Alignment.center, children: [
            CustomPaint(
                size: const Size(170, 170),
                painter:
                    Ring(restLeft.value / restTarget, p.on(C.teal), p.track)),
            Column(mainAxisSize: MainAxisSize.min, children: [
              Text(clock(restLeft.value), style: F.n34.copyWith(color: p.ink)),
              if (logged.isNotEmpty)
                Text(
                    logged.last.loadKg == null
                        ? (l?.activityLiveRepsLoggedBodyweight(
                                logged.last.reps) ??
                            '${logged.last.reps} reps logged')
                        : (l?.activityLiveWeightRepsLogged(
                                _fmt(logged.last.loadKg!), logged.last.reps) ??
                            '${_fmt(logged.last.loadKg!)} kg × '
                                '${logged.last.reps} logged'),
                    style: F.cap.copyWith(color: p.ink3)),
            ]),
          ]),
        ),
      ]);
  }

  Widget _stepper(BuildContext c, P p, String label, String value,
          String unit, VoidCallback minus, VoidCallback plus) {
    final l = AppLocalizations.of(c);
    return Column(children: [
        Text(label, style: F.over.copyWith(color: p.ink3)),
        const SizedBox(height: S.x3),
        Row(children: [
          counterButton(p, LucideIcons.minus, p.ink,
              l?.activityLiveDecrease(label) ?? '$label down', minus),
          Expanded(child: bigNum(p, value, unit)),
          counterButton(p, LucideIcons.plus, p.ink,
              l?.activityLiveIncrease(label) ?? '$label up', plus),
        ]),
      ]);
  }

  Widget _total(P p, String v, String l) => Column(children: [
        Text(v, style: F.n17.copyWith(color: p.ink)),
        Text(l,
            style: F.over.copyWith(color: p.ink3),
            textAlign: TextAlign.center),
      ]);

  Widget _ref(BuildContext c, P p, String label, LoggedSet? s,
      {bool gold = false}) {
    final l = AppLocalizations.of(c);
    return Surface(
        pad: const EdgeInsets.symmetric(horizontal: S.x3, vertical: S.x3),
        child: Column(children: [
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (gold) ...[
              Icon(LucideIcons.trophy, size: 12, color: p.on(C.yellow)),
              const SizedBox(width: S.x1),
            ],
            Text(label.toUpperCase(),
                style: F.over
                    .copyWith(color: gold ? p.on(C.yellow) : p.ink3)),
          ]),
          const SizedBox(height: S.x2),
          Text(
              s == null
                  ? (l?.activityLiveNoneYet ?? 'None yet')
                  : s.loadKg == null
                      ? (l?.activityLiveRepsOnly(s.reps) ?? '${s.reps} reps')
                      : '${_fmt(s.loadKg!)} kg × ${s.reps}',
              style: F.cap
                  .copyWith(color: p.ink, fontWeight: FontWeight.w600)),
        ]),
      );
  }

  String _fmt(double d) =>
      d == d.roundToDouble() ? d.round().toString() : d.toStringAsFixed(1);
}

// ══════════════ SWIMMING — laps are counted, not measured ══════════════

class LiveSwim extends StatefulWidget {
  final Activity a;
  final LiveFeedSource? feed;
  final double? weightKg;
  final bool private;
  final SessionFinish? onFinish;
  const LiveSwim(this.a,
      {super.key,
      this.feed,
      this.weightKg,
      this.private = false,
      this.onFinish});

  @override
  State<LiveSwim> createState() => _LiveSwimState();
}

class _LiveSwimState extends State<LiveSwim> {
  int poolLen = 25;
  int stroke = 0;
  final lapAt = <int>[]; // elapsed seconds at each lap
  static const strokes = ['Free', 'Back', 'Breast', 'Fly'];
  static const pools = [20, 25, 33, 50];

  /// One lap per tap. A separate counter beside the timestamps is how this
  /// screen and the summary came to report different distances for the same
  /// swim.
  int get laps => lapAt.length;

  /// Seconds per lap, from the taps. The FIRST lap is measured from the start
  /// of the session; taking only the gaps between taps produced one time
  /// fewer than there were laps, and the summary — which counts these — then
  /// reported every swim one lap and one pool length short.
  ///
  /// Real units: the relative bar heights are derived from these on the way to
  /// the painter, not stored instead of them.
  List<int> get lapSecs => [
        for (var i = 0; i < lapAt.length; i++)
          lapAt[i] - (i == 0 ? 0 : lapAt[i - 1]),
      ];

  @override
  void initState() {
    super.initState();
    // Laps are counted by hand — nothing can recount them. Restore whatever
    // was tapped before this screen was rebuilt.
    final d = LiveDraft.current;
    if (d == null) return;
    for (final e in (d.data['lap_at'] as List? ?? const [])) {
      if (e is num) lapAt.add(e.toInt());
    }
    poolLen = (d.data['pool'] as num?)?.toInt() ?? poolLen;
    stroke = (d.data['stroke'] as num?)?.toInt() ?? stroke;
  }

  void _persist() {
    final d = LiveDraft.current;
    if (d == null) return;
    d.put('lap_at', List<int>.of(lapAt));
    d.put('pool', poolLen);
    d.put('stroke', stroke);
  }

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    return LiveShell(
      widget.a,
      subtitle: l?.activityLivePoolSubtitle(
              poolLen, _strokeLabel(c, strokes[stroke]).toUpperCase()) ??
          '${poolLen}M POOL · ${strokes[stroke].toUpperCase()}',
      private: widget.private,
      weightKg: widget.weightKg,
      onFinish: widget.onFinish,
      result: (elapsed) => _baseResult(widget.a,
          widget.feed?.call() ?? LiveFeed.none, widget.weightKg, elapsed,
          widget.private,
          lapSecs: lapSecs,
          poolLengthM: poolLen,
          stroke: strokes[stroke]),
      body: (ctx, elapsed) {
        final p = P.of(ctx);
        final l = AppLocalizations.of(ctx);
        final f = widget.feed?.call() ?? LiveFeed.none;
        return Column(children: [
          const SizedBox(height: S.x5),
          bigNum(p, '${laps * poolLen}', 'm'),
          const SizedBox(height: S.x2),
          Text(
              l?.activityLiveLapsCount(laps, _strokeLabel(ctx, strokes[stroke])) ??
                  '$laps ${laps == 1 ? 'lap' : 'laps'} · ${strokes[stroke]}',
              style: F.body.copyWith(color: p.ink3)),
          const SizedBox(height: S.x6),
          statRow(p, [
            (clock(elapsed), l?.activityLiveTimeUnit ?? 'time'),
            if (laps > 0)
              (clock(elapsed ~/ laps), l?.activityLivePerLapUnit ?? 'per lap'),
            ..._commonStats(ctx, widget.a, f, widget.weightKg, elapsed),
          ].take(3).toList()),
          const SizedBox(height: S.x8),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            counterButton(p, LucideIcons.minus, p.ink,
                l?.activityLiveOneLapFewer ?? 'One lap fewer', () {
              if (lapAt.isEmpty) return;
              setState(() => lapAt.removeLast());
              _persist();
            }),
            const SizedBox(width: S.x6),
            Pressable(
              semanticLabel: l?.activityLiveAddALap ?? 'Add a lap',
              onTap: () {
                HapticFeedback.mediumImpact();
                setState(() => lapAt.add(elapsed));
                _persist();
              },
              child: Container(
                width: 110,
                height: 110,
                decoration: BoxDecoration(
                    color: p.fill(C.blue), shape: BoxShape.circle),
                child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(LucideIcons.plus, size: 30, color: p.inkOnFill),
                      Text(l?.activityLiveLapButtonLabel ?? 'LAP',
                          style: F.over.copyWith(color: p.inkOnFill)),
                    ]),
              ),
            ),
            const SizedBox(width: S.x6),
            counterButton(p, LucideIcons.repeat2, p.ink,
                l?.activityLiveChangeStroke ?? 'Change stroke', () {
              setState(() => stroke = (stroke + 1) % strokes.length);
              _persist();
            }),
          ]),
          const SizedBox(height: S.x6),
          Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final len in pools) ...[
                  Pressable(
                    semanticLabel:
                        l?.activityLiveMetrePoolLabel(len) ?? '$len metre pool',
                    onTap: () {
                      setState(() => poolLen = len);
                      _persist();
                    },
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: S.x1),
                      padding: const EdgeInsets.symmetric(
                          horizontal: S.x3, vertical: S.x2),
                      decoration: BoxDecoration(
                          color:
                              poolLen == len ? p.wash(C.blue) : p.card2,
                          borderRadius: R.rPill),
                      child: Text('$len m',
                          style: F.cap.copyWith(
                              color: poolLen == len
                                  ? p.on(C.blue)
                                  : p.ink2)),
                    ),
                  ),
                ],
              ]),
          const SizedBox(height: S.x5),
          Builder(builder: (_) {
            final secs = lapSecs;
            if (secs.isEmpty) return const SizedBox.shrink();
            final fastest = secs.reduce((x, y) => x < y ? x : y);
            return ChartFrame(
              title: l?.activityLiveLapsChartTitle ?? 'LAPS',
              unit: 'seconds per lap',
              height: 20.0 * secs.length,
              xLabels: [
                l?.activityLiveLapXLabel(1) ?? 'Lap 1',
                l?.activityLiveLapXLabel(secs.length) ?? 'Lap ${secs.length}',
              ],
              footnote: l?.activityLiveLapsFootnote(clock(fastest)) ??
                  'Fastest ${clock(fastest)} · bar length is speed '
                      'against it.',
              child: CustomPaint(
                  size: Size.infinite,
                  painter: LapBars(
                      [for (final t in secs) t <= 0 ? 1.0 : fastest / t],
                      p.on(C.blue),
                      p.track)),
            );
          }),
          const SizedBox(height: S.x5),
          LiveHeart(f),
        ]);
      },
    );
  }
}

// ══════════════ FLOW — poses are stepped, breath is paced ══════════════

class LiveFlow extends StatefulWidget {
  final Activity a;
  final LiveFeedSource? feed;
  final double? weightKg;
  final bool private;
  final SessionFinish? onFinish;
  const LiveFlow(this.a,
      {super.key,
      this.feed,
      this.weightKg,
      this.private = false,
      this.onFinish});

  @override
  State<LiveFlow> createState() => _LiveFlowState();
}

class _LiveFlowState extends State<LiveFlow>
    with SingleTickerProviderStateMixin {
  static const poses = [
    'Mountain', 'Forward fold', 'Plank', 'Warrior II', 'Triangle',
    'Chair', 'Pigeon', 'Bridge', 'Child\'s pose', 'Savasana',
  ];

  int pose = 0;

  /// The furthest pose this session actually reached.
  ///
  /// The record used to be `poses.sublist(0, pose + 1)` off the LIVE index,
  /// so stepping back to hold Bridge again deleted the two poses after it from
  /// a session in which they were done — and going back to Mountain at the end
  /// recorded '1 poses'.
  int reached = 0;
  int hold = 30;
  Timer? _hold;

  /// The breath ring's phase. Owned here, not by the painter, and it only
  /// runs while the platform allows animation — the ring is a pacer, so with
  /// motion off it simply rests open instead of looping invisibly.
  late final AnimationController breath =
      AnimationController(vsync: this, duration: Motion.breath)
        ..addStatusListener((s) {
          if (!mounted) return;
          if (s == AnimationStatus.completed) breath.reverse();
          if (s == AnimationStatus.dismissed) breath.forward();
        });

  @override
  void initState() {
    super.initState();
    pose = (LiveDraft.current?.data['pose'] as num?)?.toInt() ?? 0;
    reached = (LiveDraft.current?.data['pose_max'] as num?)?.toInt() ?? pose;
    // No `setState`: this body follows the shell's clock, which already
    // rebuilds it once a second, so the wrapper only bought a second rebuild
    // of the same subtree at the same rate.
    //
    // WHICH IS WHY THE PAUSE CHECK IS HERE. A paused session stops advancing
    // `elapsedSec`, so the shell stops repainting — and a hold that kept
    // counting behind a frozen screen would sit there wrong and then jump on
    // resume. It is a pacer for a pose being held; a paused session is not
    // holding anything.
    _hold = Timer.periodic(Motion.tick, (_) {
      if (!mounted || LiveDraft.current?.pausedAt != null) return;
      hold = hold > 0 ? hold - 1 : 30;
    });
  }

  /// Where in the sequence the session is. The hold countdown is not saved —
  /// it is a pacer, and restarting it on resume is honest.
  void _go(int to) {
    setState(() {
      pose = to.clamp(0, poses.length - 1);
      if (pose > reached) reached = pose;
      hold = 30;
    });
    LiveDraft.current?.put('pose', pose);
    LiveDraft.current?.put('pose_max', reached);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Both directions. The gate used to guard only the START, so turning
    // reduced motion on mid-session left the ring looping anyway — and there is
    // no way to turn it back off from inside a yoga flow.
    final on = Motion.enabled(context);
    if (on && !breath.isAnimating) {
      breath.forward();
    } else if (!on && breath.isAnimating) {
      breath.stop();
    }
  }

  @override
  void dispose() {
    _hold?.cancel();
    breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    return LiveShell(
      widget.a,
      subtitle: l?.activityLivePoseOf(pose + 1, poses.length) ??
          'POSE ${pose + 1} OF ${poses.length}',
      private: widget.private,
      weightKg: widget.weightKg,
      onFinish: widget.onFinish,
      result: (elapsed) => _baseResult(widget.a,
          widget.feed?.call() ?? LiveFeed.none, widget.weightKg, elapsed,
          widget.private,
          poses: poses.sublist(0, reached + 1)),
      body: (ctx, elapsed) {
        final p = P.of(ctx);
        final l = AppLocalizations.of(ctx);
        final f = widget.feed?.call() ?? LiveFeed.none;
        return Column(children: [
          const SizedBox(height: S.x4),
          bigNum(p, clock(elapsed), ''),
          const SizedBox(height: S.x6),
          Container(
            height: 210,
            decoration: BoxDecoration(
                borderRadius: R.rXl, color: p.wash(C.teal)),
            child: Stack(alignment: Alignment.center, children: [
              AnimatedBuilder(
                animation: breath,
                // Through `animate`, or reduced motion draws the pacer
                // PERMANENTLY COLLAPSED: `forward()` never runs, the value
                // stays 0, and `BreathRing` bottoms out at 55% of its radius.
                // Reduced motion made the ring wrong, not still.
                builder: (_, _) => CustomPaint(
                    size: const Size(170, 170),
                    painter: BreathRing(
                        animate(ctx, Curves.easeInOut.transform(breath.value)),
                        p.on(C.teal))),
              ),
              Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(LucideIcons.personStanding,
                    size: 46, color: p.on(C.teal)),
                const SizedBox(height: S.x2),
                Text(_poseLabel(ctx, poses[pose]),
                    style: F.t2.copyWith(color: p.ink)),
                const SizedBox(height: S.x1),
                Text(l?.activityLiveHoldTime(clock(hold)) ??
                    'Hold · ${clock(hold)}',
                    style: F.cap.copyWith(color: p.on(C.teal))),
              ]),
            ]),
          ),
          const SizedBox(height: S.x4),
          Row(children: [
            Expanded(
              child: BigButton(l?.activityLivePreviousLabel ?? 'Previous',
                  icon: LucideIcons.chevronLeft,
                  color: C.teal,
                  soft: true,
                  onTap: () => _go(pose - 1)),
            ),
            const SizedBox(width: S.x3),
            Expanded(
              child: BigButton(l?.activityLiveNextPose ?? 'Next pose',
                  icon: LucideIcons.chevronRight,
                  color: C.teal,
                  onTap: () => _go(pose + 1)),
            ),
          ]),
          const SizedBox(height: S.x5),
          Row(
            children: List.generate(
                poses.length,
                (i) => Expanded(
                      child: Container(
                        margin: EdgeInsets.only(
                            right: i == poses.length - 1 ? 0 : 3),
                        height: 5,
                        decoration: BoxDecoration(
                            color: i <= pose ? p.on(C.teal) : p.track,
                            borderRadius: R.rPill),
                      ),
                    )),
          ),
          const SizedBox(height: S.x6),
          LiveHeart(f),
        ]);
      },
    );
  }
}

// ══════════════ MATCH — the score is the parameter ══════════════

class LiveMatch extends StatefulWidget {
  final Activity a;
  final LiveFeedSource? feed;
  final double? weightKg;
  final bool private;
  final SessionFinish? onFinish;
  const LiveMatch(this.a,
      {super.key,
      this.feed,
      this.weightKg,
      this.private = false,
      this.onFinish});

  @override
  State<LiveMatch> createState() => _LiveMatchState();
}

class _LiveMatchState extends State<LiveMatch> {
  int me = 0, them = 0;
  final sets = <(int, int)>[];

  @override
  void initState() {
    super.initState();
    // The score is typed, so it restores with the session. Stored flat —
    // [me, them, me, them, …] — because JSON has no tuples.
    final d = LiveDraft.current;
    if (d == null) return;
    final v = [
      for (final e in (d.data['score'] as List? ?? const []))
        if (e is num) e.toInt(),
    ];
    for (var i = 0; i + 1 < v.length; i += 2) {
      sets.add((v[i], v[i + 1]));
    }
    me = (d.data['me'] as num?)?.toInt() ?? 0;
    them = (d.data['them'] as num?)?.toInt() ?? 0;
  }

  /// Change the score and bank it in the same breath.
  void _score(VoidCallback change) {
    setState(change);
    _persist();
  }

  /// Every point and every closed set, the moment it is entered.
  void _persist() {
    final d = LiveDraft.current;
    if (d == null) return;
    d.put('score', [for (final s in sets) ...[s.$1, s.$2]]);
    d.put('me', me);
    d.put('them', them);
  }

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    return LiveShell(
      widget.a,
      subtitle: l?.activityLiveMatchSetSubtitle(sets.length + 1) ??
          'SET ${sets.length + 1}',
      private: widget.private,
      weightKg: widget.weightKg,
      onFinish: widget.onFinish,
      result: (elapsed) => _baseResult(widget.a,
          widget.feed?.call() ?? LiveFeed.none, widget.weightKg, elapsed,
          widget.private,
          gameScore: [...sets, if (me > 0 || them > 0) (me, them)]),
      body: (ctx, elapsed) {
        final p = P.of(ctx);
        final l = AppLocalizations.of(ctx);
        final f = widget.feed?.call() ?? LiveFeed.none;
        return Column(children: [
          const SizedBox(height: S.x4),
          bigNum(p, clock(elapsed), ''),
          const SizedBox(height: S.x6),
          Row(children: [
            Expanded(
                child: _side(ctx, p, l?.activityLiveYouLabel ?? 'YOU', me,
                    p.on(widget.a.color),
                    () => _score(() => me++),
                    () => _score(() => me = (me - 1).clamp(0, 99)))),
            Container(width: 1, height: 120, color: p.line),
            Expanded(
                child: _side(ctx, p, l?.activityLiveOpponentLabel ?? 'OPPONENT',
                    them, p.ink2,
                    () => _score(() => them++),
                    () => _score(() => them = (them - 1).clamp(0, 99)))),
          ]),
          const SizedBox(height: S.x5),
          BigButton(l?.activityLiveEndSet ?? 'End set',
              color: widget.a.color,
              soft: true,
              onTap: () => _score(() {
                    sets.add((me, them));
                    me = 0;
                    them = 0;
                  })),
          const SizedBox(height: S.x5),
          if (sets.isNotEmpty) ...[
            Align(
                alignment: Alignment.centerLeft,
                child: Text(l?.activityLiveSetsListHeader ?? 'SETS',
                    style: F.over.copyWith(color: p.ink3))),
            const SizedBox(height: S.x3),
            Surface(
              pad: const EdgeInsets.symmetric(horizontal: S.x4),
              child: Column(children: [
                for (var i = 0; i < sets.length; i++) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: S.x3),
                    child: Row(children: [
                      Expanded(
                          child: Text(
                              l?.activityLiveSetNumber(i + 1) ?? 'Set ${i + 1}',
                              style: F.body.copyWith(color: p.ink3))),
                      Text('${sets[i].$1} — ${sets[i].$2}',
                          style: F.n17.copyWith(
                              color: sets[i].$1 > sets[i].$2
                                  ? p.on(widget.a.color)
                                  : p.ink3)),
                    ]),
                  ),
                  if (i < sets.length - 1) Divider(color: p.line, height: 1),
                ],
              ]),
            ),
            const SizedBox(height: S.x5),
          ],
          LiveHeart(f),
        ]);
      },
    );
  }

  Widget _side(BuildContext c, P p, String label, int v, Color col,
      VoidCallback up, VoidCallback down) {
    final l = AppLocalizations.of(c);
    return Column(children: [
        Text(label, style: F.over.copyWith(color: p.ink3)),
        const SizedBox(height: S.x3),
        Pressable(
          semanticLabel: l?.activityLivePointLabel(label) ?? '$label point',
          onTap: () {
            HapticFeedback.mediumImpact();
            up();
          },
          child: Text('$v', style: F.n48.copyWith(color: col)),
        ),
        const SizedBox(height: S.x3),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          counterButton(p, LucideIcons.minus, p.ink2,
              l?.activityLiveDecrease(label) ?? '$label down', down,
              size: 40),
          const SizedBox(width: S.x3),
          counterButton(p, LucideIcons.plus, col,
              l?.activityLiveIncrease(label) ?? '$label up', up, size: 40),
        ]),
      ]);
  }
}

// ══════════════ INTERVAL — the rounds run themselves ══════════════

class LiveInterval extends StatefulWidget {
  final Activity a;
  final LiveFeedSource? feed;
  final double? weightKg;
  final bool private;
  final SessionFinish? onFinish;

  /// Chosen on the setup screen (defaults match the old hardcoded values —
  /// nothing to migrate for a draft that predates this).
  final int workSec;
  final int restSec;
  final int rounds;
  const LiveInterval(this.a,
      {super.key,
      this.feed,
      this.weightKg,
      this.private = false,
      this.onFinish,
      this.workSec = 45,
      this.restSec = 30,
      this.rounds = 8});

  @override
  State<LiveInterval> createState() => _LiveIntervalState();
}

class _LiveIntervalState extends State<LiveInterval> {
  // ponytail: the round position is not written to the draft — minimising a
  // HIIT session restarts it at round 1. Nothing here is typed, so nothing is
  // LOST; it is a timer, and a timer that keeps running while the screen is
  // gone needs the countdown to live on the draft's clock. Do that if anyone
  // actually minimises intervals.
  /// [widget.rounds] is how many pips the row starts with, NOT a plan the
  /// session runs to: nothing stops this timer at that round, so a session
  /// that keeps going simply grows the row.
  int round = 1;
  late int left;
  bool work = true;
  final done = <IntervalRound>[];
  Timer? _t;

  /// Heart-rate samples taken during the CURRENT round, so each finished
  /// round carries a real mean rather than the reading that happened to be on
  /// screen when it ended.
  final _roundHr = <int>[];

  @override
  void initState() {
    super.initState();
    left = widget.workSec;
    _t = Timer.periodic(Motion.tick, (_) {
      if (!mounted) return;
      // PAUSE STOPS THE INTERVAL ENGINE. Without this the countdown kept
      // running while the session was paused: it buzzed and announced
      // "Work"/"Rest" at a phone in your pocket, advanced the round pips, and
      // BANKED IntervalRounds you never performed — so a five-minute pause
      // wrote four rounds of 45 s work into the summary while the elapsed
      // clock, which does subtract pauses, said the session was shorter than
      // the rounds it listed.
      //
      // The heart-rate sample is skipped too: readings taken while you stand
      // still would drag the round's mean down toward resting.
      if (LiveDraft.current?.pausedAt != null) return;
      final hr = widget.feed?.call().hr;
      if (hr != null && hr > 0) _roundHr.add(hr);
      setState(() {
        if (left > 0) {
          left--;
          return;
        }
        HapticFeedback.mediumImpact();
        final l = AppLocalizations.of(context);
        say(
            context,
            work
                ? (l?.activityLiveRestWord ?? 'Rest')
                : (l?.activityLiveWorkWord ?? 'Work'));
        if (work) {
          work = false;
          left = widget.restSec;
        } else {
          done.add(IntervalRound(widget.workSec, widget.restSec,
              avgHr: _roundHr.isEmpty
                  ? null
                  : (_roundHr.reduce((x, y) => x + y) / _roundHr.length)
                      .round()));
          _roundHr.clear();
          work = true;
          left = widget.workSec;
          // UNCAPPED. `done` is unconditional and the timer never stops at the
          // configured round count, so `if (round < widget.rounds) round++`
          // froze the live counter while the summary counted more — two
          // screens, one session, two round counts. [widget.rounds] is the
          // pip row's floor now, not a limit the session has.
          round++;
        }
      });
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    return LiveShell(
      widget.a,
      subtitle: l?.activityLiveIntervalSubtitle(widget.workSec, widget.restSec) ??
          '${widget.workSec} S WORK · ${widget.restSec} S REST',
      private: widget.private,
      weightKg: widget.weightKg,
      onFinish: widget.onFinish,
      result: (elapsed) => _baseResult(widget.a,
          widget.feed?.call() ?? LiveFeed.none, widget.weightKg, elapsed,
          widget.private,
          rounds: done),
      body: (ctx, elapsed) {
        final p = P.of(ctx);
        final l = AppLocalizations.of(ctx);
        final f = widget.feed?.call() ?? LiveFeed.none;
        final col = work ? C.red : C.teal;
        // At least [widget.rounds] the row is drawn for, and more once the
        // session has done more. '/ 8' was a denominator nothing enforced.
        final pips = round > widget.rounds ? round : widget.rounds;
        return Column(children: [
          const SizedBox(height: S.x5),
          Text(l?.activityLiveRoundLabel(round) ?? 'ROUND $round',
              style: F.over.copyWith(color: p.ink3)),
          const SizedBox(height: S.x4),
          Text(clock(left), style: F.n48.copyWith(color: p.on(col))),
          const SizedBox(height: S.x2),
          Text(
              (work
                      ? (l?.activityLiveWorkWord ?? 'Work')
                      : (l?.activityLiveRestWord ?? 'Rest'))
                  .toUpperCase(),
              style: F.t2.copyWith(color: p.on(col), letterSpacing: 3)),
          const SizedBox(height: S.x5),
          ClipRRect(
            borderRadius: R.rPill,
            child: LinearProgressIndicator(
                value: left / (work ? widget.workSec : widget.restSec),
                minHeight: 10,
                backgroundColor: p.track,
                valueColor: AlwaysStoppedAnimation(p.on(col))),
          ),
          const SizedBox(height: S.x6),
          Surface(
            child: Row(children: [
              Text(l?.activityLiveNextLabel ?? 'NEXT',
                  style: F.over.copyWith(color: p.ink3)),
              const Spacer(),
              Text(
                  work
                      ? (l?.activityLiveNextRest(clock(widget.restSec)) ??
                          'Rest · ${clock(widget.restSec)}')
                      : (l?.activityLiveNextWork(clock(widget.workSec)) ??
                          'Work · ${clock(widget.workSec)}'),
                  style: F.body
                      .copyWith(color: p.ink, fontWeight: FontWeight.w600)),
            ]),
          ),
          const SizedBox(height: S.x5),
          Row(
            children: List.generate(
                pips,
                (i) => Expanded(
                      child: Container(
                        margin:
                            EdgeInsets.only(right: i == pips - 1 ? 0 : 4),
                        height: 6,
                        decoration: BoxDecoration(
                            color: i < round ? p.on(C.red) : p.track,
                            borderRadius: R.rPill),
                      ),
                    )),
          ),
          const SizedBox(height: S.x6),
          statRow(p, _commonStats(ctx, widget.a, f, widget.weightKg, elapsed)),
          const SizedBox(height: S.x6),
          LiveHeart(f),
        ]);
      },
    );
  }
}
