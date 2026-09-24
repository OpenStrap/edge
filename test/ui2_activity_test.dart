// The activity experience: catalogue, archetypes, strength maths, and the
// screens that render them.
//
// Three things this file is actually protecting:
//
//   1. Every activity has a published MET — bar the one catch-all row that
//      names no activity for one to apply to — and every archetype has a
//      screen, so the "different visual centre of gravity" claim is
//      checkable, not a design-doc assertion.
//   2. Volume never counts a bodyweight set as zero kilos. That single null
//      is why `load_kg` is nullable in the schema.
//   3. No screen renders a bare em-dash. Absence is a StatusCard, and the
//      widget tests sweep for the dash directly.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/gps/gps_source.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/ui2/activity/catalogue.dart';
import 'package:openstrap_edge/ui2/activity/day_strain.dart';
import 'package:openstrap_edge/ui2/activity/live.dart';
import 'package:openstrap_edge/ui2/activity/picker.dart';
import 'package:openstrap_edge/ui2/activity/poster.dart';
import 'package:openstrap_edge/ui2/activity/setup.dart';
import 'package:openstrap_edge/ui2/activity/share.dart';
import 'package:openstrap_edge/ui2/activity/summary.dart';
import 'package:openstrap_edge/ui2/activity/zones.dart';
import 'package:openstrap_edge/ui2/screens/workout_screen.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── deterministic fixtures ─────────────────────────────────────────────────

final _start = DateTime(2026, 5, 20, 7, 15);

Activity _first(Arch a) =>
    allActivities.firstWhere((x) => archOf(x) == a);

List<double> _series(int n, double base, double amp) =>
    [for (var i = 0; i < n; i++) base + (i * 37 % 23) - (i % 5) * amp];

final _sets = <LoggedSet>[
  LoggedSet('bench_press', 8,
      loadKg: 80, rpe: 7, at: _start.add(const Duration(minutes: 3))),
  LoggedSet('bench_press', 7,
      loadKg: 82.5, rpe: 8, at: _start.add(const Duration(minutes: 6))),
  LoggedSet('triceps_pushdown', 12,
      loadKg: 30, rpe: 7, at: _start.add(const Duration(minutes: 12))),
  LoggedSet('pull_up', 9, rpe: 8, at: _start.add(const Duration(minutes: 18))),
];

/// A fully-populated result for [arch] — every archetype's own data present,
/// so the goldens show the defining object rather than nine StatusCards.
ActivityResult _result(Arch arch) {
  final a = _first(arch);
  return ActivityResult(
    a,
    start: _start,
    duration: const Duration(minutes: 45, seconds: 28),
    avgHr: 148,
    maxHr: 176,
    calories: 612,
    strain: 12.4,
    hr: _series(120, 150, 3),
    zoneMinutes: const [4, 9, 17, 11, 4],
    route: arch == Arch.route || arch == Arch.journey
        ? [for (var i = 0; i < 60; i++) Offset(.1 + i / 75, .5 + (i % 9) / 30)]
        : const [],
    routePace: arch == Arch.route
        ? [for (var i = 0; i < 60; i++) (i % 10) / 10]
        : null,
    distanceKm: arch == Arch.route || arch == Arch.journey ? 8.72 : null,
    elevationM: arch == Arch.journey ? _series(80, 900, 12) : const [],
    gainM: arch == Arch.journey ? 642 : null,
    lossM: arch == Arch.journey ? 618 : null,
    splits: arch == Arch.route
        ? const [
            KmSplit(1, 308, avgHr: 152),
            KmSplit(1, 307, avgHr: 156),
            KmSplit(1, 312, avgHr: 162),
            KmSplit(1, 298, avgHr: 176),
          ]
        : const [],
    strength: arch == Arch.strength ? StrengthLog(_sets) : StrengthLog.empty,
    lapSecs: arch == Arch.laps ? const [38, 40, 41, 43, 45, 52] : const [],
    poolLengthM: arch == Arch.laps ? 25 : null,
    stroke: arch == Arch.laps ? 'Free' : null,
    rounds: arch == Arch.interval
        ? const [
            IntervalRound(45, 30, avgHr: 154),
            IntervalRound(45, 30, avgHr: 161),
            IntervalRound(45, 30, avgHr: 168),
            IntervalRound(45, 30, avgHr: 172),
          ]
        : const [],
    poses: arch == Arch.flow
        ? const ['Mountain', 'Plank', 'Warrior II']
        : const [],
    breathsPerMin: arch == Arch.flow ? 6.2 : null,
    gameScore: arch == Arch.match ? const [(6, 4), (4, 6)] : const [],
  );
}

Widget _frame(Widget child, Brightness b, double scale) => MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(b),
        home: child,
      ),
    );

Future<void> _loadType() async {
  final files = Directory('assets/fonts/Manrope')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.ttf'));
  for (final family in const ['Manrope', '.SF Pro Text']) {
    final loader = FontLoader(family);
    for (final f in files) {
      loader.addFont(f
          .readAsBytes()
          .then((b) => ByteData.sublistView(Uint8List.fromList(b))));
    }
    await loader.load();
  }
}

/// Enough repo for [DayStrainData.load]: the persisted strain curve and the
/// day's wear, which is all that screen reads.
class _StrainRepo extends LocalRepository {
  final List<Map<String, Object?>> curve;
  _StrainRepo(this.curve);

  @override
  Future<Map<String, dynamic>> getDayStrain(String date) async => {
        'curve': curve,
        'strain': 12.4,
        'zones': const {},
        'hr': const {'max': 168},
        'max_hr_used': 190,
      };

  @override
  Future<Map<String, dynamic>> getDayWear(String date) async =>
      const {'worn_min': 600, 'coverage_pct': 42};
}

/// The golden PNGs are NOT in the repo. They are machine-specific — two Flutter
/// SDKs disagree on antialiasing — and 27 MB of them was purged from history,
/// so this group can only pass on a machine that has them.
///
/// Skipped with a stated reason rather than filtered out by a CI flag: the run
/// then says out loud that nobody checked the pixels, which is the honest
/// report. Drop the images back into test/goldens/ and it runs again.
final Object _noGoldens = Directory('test/goldens').existsSync()
    ? false
    : 'golden images are not committed — run this suite locally';

void main() {
  // ── the catalogue ────────────────────────────────────────────────────────
  group('catalogue', () {
    test('eight groups, ~70 activities, no duplicate names', () {
      expect(activityLibrary.length, 8);
      expect(allActivities.length, greaterThanOrEqualTo(65));
      final names = allActivities.map((a) => a.name).toSet();
      expect(names.length, allActivities.length,
          reason: 'a duplicate name would collide in activityByName');
      for (final g in activityLibrary) {
        expect(g.items, isNotEmpty, reason: '${g.name} is empty');
      }
    });

    test('every activity carries a physiologically plausible MET, or none',
        () {
      for (final a in allActivities) {
        final met = a.met;
        if (met == null) continue;
        expect(met, greaterThanOrEqualTo(1.0), reason: a.name);
        expect(met, lessThanOrEqualTo(25.0), reason: a.name);
      }
      // A null MET is not a gap to be filled later — it is the catch-all row
      // saying it was told nothing. Exactly one row may say that, or the
      // exception has quietly become a habit.
      final unpriced = allActivities.where((a) => a.met == null).toList();
      expect(unpriced.map((a) => a.name), ['General workout']);
    });

    test('Intimacy is a normal entry with a privacy default', () {
      final it = allActivities.firstWhere((a) => a.name == 'Intimacy');
      expect(it.met, 5.8);
      expect(it.private, isTrue);
      // Not special-cased anywhere: it resolves through the same lookup.
      expect(activityByName('intimacy')?.name, 'Intimacy');
    });

    test('Bowling cites a compendium row, General workout cites none', () {
      // 15092 "bowling, indoor, bowling alley", not 15090's bare 3.0 — and it
      // stays out of `_sports`, so a bowling night reports as a session
      // rather than as a match's worth of effort. `Arch.match` opens a
      // two-sided scorer, and bowling has no opponent to score against.
      final bowling = activityByName('bowling')!;
      expect(bowling.met, 3.8);
      expect(archOf(bowling), Arch.basic);
      // The catch-all names no activity, so no MET can be honest for it, so
      // no calorie estimate is offered up front. 02060 "health club exercise,
      // general" was the near miss and it prices a gym session — which is not
      // what this row means.
      final general = activityByName('general_workout')!;
      expect(general.met, isNull);
      expect(general.kcal(80, 45), isNull,
          reason: 'a weight is not enough to price an unnamed session');
      expect(general.track, Track.duration);
    });

    test('quick start entries all exist in the library', () {
      for (final q in quickStart) {
        expect(activityByName(q.typeKey)?.name, q.name);
      }
    });

    test('activityByName tolerates display names and unknown types', () {
      expect(activityByName('Weight training')?.track, Track.sets);
      expect(activityByName('weight_training')?.track, Track.sets);
      expect(activityByName('underwater basket weaving'), isNull);
      expect(activityByName(null), isNull);
    });

    test('kcal is MET × 3.5 × kg / 200 × min, and null without a weight', () {
      final run = activityByName('running')!;
      // 9.8 × 3.5 × 70 / 200 × 30 = 360.15
      expect(run.kcal(70, 30), 360);
      expect(run.kcal(null, 30), isNull);
      expect(run.kcal(0, 30), isNull,
          reason: 'a zero weight is a missing weight, not a weightless user');
    });
  });

  // ── archetypes ───────────────────────────────────────────────────────────
  group('archetypes', () {
    test('every activity maps to an archetype', () {
      for (final a in allActivities) {
        expect(Arch.values, contains(archOf(a)), reason: a.name);
      }
    });

    test('all nine archetypes are reachable from the catalogue', () {
      final seen = allActivities.map(archOf).toSet();
      expect(seen, hasLength(Arch.values.length),
          reason: 'unreachable: '
              '${Arch.values.where((x) => !seen.contains(x)).toList()}');
    });

    test('named exceptions beat the tracking mode', () {
      // Hiking is tracked by distance but is about the climb.
      expect(archOf(activityByName('hiking')!), Arch.journey);
      // Swimming is tracked by distance but is about the lap.
      expect(archOf(activityByName('swimming')!), Arch.laps);
      expect(archOf(activityByName('tennis')!), Arch.match);
      expect(archOf(activityByName('running')!), Arch.route);
      expect(archOf(activityByName('yoga')!), Arch.flow);
      expect(archOf(activityByName('hiit')!), Arch.interval);
      expect(archOf(activityByName('weight_training')!), Arch.strength);
      expect(archOf(activityByName('golf')!), Arch.basic);
    });

    test('every archetype has a live screen', () {
      for (final arch in Arch.values) {
        expect(liveFor(_first(arch)), isA<Widget>());
      }
    });

    test('there is no power archetype, and the machines that claimed it are '
        'heart-rate sessions', () {
      expect([for (final a in Arch.values) a.name], isNot(contains('power')));
      for (final key in const [
        'indoor_bike',
        'treadmill',
        'elliptical',
        'stair_climber',
      ]) {
        expect(archOf(activityByName(key)!), Arch.basic,
            reason: '$key has no power meter and no indoor distance');
      }
    });

    test('hard minutes are Z4 + Z5, and absent without a zone split', () {
      final r = _result(Arch.match);
      expect(r.hardMinutes, closeTo(15, .001)); // 11 + 4
      expect(
          ActivityResult(_first(Arch.match),
                  start: _start, duration: const Duration(minutes: 20))
              .hardMinutes,
          isNull,
          reason: 'nobody counted is not zero hard minutes');
    });
  });

  // ── strength maths ───────────────────────────────────────────────────────
  group('strength', () {
    test('volume excludes unloaded sets and says so', () {
      const log = StrengthLog([]);
      expect(log.volumeKg, isNull);

      final full = StrengthLog(_sets);
      // 80×8 + 82.5×7 + 30×12 = 640 + 577.5 + 360 = 1577.5; the pull-up is out.
      expect(full.volumeKg, closeTo(1577.5, .001));
      expect(full.hasUnloadedSets, isTrue);
      expect(full.setCount, 4);
      expect(full.repCount, 36);
      expect(full.exercises,
          ['bench_press', 'triceps_pushdown', 'pull_up']);
    });

    test('a bodyweight-only session has no volume, not zero volume', () {
      final log = StrengthLog([
        LoggedSet('pull_up', 8, at: _start),
        LoggedSet('plank', 1, at: _start),
      ]);
      expect(log.volumeKg, isNull,
          reason: 'zero would claim a real session did no work');
      expect(log.setCount, 2);
    });

    test('top set is the heaviest, ties broken by reps', () {
      expect(StrengthLog(_sets).topSet?.loadKg, 82.5);
      final tie = StrengthLog([
        LoggedSet('bench_press', 5, loadKg: 100, at: _start),
        LoggedSet('bench_press', 6, loadKg: 100, at: _start),
      ]);
      expect(tie.topSet?.reps, 6);
    });

    test('Epley 1RM, and null without a load', () {
      final s = LoggedSet('bench_press', 6, loadKg: 100, at: _start);
      expect(oneRepMax(s), closeTo(120, .001)); // 100 × (1 + 6/30)
      expect(oneRepMax(LoggedSet('pull_up', 6, at: _start)), isNull);
      expect(oneRepMax(null), isNull);
    });

  });

  // ── the live feed ────────────────────────────────────────────────────────
  group('live feed', () {
    test('the session average comes from the curve, not the last sample', () {
      // The bug this replaces: `avgHr: feed.hr` — whatever the strap happened
      // to be reading when the user pressed stop, labelled "Avg HR".
      const f = LiveFeed(hr: 190, hrCurve: [120, 130, 140]);
      expect(f.avgHr, 130);
      expect(const LiveFeed(hr: 190).avgHr, isNull,
          reason: 'no curve means no average — not the instant');
    });

    test('lap speeds are derived from lap seconds, so they cannot disagree',
        () {
      final r = ActivityResult(_first(Arch.laps),
          start: _start,
          duration: const Duration(minutes: 10),
          lapSecs: const [40, 80]);
      expect(r.lapCount, 2);
      expect(r.lapSpeeds, [1.0, .5]);
    });

    test('an unfinished session survives being killed', () async {
      SharedPreferences.setMockInitialValues(const {});
      await Prefs.ensureLoaded();
      addTearDown(LiveDraft.clear);

      final d = LiveDraft.begin(activityByName('swimming')!, weightKg: 72.4);
      d.put('lap_at', const [30, 65]);
      d.setPaused(true);

      // The process dies. Everything in memory goes with it.
      LiveDraft.debugForget();

      final back = LiveDraft.current;
      expect(back, isNotNull, reason: 'the workout is still running');
      expect(back!.activityKey, 'swimming');
      expect(back.weightKg, 72.4);
      expect(back.data['lap_at'], const [30, 65]);
      expect(back.pausedAt, isNotNull, reason: 'it was paused, and still is');

      LiveDraft.clear();
      LiveDraft.debugForget();
      expect(LiveDraft.current, isNull);
    });
  });

  // ── the supporting stats ─────────────────────────────────────────────────
  group('sessionStats prints what the hero does not', () {
    List<String> namesOf(ActivityResult r) =>
        [for (final s in sessionStats(r, null)) s.$1];

    test('the hero\'s own number is not printed again underneath it', () {
      // A yoga/HIIT/indoor session's hero IS the clock, at 48 pt, and the
      // first ringed row under it read 'TIME 45:12'. The poster already
      // subtracts its hero from its grid; the screen it is generated from did
      // not.
      expect(namesOf(_result(Arch.basic)), isNot(contains('Time')));
      expect(namesOf(_result(Arch.flow)), isNot(contains('Time')));
      // A run's hero is its distance, so the clock is the run's alone.
      expect(namesOf(_result(Arch.route)), contains('Time'));
      // …and a run with no distance falls back to the clock, which then goes.
      final noGps = ActivityResult(_first(Arch.route),
          start: _start, duration: const Duration(minutes: 30), avgHr: 130);
      expect(namesOf(noGps), isNot(contains('Time')));
    });

    test('an empty lift prints no sets and no reps', () {
      final empty = ActivityResult(_first(Arch.strength),
          start: _start, duration: const Duration(minutes: 20), avgHr: 96);
      // 'SETS 0' and 'REPS 0' used to sit directly under 'No sets logged',
      // while the share card for the same session printed neither.
      expect(namesOf(empty), isNot(contains('Sets')));
      expect(namesOf(empty), isNot(contains('Reps')));
      expect(namesOf(_result(Arch.strength)), contains('Reps'));
    });

    test('the measured peak is on the screen, not only on the history row',
        () {
      expect(namesOf(_result(Arch.basic)), contains('Max HR'));
      final noPeak = ActivityResult(_first(Arch.basic),
          start: _start, duration: const Duration(minutes: 20));
      expect(namesOf(noPeak), isNot(contains('Max HR')),
          reason: 'absent is dropped, never dashed');
    });

    // TS-09 — the rating is a SELF-REPORT and has to read as one.
    test('a rating is shown as the user\'s own, and never invented', () {
      final rated = ActivityResult(_first(Arch.strength),
          start: _start,
          duration: const Duration(minutes: 40),
          sessionId: 's1',
          rpe: 8,
          strength: StrengthLog(_sets));
      expect(namesOf(rated), contains('Your rating'),
          reason: 'named for who said it, not for the instrument');
      expect(namesOf(rated), isNot(contains('RPE')));
      expect(
          [for (final s in sessionStats(rated, null)) s.$2], contains('8 of 10'));

      // Unrated is DROPPED, not zeroed and not defaulted to the set picker's 7.
      final unrated = rated.copyWith();
      expect(unrated.rpe, 8, reason: 'copyWith must not lose it');
      final never = ActivityResult(_first(Arch.strength),
          start: _start,
          duration: const Duration(minutes: 40),
          sessionId: 's1',
          strength: StrengthLog(_sets));
      expect(namesOf(never), isNot(contains('Your rating')));

      // And a feeling is not one of the things the session MEASURED, so it is
      // not offered to the share card.
      expect([for (final s in shareStats(rated)) s.$1],
          isNot(contains('Your rating')));
    });
  });

  // ── steps ────────────────────────────────────────────────────────────────
  // The strap's 100 Hz pedometer over-counts arm work by up to +199.5%
  // (OXWALK_VALIDATION), so `kGaitStepTypeKeys` stops it counting anything but
  // locomotion on foot. `Activity.gait` is that same law in the catalogue —
  // pinned to the set by gait_step_types_test — and it gates the screens too,
  // so a count banked under one type cannot follow a corrected session onto a
  // rowing machine.
  group('steps are shown only where the strap was allowed to count', () {
    ActivityResult session(String name, {int? steps}) => ActivityResult(
          activityByName(name)!,
          start: _start,
          duration: const Duration(minutes: 52),
          avgHr: 131,
          steps: steps,
        );

    List<String> screenNames(ActivityResult r) =>
        [for (final s in sessionStats(r, null)) s.$1];
    List<String> cardNames(ActivityResult r) =>
        [for (final s in shareStats(r)) s.$1];

    test('a walk that counted them prints them, on the screen and the card',
        () {
      final walk = session('Walking', steps: 8412);
      expect(screenNames(walk), contains('Steps'));
      expect(cardNames(walk), contains('Steps'));
      // Grouped, and bare on both: the label already says what they are.
      expect([for (final s in shareStats(walk)) s.$2], contains('8,412'));
      expect(
          [for (final s in sessionStats(walk, null)) s.$2], contains('8,412'));
    });

    test('a walk with nothing measured is dropped, never zeroed', () {
      // Issue #183: the raw stream is routinely absent during a perfectly good
      // walk, and '0 STEPS' beside a real distance is a fabricated measurement.
      final unmeasured = session('Walking');
      expect(screenNames(unmeasured), isNot(contains('Steps')));
      expect(cardNames(unmeasured), isNot(contains('Steps')));
    });

    test('a rowing session never shows a count, even carrying one', () {
      final rowing = session('Rowing', steps: 4000);
      expect(rowing.activity.gait, isFalse,
          reason: 'stale test, not stale code');
      expect(rowing.stepsCounted, isNull);
      expect(screenNames(rowing), isNot(contains('Steps')));
      expect(cardNames(rowing), isNot(contains('Steps')));
    });

    test('enrichment does not lose the count', () {
      // Every stored session reaches the summary through copyWith — the route,
      // the trace and the rating are all folded in that way. A field left off
      // that list goes blank the moment the session is opened from history.
      expect(session('Running', steps: 5120).copyWith().stepsCounted, 5120);
    });
  });

  // ── formatting ───────────────────────────────────────────────────────────
  // ── the daily-load axis ──────────────────────────────────────────────────
  group('daily load is bucketed by date, not by position', () {
    // Noon local on `d`, which is what `getChart` emits.
    Map<String, Object?> pt(DateTime d, double v) => {
          't': DateTime(d.year, d.month, d.day, 12).millisecondsSinceEpoch ~/
              1000,
          'v': v,
        };

    final end = DateTime(2026, 5, 20); // a Wednesday

    test('a day that derived nothing is a hole, not a shift', () {
      // Three days derived: today, two days ago, and six days ago. The old
      // code took the last seven POINTS and labelled them M…S regardless.
      final out = lastSevenDays([
        pt(end.subtract(const Duration(days: 6)), 10),
        pt(end.subtract(const Duration(days: 2)), 40),
        pt(end, 55),
      ], end);
      expect(out, [10, null, null, null, 40, null, 55]);
      expect(out.length, 7, reason: 'seven days, always — labels depend on it');
    });

    test('points outside the window and junk rows are dropped', () {
      final out = lastSevenDays([
        pt(end.subtract(const Duration(days: 7)), 99),
        pt(end.add(const Duration(days: 1)), 99),
        {'t': 'nonsense', 'v': 5},
        'not a row',
        pt(end, 12),
      ], end);
      expect(out, [null, null, null, null, null, null, 12]);
      expect(lastSevenDays(null, end), List<double?>.filled(7, null));
    });
  });

  // TS-11 / TS-12 — the two crossday reads the Workout screen renders. Both
  // are gates before they are cards: the conjunction is the analytics' verdict
  // and never re-derived here, and a per-type row without its sample size is
  // dropped rather than printed.
  group('the crossday reads the workout screen renders', () {
    Map<String, dynamic> withOverreach({
      required bool both,
      double ratio = 1.6,
    }) =>
        {
          'overreaching': {
            'value': {
              'load_ratio': ratio,
              'nights_elevated': 4,
              'nights_considered': 5,
              'both_point_same_way': both,
            },
          },
        };

    test('TS-12 renders only on the conjunction the analytics decided', () {
      final on = overreachFrom(withOverreach(both: true));
      expect(on, isNotNull);
      expect(on!.ratio, 1.6);
      expect(on.nightsElevated, 4);
      expect(on.nightsConsidered, 5);

      // A high ratio with `both_point_same_way: false` is the case that must
      // stay silent — the screen may not re-derive the verdict from the ratio.
      expect(overreachFrom(withOverreach(both: false, ratio: 2.4)), isNull);
      // Absent metric (no load history), and a stale artifact.
      expect(overreachFrom({'overreaching': {'note': 'need_baseline:'}}), isNull);
      expect(overreachFrom({'stale': 'algo_version'}), isNull);
      expect(overreachFrom(const {}), isNull);
    });

    test('TS-11 keeps n on every row and drops the ones without it', () {
      final rows = morningEffectsFrom({
        'session_cost': {
          'rhr': {
            'value': [
              {
                'session_type': 'Football',
                'n': 14,
                'median_delta': 5.2,
                'exceeds_mdc': true,
              },
              // No n — a median without its sample size is the one shape this
              // item exists to prevent.
              {'session_type': 'Yoga', 'median_delta': 0.4},
            ],
          },
          'rmssd': {
            'value': [
              {
                'session_type': 'Running',
                'n': 22,
                'median_delta': -3.1,
                'exceeds_mdc': false,
              },
            ],
          },
        },
      });
      expect(rows.length, 2);
      // Biggest sample first.
      expect(rows.first.type, 'Running');
      expect(rows.first.metric, 'rmssd');
      expect(rows.first.n, 22);
      expect(rows.first.exceedsMdc, isFalse);
      expect(rows.last.type, 'Football');
      expect(rows.last.n, 14);
      expect(rows.last.exceedsMdc, isTrue);

      expect(morningEffectsFrom(const {}), isEmpty);
      expect(morningEffectsFrom({'session_cost': {'rhr': {'note': 'x'}}}),
          isEmpty);
    });
  });

  group('the day-strain trace is a picture of a day', () {
    final day = DateTime(2026, 5, 20);
    int at(int h, int m) =>
        DateTime(day.year, day.month, day.day, h, m).millisecondsSinceEpoch ~/
            1000;

    test('a gap in wear stays a gap, and the day comes off the curve', () async {
      final d = await DayStrainData.load(_StrainRepo([
        {'t': at(7, 0), 'v': 1.0},
        {'t': at(7, 1), 'v': 1.2},
        // three hours the band recorded nothing at all
        {'t': at(10, 1), 'v': 5.0},
      ]));
      // `getDayStrain` serves the last SETTLED bundle while today is still
      // deriving, so the day is read off the timestamps rather than off the
      // label we asked for — a screen headed "Today" over yesterday's trace is
      // the whole reason for it.
      expect(d.day, day);
      expect(d.curve.length, 1440, reason: 'one slot per minute of that day');
      expect(d.curve[7 * 60], 1.0);
      expect(d.curve[7 * 60 + 1], 1.2);
      expect(d.curve[10 * 60 + 1], 5.0);
      // Dropping the timestamps and keeping the values would close the gap up
      // and draw three hours of climb nobody measured.
      expect(d.curve.sublist(7 * 60 + 2, 10 * 60 + 1).every((v) => v == null),
          isTrue);
      expect(d.wornMin, 600);
      expect(d.coveragePct, 42);
    });

    test('no curve is no day and no chart', () async {
      final d = await DayStrainData.load(_StrainRepo(const []));
      expect(d.day, isNull);
      expect(d.hasCurve, isFalse);
    });
  });

  group('formatting', () {
    test('clock rolls into hours, grouped separates thousands', () {
      expect(clock(59), '00:59');
      expect(clock(605), '10:05');
      expect(clock(3725), '1:02:05');
      expect(grouped(6842), '6,842');
      expect(grouped(999), '999');
      // `pace()` (the metric-only formatter that used to live in summary.dart)
      // is gone — UnitsController.formatPace is the one pace formatter now.
      expect(UnitsController.formatPace(308), '5:08');
    });
  });

  // ── the screens ──────────────────────────────────────────────────────────
  group('screens', () {
    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      await _loadType();
    });

    testWidgets('day strain leads with the curve, and explains an empty day',
        (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 2200 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      final day = DateTime(2026, 5, 20);
      final curve = List<double?>.filled(1440, null);
      for (var m = 7 * 60; m < 19 * 60; m++) {
        curve[m] = (m - 7 * 60) / 60 * 1.4;
      }
      await tester.pumpWidget(_frame(
          DayStrainDetail(
            data: DayStrainData(
              day: day,
              curve: curve,
              strain: 16.8,
              zoneMin: const [212, 96, 41, 18, 4],
              maxHrUsed: 190,
              peakHr: 171,
              wornMin: 743,
              // Under the floor, so the "not comparable to a full day" card is
              // the one being exercised here.
              coveragePct: 51,
            ),
          ),
          Brightness.light,
          1.0));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('—'), findsNothing);
      // The assumed ceiling is PRINTED, not laundered into the score.
      expect(find.textContaining('190 bpm'), findsOneWidget);
      expect(find.textContaining('51%'), findsOneWidget);

      // iOS reaches 3.1x. The inline metrics row and the five-swatch zone key
      // are the two things on this screen that can overflow there.
      await tester.pumpWidget(_frame(
          DayStrainDetail(
            data: DayStrainData(
              day: day,
              curve: curve,
              strain: 16.8,
              zoneMin: const [212, 96, 41, 18, 4],
              maxHrUsed: 190,
              peakHr: 171,
              wornMin: 743,
              coveragePct: 51,
            ),
          ),
          Brightness.dark,
          3.1));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(_frame(
          const DayStrainDetail(data: DayStrainData()),
          Brightness.dark,
          1.0));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('—'), findsNothing);
      expect(find.byType(StatusCard), findsWidgets,
          reason: 'a day with no trace has to say why, not draw a flat line');
    });

    // THE MEASURED whoop-4 CASE: a day derived at v70 with 89 % wear and a
    // scored night (RHR 56.8) and no strain at all. The screen printed "it
    // needs a resting heart rate from a scored night and a day the band was on
    // your wrist" — both of which it had — and offered "Wear the band through
    // the day", which the user had already done.
    testWidgets('day strain states only a cause it was handed', (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 1400 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      var n = 0;
      Future<void> show(DayStrainData d) async {
        // A fresh key each time — the state reads `widget.data` in initState
        // only, so re-pumping into the same slot would show the previous case.
        await tester.pumpWidget(_frame(
            DayStrainDetail(key: ValueKey(n++), data: d),
            Brightness.light,
            1.0));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('—'), findsNothing);
      }

      await show(const DayStrainData(wornMin: 1274, coveragePct: 89));
      expect(find.textContaining('scored night'), findsNothing,
          reason: 'the night WAS scored — a cause nobody gave this screen');
      expect(find.textContaining('Wear the band through the day'), findsNothing,
          reason: 'an action that cannot change the outcome is worse than none');
      expect(find.textContaining('Nothing recorded says why'), findsOneWidget);

      // The same absence WITH the pipeline's reason attached renders that
      // reason, and still offers nothing to tap — no button can fix it.
      await show(const DayStrainData(
          wornMin: 1274,
          coveragePct: 89,
          note: 'unknown_device_family:id=none'));
      expect(find.textContaining('which strap'), findsOneWidget);
      expect(find.textContaining('Nothing recorded says why'), findsNothing);

      // A day the band genuinely never saw is the ONE state where "wear the
      // band" is an instruction rather than an insult, so it survives there.
      await show(const DayStrainData());
      expect(find.textContaining('Wear the band through the day'),
          findsOneWidget);

      // MEASURED on whoop-4, 6 of 17 days: `backfillStrainScale` rescales the
      // headline and drops the curve it cannot rescale, so the day has a strain
      // and no trace. The card claimed "this day produced no strain" over a
      // stored 10.8.
      await show(const DayStrainData(strain: 10.8, wornMin: 1274));
      expect(find.textContaining('produced no strain'), findsNothing);
      expect(find.textContaining('10.8'), findsOneWidget);
    });

    // The Zones screen offered "Add your age in Profile" on all three real
    // databases. The age was set on all three, so following it did nothing.
    testWidgets('zones never sends you after data it already has',
        (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 1600 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      var n = 0;
      Future<void> show(ZonesData d) async {
        await tester.pumpWidget(_frame(
            ZonesDetail(key: ValueKey(n++), data: d), Brightness.light, 1.0));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('—'), findsNothing);
      }

      await show(const ZonesData(age: 30));
      expect(find.textContaining('Add your age'), findsNothing);
      expect(find.textContaining('Without your age'), findsNothing);
      // Nor the claim that the (absent) zones below came off the age.
      expect(find.textContaining('zones below come off your age'), findsNothing);

      await show(const ZonesData(age: 30, note: 'need_input:name=wake_hr'));
      expect(find.textContaining('No waking heart rate'), findsOneWidget);

      // Age genuinely missing — now the button is a real promise.
      await show(const ZonesData());
      expect(find.textContaining('Add your age in Profile'), findsOneWidget);

      // The ceiling card had the same defect: it blamed a missing hard session
      // on all three real databases, where the ceiling had actually refused for
      // an unstamped strap. No hard session fixes that, so no button either.
      await show(const ZonesData(
          age: 30,
          source: 'tanaka',
          ceilingNote: 'unknown_device_family:id=none'));
      expect(find.textContaining('HELD'), findsNothing);
      expect(find.textContaining('Wear the band for your normal hard sessions'),
          findsNothing);
      expect(find.textContaining('which strap'), findsWidgets);
    });

    for (final arch in Arch.values) {
      testWidgets('${arch.name} summary renders and never shows a bare dash',
          (tester) async {
        tester.view.physicalSize = const Size(390 * 3, 2200 * 3);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(_frame(
            ActivitySummary(_result(arch), weightKg: 72.4),
            Brightness.light,
            1.0));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('—'), findsNothing);
      });

      testWidgets('${arch.name} summary survives a session that measured '
          'nothing', (tester) async {
        tester.view.physicalSize = const Size(390 * 3, 2200 * 3);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);

        // No heart rate, no distance, no sets — the absent case, which is what
        // a strap-less first session actually looks like.
        await tester.pumpWidget(_frame(
            ActivitySummary(ActivityResult(_first(arch),
                start: _start, duration: const Duration(minutes: 20))),
            Brightness.dark,
            1.0));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('—'), findsNothing);
        // Flow is the one archetype whose defining object is not a
        // measurement — the breath ring is a pacer and the elapsed time is
        // real — so it has nothing to apologise for. Every other archetype
        // must explain what is missing.
        if (arch != Arch.flow) {
          expect(find.byType(StatusCard), findsWidgets,
              reason: 'absence must be explained, not blank');
        }
      });
    }

    // ── MT-08 · heat and cold ────────────────────────────────────────────
    //
    // The card is built AROUND its no-signal state. Cold water closes the
    // wrist's vessels, which is exactly what the sensor reads through, so "no
    // pulse" is the expected content of a plunge and not a fault to offer a
    // Check-band button for.
    testWidgets('a cold plunge with no pulse says why, and offers no fix',
        (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 2200 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      final plunge = activityByName('Cold plunge')!;
      await tester.pumpWidget(_frame(
          ActivitySummary(ActivityResult(plunge,
              start: _start, duration: const Duration(minutes: 3))),
          Brightness.light,
          1.0));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('—'), findsNothing);
      expect(find.textContaining('vessels the sensor reads through'),
          findsOneWidget);
      expect(find.text('Check band connection'), findsNothing,
          reason: 'there is no connection to check — the blood moved');
      // Nothing that reads as a target, a dose or a score.
      for (final banned in const [
        'thermal load',
        'adaptation',
        'next time',
        'longer'
      ]) {
        expect(find.textContaining(banned), findsNothing, reason: banned);
      }
      // And it is not the yoga tile: no poses, no breaths.
      expect(find.textContaining('poses'), findsNothing);
    });

    testWidgets('a sauna that WAS read draws the trace and names the gaps',
        (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 2200 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      // Twelve minutes, four of them lost — the ordinary partial case.
      final hr = <double?>[
        for (var i = 0; i < 12; i++) i >= 4 && i < 8 ? null : 95.0 + i,
      ];
      await tester.pumpWidget(_frame(
          ActivitySummary(ActivityResult(activityByName('Sauna')!,
              start: _start,
              duration: const Duration(minutes: 12),
              avgHr: 99,
              hr: hr)),
          Brightness.dark,
          1.0));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('8 of 12 minutes'), findsOneWidget,
          reason: 'the coverage is stated, not averaged away');
    });

    // ── TS-09 · session RPE ──────────────────────────────────────────────
    testWidgets('the rating is asked once, pre-selects nothing, and retires',
        (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 2200 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues(const {});
      await Prefs.ensureLoaded();

      final saved = _result(Arch.strength).copyWith(sessionId: 'sess-1');

      // Not at finish → never asked. Opening an old session is not the moment.
      await tester.pumpWidget(
          _frame(ActivitySummary(saved, weightKg: 72.4), Brightness.light, 1.0));
      await tester.pumpAndSettle();
      expect(find.text('HOW HARD DID THAT FEEL?'), findsNothing);

      // Written, and just finished → asked.
      await tester.pumpWidget(_frame(
          ActivitySummary(saved, weightKg: 72.4, justFinished: true),
          Brightness.light,
          1.0));
      await tester.pumpAndSettle();
      expect(find.text('HOW HARD DID THAT FEEL?'), findsOneWidget);
      // Ten choices, and NOT ONE of them is lit: the answer is the tap. The
      // set-level picker's default of 7 is the garbage-data mechanism this
      // field exists to avoid.
      for (var v = 1; v <= 10; v++) {
        expect(find.text('$v'), findsWidgets, reason: 'choice $v');
      }

      // Skipping counts, and the count is what retires the prompt.
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(find.text('HOW HARD DID THAT FEEL?'), findsNothing);
      expect(Prefs.getInt('workout.rpe_skips', 0), 1);

      // iOS reaches 3.1x effective. Five choices across a row is the shape on
      // this card that can overflow there, and an overflow fails the build.
      SharedPreferences.setMockInitialValues(const {});
      await Prefs.ensureLoaded();
      await tester.pumpWidget(_frame(
          ActivitySummary(saved, weightKg: 72.4, justFinished: true),
          Brightness.light,
          3.1));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Three passes and it stops asking rather than escalating.
      SharedPreferences.setMockInitialValues(const {'workout.rpe_skips': 3});
      await Prefs.ensureLoaded();
      await tester.pumpWidget(_frame(
          ActivitySummary(saved, weightKg: 72.4, justFinished: true),
          Brightness.dark,
          1.0));
      await tester.pumpAndSettle();
      expect(find.text('HOW HARD DID THAT FEEL?'), findsNothing);
    });

    testWidgets('a session that never reached the database is not asked',
        (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 2200 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues(const {});
      await Prefs.ensureLoaded();

      // No `sessionId` — the write threw, so there is nowhere to put a rating.
      await tester.pumpWidget(_frame(
          ActivitySummary(_result(Arch.strength),
              weightKg: 72.4, justFinished: true),
          Brightness.light,
          1.0));
      await tester.pumpAndSettle();
      expect(find.text('HOW HARD DID THAT FEEL?'), findsNothing);
    });

    testWidgets('a match shows heart rate, not a court map', (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 2200 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_frame(
          ActivitySummary(_result(Arch.match), weightKg: 72.4),
          Brightness.light,
          1.0));
      await tester.pumpAndSettle();

      expect(find.text('HEART RATE'), findsOneWidget);
      expect(find.text('bpm'), findsWidgets);
      expect(find.textContaining('above 80%'), findsOneWidget);
      expect(find.textContaining('COURT'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('every chart in a summary states its unit', (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 2600 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      for (final (arch, unit) in const [
        (Arch.route, 'km'),
        (Arch.journey, 'm'),
        (Arch.laps, 'seconds per lap'),
        (Arch.interval, 'seconds'),
        // No `strength` row. A lift has no chart in its overview: the muscle
        // map that used to be there was a lookup table painted on a body, not
        // a measurement, and it is the one archetype whose defining object is
        // the log itself.
        (Arch.basic, 'bpm'),
      ]) {
        await tester.pumpWidget(_frame(
            ActivitySummary(_result(arch), weightKg: 72.4),
            Brightness.light,
            1.0));
        await tester.pumpAndSettle();
        expect(find.text(unit), findsWidgets, reason: '${arch.name} chart');
        // Five bands of colour with the minutes in the key.
        expect(find.text('minutes'), findsWidgets, reason: '${arch.name} zones');
        expect(find.textContaining('Z1 · '), findsWidgets);
        // The edges are drawn off a GUESSED ceiling, so the card that draws
        // them says so in words. This was only ever pinned by the goldens,
        // which is why it went four sweeps without anyone being able to say
        // what the 20 red PNGs were red about.
        expect(find.text(zonesWhyFootnote()), findsOneWidget,
            reason: '${arch.name} zones must admit the ceiling is estimated');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('MET calories always carry estimated confidence and the band',
        (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 2200 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      for (final w in const [null, 72.4]) {
        await tester.pumpWidget(_frame(
            ActivitySummary(_result(Arch.basic), weightKg: w),
            Brightness.light,
            1.0));
        await tester.pumpAndSettle();
        // No error bar is quoted, because nothing computes one. The "±15%"
        // this screen used to print had no estimator behind it, and the
        // Workout tab says so in as many words two taps away.
        expect(find.textContaining('±'), findsNothing);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('finishing hands the session to the app, with its sets',
        (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 2400 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      ActivityResult? handed;
      await tester.pumpWidget(_frame(
          liveFor(activityByName('weight_training')!,
              weightKg: 72.4,
              host: ActivityHost(onFinish: (draft) async {
                handed = draft;
                return draft;
              })),
          Brightness.light,
          1.0));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Log set'));
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('Finish session'));
      await tester.pumpAndSettle();

      expect(handed, isNotNull, reason: 'the app has to be told, or the '
          'session exists only on this screen');
      expect(handed!.strength.setCount, 1);
      expect(handed!.strength.sets.first.loadKg, 40);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a swim counts the same laps live and on the summary',
        (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 2400 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      ActivityResult? handed;
      await tester.pumpWidget(_frame(
          liveFor(activityByName('swimming')!,
              weightKg: 72.4,
              host: ActivityHost(onFinish: (draft) async {
                handed = draft;
                return draft;
              })),
          Brightness.light,
          1.0));
      await tester.pumpAndSettle();

      await tester.tap(find.text('LAP'));
      await tester.pump();
      await tester.tap(find.text('LAP'));
      await tester.pump();

      // Live: two taps, two laps, two pool lengths.
      expect(find.text('2 laps · Free'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Finish session'));
      await tester.pumpAndSettle();

      // And the summary agrees. `lapSecs` used to hold the GAPS between taps,
      // so it was one shorter than the swim: 50 m live, 25 m on the summary.
      expect(handed!.lapCount, 2);
      expect(handed!.swimMetres, 50);
      expect(handed!.lapSecs.length, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('stepping back in a flow does not delete the poses already '
        'done', (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 2400 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      ActivityResult? handed;
      await tester.pumpWidget(_frame(
          liveFor(activityByName('yoga')!,
              weightKg: 72.4,
              host: ActivityHost(onFinish: (draft) async {
                handed = draft;
                return draft;
              })),
          Brightness.light,
          1.0));
      // pump, not pumpAndSettle: the breath ring is a pacer and never stops.
      await tester.pump();

      // Four poses in, then back two to hold one again. The record used to be
      // `sublist(0, pose + 1)` off the LIVE index, so this reported two.
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('Next pose'));
        await tester.pump();
      }
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.text('Previous'));
        await tester.pump();
      }
      await tester.tap(find.bySemanticsLabel('Finish session'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(handed!.poses.length, 4,
          reason: 'four poses were done, whatever the pointer sits on');
      expect(tester.takeException(), isNull);
    });

    testWidgets('the share card keeps its ratio on a narrow screen',
        (tester) async {
      // A 320 pt viewport (SE, an iPad Slide Over pane, a split-screen pane)
      // left 288 pt inside the sheet's padding, which squeezed the card's
      // WIDTH while its height stayed fixed — so 'Post' exported 864×900, the
      // 0.96:1 near-square Instagram crops. `toImage` reads the boundary, so
      // the boundary is what has to keep the authored size.
      tester.view.physicalSize = const Size(320 * 3, 900 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_frame(
          ShareSheet(_result(Arch.route)), Brightness.dark, 1.0));
      await tester.pumpAndSettle();

      final card = tester.renderObject<RenderBox>(find.byType(PosterCard));
      expect(card.size.width, kPosterW);
      expect(card.size.height, kPosterW, reason: 'Post is 1:1');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a trailing partial split is not priced as a whole kilometre',
        (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 2200 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      // 5.4 km at a steady 6:00/km. `route_math` emits the last 0.4 km as its
      // own split, 144 s long — which this table printed as a 2:24 pace and
      // then used as the reference every real kilometre was drawn against.
      final r = ActivityResult(_first(Arch.route),
          start: _start,
          duration: const Duration(minutes: 32, seconds: 24),
          distanceKm: 5.4,
          splits: const [
            KmSplit(1, 360),
            KmSplit(1, 360),
            KmSplit(1, 360),
            KmSplit(1, 360),
            KmSplit(1, 360),
            KmSplit(.4, 144),
          ]);
      await tester.pumpWidget(
          _frame(ActivitySummary(r, weightKg: 72.4), Brightness.light, 1.0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Splits'));
      await tester.pumpAndSettle();

      expect(find.text('2:24'), findsNothing,
          reason: '144 s over 0.4 km is 6:00/km, not 2:24');
      expect(find.text('6:00'), findsNWidgets(6));
      // …and the row says what it actually is rather than calling itself km 6.
      expect(find.text('0.4'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a minimised session keeps the sets that were typed into it',
        (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 2400 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      addTearDown(LiveDraft.clear);

      final a = activityByName('weight_training')!;
      // What the setup screen does once the app accepts the session.
      LiveDraft.begin(a, weightKg: 72.4);

      await tester.pumpWidget(
          _frame(liveFor(a, weightKg: 72.4), Brightness.light, 1.0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Log set'));
      await tester.pump();
      expect(find.text('40 kg × 8'), findsWidgets);

      // Minimise: the route is gone and every widget with it. The set was
      // held in `_LiveStrengthState` and died here — silently, while
      // `activeWorkout` stayed open and refused every later workout.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      await tester.pumpWidget(
          _frame(liveFor(a, weightKg: 72.4), Brightness.light, 1.0));
      await tester.pumpAndSettle();
      expect(find.text('40 kg × 8'), findsWidgets,
          reason: 'a typed set is the one thing nothing can recompute');
      expect(find.text('320'), findsOneWidget, reason: 'volume, restored');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a restored push-up draft keeps bodyweight mode',
        (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 2400 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      addTearDown(LiveDraft.clear);

      final a = activityByName('weight_training')!;
      LiveDraft.begin(a, weightKg: 72.4);
      LiveDraft.current!.put('sets', [
        {
          'k': 'push_up',
          'reps': 12,
          'kg': null,
          'rpe': 7,
          'rest': null,
          'at': DateTime(2026, 9, 24).millisecondsSinceEpoch,
        },
      ]);

      List<LoggedSet> banked = [];
      await tester.pumpWidget(_frame(
          LiveStrength(a, onSets: (sets) => banked = sets),
          Brightness.light,
          1.0));
      await tester.pumpAndSettle();

      expect(find.text('Bodyweight — left out of volume'), findsOneWidget,
          reason: 'a restored zero-load set must keep bodyweight mode');
      await tester.tap(find.text('Log set'));
      await tester.pump();
      expect(banked.last.exerciseKey, 'push_up');
      expect(banked.last.loadKg, isNull,
          reason: 'the next set must not inherit the 40 kg default');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a collapsed group builds none of its rows', (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 1400 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
          _frame(const ActivityPicker(weightKg: 72.4), Brightness.light, 1.0));
      await tester.pumpAndSettle();

      // AnimatedCrossFade builds both of its children whatever it is showing,
      // so every group's rows used to exist while every group was shut.
      expect(find.byType(ActivityRow), findsNothing);

      await tester.tap(find.text(activityLibrary.first.name));
      await tester.pumpAndSettle();
      expect(find.byType(ActivityRow).evaluate().length,
          activityLibrary.first.items.length,
          reason: 'the open group, and only the open group');
    });

    testWidgets('a location denial is named on the live screen',
        (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 2200 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      var fixed = 0;
      await tester.pumpWidget(_frame(
          LiveMeasured(activityByName('running')!,
              feed: () => LiveFeed(
                    hr: 132,
                    bandConnected: true,
                    routeIssue: GpsPermissionStatus.deniedForever,
                    onFixRoute: () => fixed++,
                  )),
          Brightness.light,
          1.0));
      await tester.pumpAndSettle();

      // The old screen drew no pill, no map and no sentence.
      expect(find.text('No route: location not allowed'), findsOneWidget);
      await tester.tap(find.text('Open Settings'));
      await tester.pump();
      expect(fixed, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an absent heart rate says which absence it is',
        (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 2200 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      Future<void> pumpWith(bool connected) async {
        await tester.pumpWidget(_frame(
            LiveMeasured(activityByName('running')!,
                feed: () => LiveFeed(bandConnected: connected)),
            Brightness.light,
            1.0));
        await tester.pumpAndSettle();
      }

      await pumpWith(false);
      expect(find.textContaining('not connected'), findsOneWidget);
      await pumpWith(true);
      expect(find.textContaining('finger-width'), findsOneWidget,
          reason: 'a fit instruction only makes sense for a band that is there');
    });

    testWidgets('the strength screen still follows the band it does not tick '
        'for', (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 2400 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      addTearDown(LiveDraft.clear);

      var hr = 96;
      await tester.pumpWidget(_frame(
          LiveStrength(activityByName('weight_training')!,
              feed: () => LiveFeed(hr: hr, bandConnected: true)),
          Brightness.light,
          1.0));
      await tester.pumpAndSettle();
      expect(find.text('96'), findsOneWidget);

      // The body is built once and left alone by the 1 Hz tick — but the heart
      // rate on it is measured, so it must not freeze with the rest.
      hr = 141;
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('141'), findsOneWidget);
    });

    testWidgets('the rest countdown ticks without rebuilding the shell',
        (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 2400 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      addTearDown(LiveDraft.clear);

      await tester.pumpWidget(_frame(
          LiveStrength(activityByName('weight_training')!),
          Brightness.light,
          1.0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Log set'));
      await tester.pump();
      expect(find.text('01:30'), findsOneWidget);

      // The countdown used to be a field behind setState, so every one of the
      // ninety ticks rebuilt this state — and with it a whole new LiveShell,
      // header and transport and all. The widget instance is the tell: only
      // _LiveStrengthState.build makes a new one.
      final shell = tester.widget<LiveShell>(find.byType(LiveShell));
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('01:29'), findsOneWidget,
          reason: 'the ring still counts down');
      expect(identical(tester.widget<LiveShell>(find.byType(LiveShell)), shell),
          isTrue,
          reason: 'the shell must not be rebuilt for a number inside the body');
    });

    testWidgets('a session that failed to save says so and can retry',
        (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 2200 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      var attempts = 0;
      final r = _result(Arch.route);
      await tester.pumpWidget(_frame(
          ActivitySummary(r, weightKg: 72.4, onRetrySave: () async {
            attempts++;
            if (attempts == 1) throw StateError('disk');
            return r;
          }),
          Brightness.light,
          1.0));
      await tester.pumpAndSettle();

      // The summary used to be identical to a successful one.
      expect(find.text('This session is not saved yet'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('This session is not saved yet'), findsOneWidget,
          reason: 'a retry that threw has not saved anything either');

      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('This session is not saved yet'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('push-ups start as bodyweight and repeated sets are banked',
        (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 2600 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      addTearDown(LiveDraft.clear);

      List<LoggedSet> banked = const [];
      await tester.pumpWidget(_frame(
          LiveStrength(
            activityByName('weight_training')!,
            onSets: (sets) => banked = List.of(sets),
          ),
          Brightness.light,
          1.0));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Next exercise'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Push-ups'));
      await tester.pumpAndSettle();

      expect(find.text('Push-ups'), findsOneWidget);
      expect(find.text('Bodyweight — left out of volume'), findsOneWidget);
      await tester.tap(find.text('Log set'));
      await tester.pump();
      expect(banked, hasLength(1));
      expect(banked.single.exerciseKey, 'push_up');
      expect(banked.single.reps, 8);
      expect(banked.single.loadKg, isNull);

      await tester.tap(find.text('Skip rest'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Log set'));
      await tester.pump();
      expect(banked, hasLength(2));
      expect(StrengthLog(banked).repCount, 16);
      expect(banked.every((set) => set.exerciseKey == 'push_up'), isTrue);
    });

    testWidgets('the picker lists every activity and searches by name',
        (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 1400 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
          _frame(const ActivityPicker(weightKg: 72.4), Brightness.light, 1.0));
      await tester.pumpAndSettle();

      expect(find.text('Search ${allActivities.length} activities'),
          findsOneWidget);
      await tester.enterText(find.byType(TextField), 'kayak');
      await tester.pumpAndSettle();
      expect(find.text('Kayaking'), findsOneWidget);
      expect(find.text('Running'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('setup offers no goal it cannot honour', (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 1400 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      // The GOAL picker is gone. Nothing carried a goal or a target into the
      // session — no LiveDraft field, no live screen, no alert — so the only
      // thing it did was make the calorie line quote '45 min', a duration the
      // user had not chosen and could not see anywhere else on the screen.
      await tester.pumpWidget(_frame(
          ActivitySetup(activityByName('running')!, weightKg: 72.4),
          Brightness.light,
          1.0));
      await tester.pumpAndSettle();
      expect(find.text('GOAL'), findsNothing);
      expect(find.text('Distance'), findsNothing);
      expect(find.text('Calories'), findsNothing);
      // The estimate is a RATE, on the picker's own thirty-minute basis.
      expect(find.textContaining('per 30 min'), findsOneWidget);
      expect(find.textContaining('for 45 min'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the unpriced activity offers no number it cannot source',
        (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 1400 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      final general = activityByName('general_workout')!;

      // THE PICKER ROW. Every other row ends in "N kcal / 30 min", or in its
      // MET when there is no body weight. This one has neither to end in, and
      // the point is that it ends in nothing rather than in a placeholder.
      await tester.pumpWidget(
          _frame(const ActivityPicker(weightKg: 72.4), Brightness.light, 1.0));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'general');
      await tester.pumpAndSettle();
      expect(find.text(general.name), findsOneWidget);
      expect(find.textContaining('kcal / 30 min'), findsNothing);
      expect(find.textContaining('MET'), findsNothing,
          reason: 'a MET this row does not have must not be printed as one');

      // THE SETUP SCREEN. A weight IS set here, so "Calories need your
      // weight" would be a lie about which input is missing.
      await tester.pumpWidget(
          _frame(ActivitySetup(general, weightKg: 72.4), Brightness.light, 1.0));
      await tester.pumpAndSettle();
      expect(find.textContaining('per 30 min'), findsNothing);
      expect(find.textContaining('Calories need your weight'), findsNothing);
      expect(find.textContaining('No estimate up front'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the unpriced session still explains a measured figure',
        (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 2400 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      final general = activityByName('general_workout')!;
      final base = _result(Arch.basic);

      // WITH calories: the heart-rate estimator ran, so there IS a figure —
      // and the basis line must not attribute any of it to a MET.
      await tester.pumpWidget(_frame(
          ActivitySummary(
              ActivityResult(general,
                  start: base.start,
                  duration: base.duration,
                  avgHr: 131,
                  maxHr: 158,
                  calories: 402,
                  hr: base.hr,
                  zoneMinutes: base.zoneMinutes),
              weightKg: 72.4),
          Brightness.light,
          1.0));
      await tester.pumpAndSettle();
      expect(find.textContaining('MET,'), findsNothing);
      expect(find.textContaining('MET and your weight'), findsNothing);
      expect(find.textContaining('No MET is in this figure'), findsOneWidget);

      // WITHOUT calories: the missing-anchors explanation is the one that
      // applies, and it is about heart rate, not about a MET either.
      await tester.pumpWidget(_frame(
          ActivitySummary(
              ActivityResult(general,
                  start: base.start,
                  duration: base.duration,
                  avgHr: 131,
                  maxHr: 158,
                  hr: base.hr,
                  zoneMinutes: base.zoneMinutes),
              weightKg: 72.4),
          Brightness.light,
          1.0));
      await tester.pumpAndSettle();
      expect(find.textContaining('No calorie figure for this session'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the strength logger accumulates volume, sets and reps',
        (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 2400 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_frame(
          liveFor(activityByName('weight_training')!, weightKg: 72.4),
          Brightness.light,
          1.0));
      await tester.pumpAndSettle();

      // Default entry is 40 kg × 8 = 320 kg of volume for one set.
      await tester.tap(find.text('Log set'));
      await tester.pump();

      expect(find.text('320'), findsOneWidget); // volume
      expect(find.text('40 kg × 8'), findsWidgets);
      expect(find.textContaining('RESTING'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('share asks one question and prints the rest', (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 1600 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
          _frame(ShareSheet(_result(Arch.strength)), Brightness.light, 1.0));
      await tester.pumpAndSettle();
      // One card and one question. The style list and the stat picker are
      // gone: a lift never had a texture to choose, and asking which of your
      // own measurements to leave off a card with room for all of them was
      // the screen asking the user to do its job.
      expect(find.text('CHOOSE A STYLE'), findsNothing);
      expect(find.text('INCLUDE'), findsNothing);
      expect(find.text('Minimal'), findsNothing);
      expect(find.text('Muscle map'), findsNothing);
      expect(find.text('YOUR PHOTO'), findsOneWidget);
      // A lift has no distance, so no card of it can carry one.
      expect(find.text('DISTANCE'), findsNothing);

      await tester.pumpWidget(
          _frame(ShareSheet(_result(Arch.route)), Brightness.light, 1.0));
      await tester.pumpAndSettle();
      // A run's hero IS its distance, so the grid does not repeat it — the
      // pace it also measured is what proves the stats are being printed.
      expect(find.text('PACE'), findsOneWidget);
      expect(find.text('DISTANCE'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  // ── goldens ──────────────────────────────────────────────────────────────
  //
  // Regenerate deliberately:
  //   flutter test --update-goldens test/ui2_activity_test.dart
  //
  // 2026-08-17 — the twenty `summary_*` PNGs were red for four straight
  // sweeps and every verify pass hand-filtered them out, which is exactly
  // where the next real regression would have hidden. Root cause: they were
  // last baked at f7a73e6 and the screen has legitimately grown twice since.
  //
  //   · dc2d4b6 added the MAX HR row — the measured peak was on the history
  //     row and not on the screen it came from.
  //   · edbd76a/3df58da added [kZonesWhy] under the zone bar and widened the
  //     heart-rate chart's range to hold the peak (the `match` y-axis goes
  //     120/150/180 → 120/160/200).
  //
  // Both are content the screens are supposed to carry, so these were STALE
  // goldens, not a layout defect. The "identical ~18% diff regardless of
  // theme" signature that made it look like one is just geometry: an inserted
  // 88 pt row plus a three-line note shift everything below them, and
  // route/laps/journey share a card of the same height so they shift by the
  // same amount and diff by the same count. Rebaked, and the two additions
  // are now pinned in words above (`Max HR`, [kZonesWhy]) so the next drift
  // reads as a failed string match instead of twenty unreadable PNGs.
  group('goldens', () {
    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      await _loadType();
    });

    final cases = <String, Widget>{
      'summary_route': ActivitySummary(_result(Arch.route), weightKg: 72.4),
      'summary_strength':
          ActivitySummary(_result(Arch.strength), weightKg: 72.4),
      'summary_journey': ActivitySummary(_result(Arch.journey), weightKg: 72.4),
      // The two whose defining object changed: a match is now its heart-rate
      // trace (there was a court map), and a swim is now its lap times.
      'summary_match': ActivitySummary(_result(Arch.match), weightKg: 72.4),
      'summary_laps': ActivitySummary(_result(Arch.laps), weightKg: 72.4),
      'share_strength': ShareSheet(_result(Arch.strength)),
      'picker': const ActivityPicker(weightKg: 72.4),
      'setup_run': ActivitySetup(activityByName('running')!, weightKg: 72.4),
    };

    for (final scale in const [1.0, 2.0]) {
      final tag = scale == 1.0 ? '1x' : '2x';
      for (final brightness in Brightness.values) {
        final theme = brightness.name;
        cases.forEach((name, widget) {
          testWidgets('$name · $theme · $tag', (tester) async {
            tester.view.physicalSize = const Size(390 * 3, 1200 * 3);
            tester.view.devicePixelRatio = 3;
            addTearDown(tester.view.reset);

            await tester.pumpWidget(_frame(widget, brightness, scale));
            await tester.pumpAndSettle();

            await expectLater(find.byType(MaterialApp),
                matchesGoldenFile('goldens/activity_${name}_${theme}_$tag.png'));
          });
        });
      }
    }
  }, skip: _noGoldens);
}
