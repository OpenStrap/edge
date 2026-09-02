// R2 wiring regressions — the numbers the screens were reading wrong.
//
// Each group below pins one bug that shipped, so the fix cannot quietly come
// undone:
//
//  · the cross-day rollup was served VERBATIM, with no version and no date, so
//    every readiness driver, the sleep coach and the body clock could be weeks
//    old under an older algorithm with nothing on screen to say so;
//  · chart points lost their timestamps, so "Today" and "N days ago" were
//    counted off the ARRAY INDEX and a sync gap read as continuous;
//  · the sleep trend captioned itself "vs your need" while subtracting the
//    28-day average;
//  · "days with a derived record in the last month" counted every derived day
//    since install, so anyone past their first month read "30 of 30".

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:provider/provider.dart';

/// A [CoachConfig] that just answers the one question Home asks it, without a
/// keychain or a prefs store behind it.
class _Coach extends CoachConfig {
  _Coach(this._on);
  final bool _on;
  @override
  bool get configured => _on;
}

/// Local noon of `today - back`, the stamp `getChart` puts on a stored point.
int _noon(int back) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day - back, 12).millisecondsSinceEpoch ~/
      1000;
}

String _day(int back) {
  final n = DateTime.now();
  return dayLabelOf(DateTime(n.year, n.month, n.day - back));
}

class _FakeRepo extends LocalRepository {
  final Map<String, dynamic> insights;
  final List<String> days;
  final Map<String, dynamic> today;

  /// day id -> the `daytime_hrv` block `getDayHeart` serves for it.
  final Map<String, Map<String, dynamic>> daytimeHrv;

  _FakeRepo(
      {this.insights = const {},
      this.days = const [],
      this.today = const {},
      this.daytimeHrv = const {}});

  @override
  Future<Map<String, dynamic>> getDayHeart(String date) async =>
      {'daytime_hrv': ?daytimeHrv[date]};
  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async => const {};

  @override
  Future<Map<String, dynamic>> getToday() async => today;
  @override
  Future<Map<String, dynamic>> getInsights() async => insights;
  @override
  Future<Map<String, dynamic>> getProfile() async => const {};
  @override
  Future<List<String>> availableDays() async => days;
  @override
  Future<Map<String, dynamic>> getChart(String metric,
          {int? from, int? to, Set<String> signals = const {}}) async =>
      const {'points': []};
  // Health reads the wear block for the night's off-wrist stretches and the
  // day's naps. Absent here on purpose: an empty map is "we never looked",
  // which is what a fake with no fixture is.
  @override
  Future<Map<String, dynamic>> getDayWear(String date) async => const {};
  @override
  Future<Map<String, dynamic>> getDayNaps(String date) async => const {};
}

void main() {
  // ── the artifact behind four screens ──
  group('crossDayStaleReason', () {
    Map<String, dynamic> artifact({int? version, String? builtFor}) => {
          'algo_version': version ?? kAlgoVersion,
          'built_for_day': ?builtFor,
          'readiness_glassbox': const {'drivers': []},
        };

    test('an artifact stamped with today and this algo version is served', () {
      expect(
        LocalRepositoryImpl.crossDayStaleReason(
            artifact(builtFor: _day(0)), _day(0)),
        isNull,
      );
    });

    test('yesterday is still fine — the families are multi-day by design', () {
      expect(
        LocalRepositoryImpl.crossDayStaleReason(
            artifact(builtFor: _day(1)), _day(0)),
        isNull,
      );
    });

    test('past the age ceiling it is withheld, with the day it was built for',
        () {
      final r = LocalRepositoryImpl.crossDayStaleReason(
          artifact(
              builtFor: _day(LocalRepositoryImpl.crossDayMaxAgeDays + 1)),
          _day(0));
      expect(r?['kind'], 'stale');
      expect(r?['built_for_day'],
          _day(LocalRepositoryImpl.crossDayMaxAgeDays + 1));
    });

    test('an OLDER algo version is withheld however fresh the day', () {
      // The sharp case: a bump that changes the bundle SHAPE would otherwise be
      // served from the pre-bump artifact for the rest of the day, and the new
      // family silently sees nothing on the very pass the bump existed for.
      final r = LocalRepositoryImpl.crossDayStaleReason(
          artifact(version: kAlgoVersion - 1, builtFor: _day(0)), _day(0));
      expect(r?['kind'], 'algo_version');
    });

    test('an UNSTAMPED artifact cannot be shown to be fresh, so it is not', () {
      expect(
          LocalRepositoryImpl.crossDayStaleReason(
              artifact(builtFor: null), _day(0))?['kind'],
          'unstamped');
      expect(
          LocalRepositoryImpl.crossDayStaleReason(
              {'readiness_glassbox': const {}}, _day(0))?['kind'],
          'algo_version');
    });

    test('a day in the FUTURE is a clock that moved, not freshness', () {
      final n = DateTime.now();
      final ahead = dayLabelOf(DateTime(n.year, n.month, n.day + 40));
      expect(
          LocalRepositoryImpl.crossDayStaleReason(
              artifact(builtFor: ahead), _day(0))?['kind'],
          'stale');
    });
  });

  // ── the seam that dropped `t` ──
  group('chart points keep their date', () {
    test('pointsOf carries t through; seriesOf is still values-only', () {
      final chart = {
        'points': [
          {'t': _noon(2), 'v': 51},
          {'t': _noon(0), 'v': 54.5},
        ],
      };
      expect(pointsOf(chart).map((e) => e.v).toList(), [51.0, 54.5]);
      expect(pointsOf(chart).last.t, _noon(0));
      expect(seriesOf(chart), [51.0, 54.5]);
    });

    test('a point with no timestamp is not a dated point', () {
      expect(pointsOf({'points': [{'v': 51}]}), isEmpty);
    });

    test('a gap is a HOLE, not a shorter line', () {
      // The bug in one assertion: three stored points spread over seven days
      // used to be drawn as three evenly spaced samples, and the line ran
      // straight through the four missing days as though they were measured.
      final dense = denseDays([
        (t: _noon(6), v: 50.0),
        (t: _noon(2), v: 54.0),
        (t: _noon(0), v: 52.0),
      ], 7);
      expect(dense, [50.0, null, null, null, 54.0, null, 52.0]);
      expect(dense.length, 7);
    });

    test('a point outside the window is dropped, not clamped into it', () {
      expect(denseDays([(t: _noon(40), v: 50.0)], 7), List.filled(7, null));
    });

    test('the label counts REAL days, not array positions', () {
      // Two stored points a fortnight apart. Labelling off the index called the
      // older one "1 day ago" and the newer one "Today" whatever their dates.
      expect(axisDay(_noon(0)), 'Today');
      expect(axisDay(_noon(0), todayWord: 'Last night'), 'Last night');
      expect(axisDay(_noon(14)), '14 days ago');
      expect(axisDay(_noon(14), unitWord: 'nights'), '14 nights ago');
      expect(axisDay(null), '');
      expect(daysBehind(_noon(3)), 3);
    });

    test('a day is a calendar day, DST boundary or not', () {
      // Spring forward, America/New_York: local midnight on the 8th to local
      // midnight on the 10th is 47 hours, and `inDays` truncated that to ONE.
      // `denseDays` then wrote the 8th and the 9th into the same slot and the
      // older of the two vanished.
      //
      // These assertions are exact in every zone; they only had teeth in a
      // DST one, which is where the bug was reproduced.
      expect(
          calendarDaysBetween(
              DateTime(2026, 3, 8, 23, 59), DateTime(2026, 3, 10, 0, 1)),
          2);
      expect(
          calendarDaysBetween(DateTime(2026, 3, 9), DateTime(2026, 3, 10)), 1);
      // Autumn back, the 25-hour day.
      expect(
          calendarDaysBetween(DateTime(2026, 11, 1), DateTime(2026, 11, 2)), 1);
      // Time of day never counts: one minute before midnight and one minute
      // after are a whole day apart, not zero.
      expect(
          calendarDaysBetween(
              DateTime(2026, 6, 1, 23, 59), DateTime(2026, 6, 2, 0, 1)),
          1);
    });
  });

  // ── the last thirty CALENDAR days ──
  group('HealthData.load', () {
    test('consistency counts the last 30 calendar days, not all history', () async {
      final repo = _FakeRepo(
        // 45 derived days, but only 10 of them inside the last month.
        days: [
          for (var i = 0; i < 10; i++) _day(i),
          for (var i = 40; i < 75; i++) _day(i),
        ],
      );
      expect((await HealthData.load(repo)).daysWithData, 10);
    });

    test('a withheld rollup arrives as a reason, not as silence', () async {
      final d = await HealthData.load(_FakeRepo(insights: const {
        'stale': {'kind': 'algo_version'},
      }));
      expect(d.insightsStale?['kind'], 'algo_version');
      expect(d.need.value, isNull);
    });
  });

  // ── the caption and the number have to be the same subtraction ──
  group('Health · Trends', () {
    HealthData sleepFixture({Metric need = Metric.empty}) => HealthData(
          today: const {
            'sleep': {
              'duration_min': {
                'value': 420,
                'confidence': .8,
                'tier': 'ESTIMATE',
              },
            },
          },
          charts: {
            'sleep': [
              for (var i = 29; i >= 1; i--) (t: _noon(i), v: 400.0),
              (t: _noon(0), v: 420.0),
            ],
          },
          need: need,
        );

    Future<void> pump(WidgetTester t, HealthData d) async {
      t.view.physicalSize = const Size(390 * 3, 2400 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        // Trends. Explore was inserted at index 1, so Trends moved to 2.
        home: Scaffold(body: HealthScreen(data: d, tab: 2)),
      ));
      await t.pumpAndSettle();
    }

    testWidgets('with no sleep need, the delta is vs the stored average',
        (t) async {
      await pump(t, sleepFixture());
      expect(find.text('20m'), findsOneWidget); // 420 − 400
      expect(find.text('vs your 28-day average'), findsOneWidget);
    });

    testWidgets('captioned "vs your need", the delta IS vs the need',
        (t) async {
      // The bug: the caption changed and the subtraction did not, so the user
      // read 20m — the distance from their own average — under the words "vs
      // your 7h 42m need". The real shortfall is 42m.
      await pump(
          t,
          sleepFixture(
              need: const Metric(
                  value: 462, unit: 'min', confidence: .7, tier: MetricTier.estimate)));
      expect(find.text('42m'), findsOneWidget);
      expect(find.text('20m'), findsNothing);
      expect(find.text('vs your 7h 42m need'), findsOneWidget);
    });

    testWidgets('the window says how many days it actually holds', (t) async {
      // "vs your 28-day average" printed from the SECOND stored value.
      await pump(
          t,
          HealthData(charts: {
            'sleep': [(t: _noon(1), v: 400.0), (t: _noon(0), v: 420.0)],
          }));
      expect(find.text('vs your 1-day average'), findsOneWidget);
    });
  });

  // ── an older night is not today's number ──
  //
  // This used to say the opposite: getToday holds the last scored night over
  // until today's settles, and Home printed it with one sentence naming the
  // night. On a phone the sentence loses — a figure in the today slot reads as
  // today's, so a morning the strap was never worn showed last week's sleep as
  // this morning's. The numbers stop at the loader now and the reason travels
  // in their place.
  group('held-over overnight', () {
    Map<String, dynamic> bundle(String state, {bool prior = true}) => {
          'status': {
            'today_day': '2026-05-20',
            'overnight_state': state,
            'overnight_day': '2026-05-16',
            'showing_prior_overnight': prior,
          },
          'daily': {
            'readiness': {'value': 82, 'confidence': .8, 'tier': 'HIGH'},
            'resting_hr': {'value': 51, 'confidence': .8, 'tier': 'HIGH'},
          },
          'sleep': {
            'duration_min': {'value': 430, 'confidence': .8, 'tier': 'HIGH'},
          },
        };

    test('the three overnight figures are refused', () async {
      final d = await HomeData.load(_FakeRepo(today: bundle('missing')));
      expect(d.readiness.value, isNull);
      expect(d.sleepMin.value, isNull);
      expect(d.rhr.value, isNull);
      // The night is still resolvable — it is just no longer a reading.
      expect(d.heldOverNight, '2026-05-16');
    });

    // A night still computing and a night that never happened are different
    // absences: one resolves itself, the other wants a sync.
    test('the absence says which of the two it is', () async {
      final building = await HomeData.load(_FakeRepo(today: bundle('building')));
      expect(building.readiness.note, contains('still being worked out'));

      final missing = await HomeData.load(_FakeRepo(today: bundle('missing')));
      expect(missing.readiness.note, contains('reached the app'));
    });

    test("today's own night is served as itself", () async {
      final d = await HomeData.load(
          _FakeRepo(today: bundle('ready', prior: false)));
      expect(d.readiness.value, 82);
      expect(d.rhr.value, 51);
      expect(d.heldOverNight, isNull);
    });

    Widget frame(HomeData d) => MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(body: HomeScreen(data: d, hour: 20)));

    testWidgets('a day with nothing of its own says where the data stops',
        (t) async {
      await t.pumpWidget(frame(
          const HomeData(dayId: '2026-05-20', heldOverNight: '2026-05-16')));
      expect(find.text('Nothing recorded for today'), findsOneWidget);
      expect(find.textContaining('16 May'), findsOneWidget);
    });

    // The same empty screen, on an install that has never scored anything, is
    // a first run and gets the first-run words.
    testWidgets('a genuine first run keeps its own card', (t) async {
      await t.pumpWidget(frame(const HomeData(dayId: '2026-05-20')));
      expect(find.text('Nothing derived yet'), findsOneWidget);
    });

    // A bare day during a live workout is missing COMPUTE, not data: the
    // session holds derivation (DeriveScheduler.setWorkoutActive), so "sync
    // the band" is a false answer — the sync completes and changes nothing.
    // The card must name the workout instead.
    testWidgets('a bare day during a live workout blames the workout, not sync',
        (t) async {
      await t.pumpWidget(MaterialApp(
          theme: buildTheme(Brightness.light),
          home: const Scaffold(
              body: HomeScreen(
                  data: HomeData(
                      dayId: '2026-05-20', heldOverNight: '2026-05-16'),
                  hour: 20,
                  workoutLive: true))));
      expect(find.text('A workout is still running'), findsOneWidget);
      expect(find.text('Nothing recorded for today'), findsNothing);
      expect(find.text('Sync the band'), findsNothing);
    });
  });

  // ── the one observation Home is allowed to make ──
  //
  // The watch earns Home because of WHEN it is useful, not how alarming it is:
  // amber has no notification, so before this the earliest signal the app
  // produces could only be found by opening Health and scrolling to it.
  group('illness watch on Home', () {
    Widget frame(HomeData d) => MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(body: HomeScreen(data: d, hour: 9)));

    const base = HomeData(dayId: '2026-05-20');

    testWidgets('amber shows — this is the whole point of the change',
        (t) async {
      await t.pumpWidget(frame(base.copyOrIllness('amber', '2026-05-20', 2.4)));
      expect(find.textContaining('outside your normal range'), findsOneWidget);
    });

    testWidgets('red shows, and says it is a run rather than one night',
        (t) async {
      await t.pumpWidget(frame(base.copyOrIllness('red', '2026-05-20', 3.1)));
      expect(find.textContaining('Several nights in a row'), findsOneWidget);
    });

    testWidgets('green is SILENT, not a card saying you are fine', (t) async {
      await t.pumpWidget(frame(base.copyOrIllness('green', '2026-05-20', 0.2)));
      expect(find.textContaining('normal range'), findsNothing);
      expect(find.textContaining('Several nights'), findsNothing);
    });

    testWidgets('no state at all is silent too — the CUSUM wants 7 nights',
        (t) async {
      await t.pumpWidget(frame(base));
      expect(find.textContaining('normal range'), findsNothing);
    });

    testWidgets('a negative z says BELOW while the run is still up', (t) async {
      // The stored z is the latest night's own deviation and can be negative
      // while the accumulator is still raised — it only clears after two
      // nights back under. Printing "1.3 deviations" without a direction read
      // as "above your baseline, 1.3 below it".
      await t.pumpWidget(frame(base.copyOrIllness('red', '2026-05-20', -1.3)));
      expect(find.textContaining('1.3 standardised deviations below it'),
          findsOneWidget);
    });

    testWidgets('an older night is named rather than called last night',
        (t) async {
      await t.pumpWidget(frame(base.copyOrIllness('amber', '2026-05-16', 2.2)));
      expect(find.textContaining('16 May'), findsOneWidget);
      expect(find.textContaining('Last night'), findsNothing);
    });
  });

  // ── a rebuild the user never hears about is data quietly vanishing ──
  group('dbRebuiltCard', () {
    test('says nothing when nothing was rebuilt', () {
      expect(dbRebuiltCard(null), isNull);
    });

    test('names the EMPTY tables, not just the recovered count', () {
      final card = dbRebuiltCard((
        cause: 'database disk image is malformed',
        quarantinePath: '/data/openstrap.corrupt.1755300000.db',
        salvaged: const {'day_result': 412, 'food_entry': 0, 'med_dose': 0},
      ))!;
      // The reassuring half.
      expect(card.why, contains('day_result 412'));
      // The half that actually tells someone their food log is gone. A summed
      // "412 rows recovered" would have read as good news.
      expect(card.why, contains('Empty:'));
      expect(card.why, contains('food_entry'));
      expect(card.why, contains('med_dose'));
      // And the original is still on disk — never imply a delete.
      expect(card.why, contains('/data/openstrap.corrupt.1755300000.db'));
      expect(card.why, contains('nothing was '));
    });

    test('does not pretend when nothing came back', () {
      final card = dbRebuiltCard((
        cause: 'file is not a database',
        quarantinePath: '/data/x.db',
        salvaged: const {'day_result': 0},
      ))!;
      expect(card.why, contains('Nothing could be read back'));
    });
  });

  // ── the absence diagnostic reaches the user, not just Firebase ──
  //
  // `readiness_absent_diag` is produced on every day readiness comes back
  // absent — which input was missing, how many of your own nights are behind
  // each — and its only destination was a telemetry breadcrumb.
  group('why is this blank', () {
    Future<void> pump(WidgetTester t, Widget w) async {
      t.view.physicalSize = const Size(390 * 3, 2400 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
          theme: buildTheme(Brightness.light), home: Scaffold(body: w)));
      await t.pumpAndSettle();
    }

    testWidgets('the empty hero on Home is a door, not a dead end', (t) async {
      await pump(
          t,
          HomeScreen(
              hour: 10,
              data: const HomeData(
                  dayId: '2026-05-20',
                  steps: Metric(
                      value: 4200,
                      unit: 'steps',
                      confidence: .9,
                      tier: MetricTier.high))));
      expect(find.text('Readiness is not scored today'), findsOneWidget);
      expect(find.text('See what was missing'), findsOneWidget);
    });

    testWidgets('the detail names each input and QUOTES the pipeline',
        (t) async {
      await pump(
          t,
          const ReadinessDetail(
              data: ReadinessData(absentDiag: {
            'hrv': {'value': true, 'baseline_n': 6, 'baseline_sd': 0.11},
            'rhr': {'value': false, 'baseline_n': 6, 'baseline_sd': 1.2},
            'note': 'need_baseline:have=6,need=14',
          })));
      expect(find.text('What went into it'), findsNothing);
      expect(find.text('What was missing'), findsOneWidget);
      // Presence and history are separate facts, and both are the pipeline's.
      expect(find.textContaining('Measured · 6 nights'), findsOneWidget);
      expect(find.textContaining('Not measured · 6 nights'), findsOneWidget);
      // The note is turned into English by the machinery that already parses
      // it — and never into a date. 14 − 6 = 8.
      expect(find.textContaining('Need 8 more nights'), findsOneWidget);
    });

    testWidgets('a scored day carries no diagnostic at all', (t) async {
      await pump(
          t,
          const ReadinessDetail(
              data: ReadinessData(
                  readiness: Metric(
                      value: 74, confidence: .8, tier: MetricTier.high))));
      expect(find.text('What was missing'), findsNothing);
    });
  });

  // ── L4: the coverage denominator under a long trend ──
  group('wear strip', () {
    Future<void> pump(WidgetTester t, MetricData d) async {
      t.view.physicalSize = const Size(390 * 3, 2400 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(body: MetricDetail('resting_hr', data: d))));
      await t.pumpAndSettle();
    }

    testWidgets('says how much of the window was actually worn', (t) async {
      // Twelve worn days inside a thirty-day window. The line above is drawn
      // from the same twelve and used to be the only thing on the card.
      await pump(
          t,
          MetricData(
            daysAvailable: 40,
            series: [for (var i = 11; i >= 0; i--) (t: _noon(i), v: 54.0)],
            wear: [for (var i = 11; i >= 0; i--) (t: _noon(i), v: 480.0)],
          ));
      // The screen opens on Today; the denominator is a long-range thing.
      await t.tap(find.text('30 days'));
      await t.pumpAndSettle();
      expect(find.text('Worn'), findsOneWidget);
      expect(find.textContaining('12 of these 30 days have a wear record'),
          findsOneWidget);
    });

    testWidgets('a seven-day window does not get one', (t) async {
      // A week you either wore or did not; the denominator changes nothing.
      await pump(
          t,
          MetricData(
            daysAvailable: 40,
            series: [for (var i = 11; i >= 0; i--) (t: _noon(i), v: 54.0)],
            wear: [for (var i = 11; i >= 0; i--) (t: _noon(i), v: 480.0)],
          ));
      await t.tap(find.text('7 days'));
      await t.pumpAndSettle();
      expect(find.text('Worn'), findsNothing);
    });
  });

  // ── a tile opens today, not the widest range the install can fill ──
  group('MetricDetail default range', () {
    Future<void> pump(WidgetTester t, String key, MetricData d) async {
      t.view.physicalSize = const Size(390 * 3, 2400 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(body: MetricDetail(key, data: d))));
      await t.pumpAndSettle();
    }

    // The old default was index 2, clamped to whatever the install could fill
    // — so it landed on 30 days, or on 7 for a young install, and moved as the
    // install aged. It was never today.
    testWidgets('opens on today however much history there is', (t) async {
      await pump(
          t,
          'resting_hr',
          MetricData(
            daysAvailable: 400,
            series: [for (var i = 200; i >= 0; i--) (t: _noon(i), v: 54.0)],
          ));
      expect(find.text('Today'), findsWidgets);
      // Today's headline is today's reading, not a window average.
      expect(find.textContaining('Daily average'), findsNothing);
    });

    testWidgets('the range switcher still goes wide', (t) async {
      await pump(
          t,
          'resting_hr',
          MetricData(
            daysAvailable: 400,
            series: [for (var i = 200; i >= 0; i--) (t: _noon(i), v: 54.0)],
          ));
      await t.tap(find.text('30 days'));
      await t.pumpAndSettle();
      expect(find.textContaining('Daily average'), findsOneWidget);
    });
  });

  // ── the sparkles button is not an advert for a feature you never set up ──
  group('the AI button on Home', () {
    Widget frame(bool configured) => MaterialApp(
        theme: buildTheme(Brightness.light),
        home: ChangeNotifierProvider<CoachConfig>.value(
          value: _Coach(configured),
          child: const Scaffold(
              body: HomeScreen(data: HomeData(dayId: '2026-05-20'), hour: 20)),
        ));

    testWidgets('no model, no button', (t) async {
      await t.pumpWidget(frame(false));
      expect(find.byIcon(LucideIcons.sparkles), findsNothing);
      // The profile/settings button beside it is untouched — this is one
      // button, not the row. (It's a gear, not an avatar — the profile photo
      // was retired from this row; see home_screen's "Profile and settings".)
      expect(find.byIcon(LucideIcons.settings), findsOneWidget);
    });

    testWidgets('a configured coach gets its button', (t) async {
      await t.pumpWidget(frame(true));
      expect(find.byIcon(LucideIcons.sparkles), findsOneWidget);
    });
  });

  // ── the breakdown describes today, so it only shows on today ──
  group('steps breakdown', () {
    Future<void> pump(WidgetTester t) async {
      t.view.physicalSize = const Size(390 * 3, 2400 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(
              body: MetricDetail('steps',
                  data: MetricData(
                    daysAvailable: 400,
                    series: [
                      for (var i = 60; i >= 0; i--) (t: _noon(i), v: 8000.0),
                    ],
                  )))));
      await t.pumpAndSettle();
    }

    testWidgets('it is there on today, and it is called Breakdown', (t) async {
      await pump(t);
      expect(find.text('Breakdown'), findsOneWidget);
      // The old name said "today's" while sitting under a month of days.
      expect(find.textContaining("Where today's came from"), findsNothing);
    });

    testWidgets('it is gone on a wider range', (t) async {
      await pump(t);
      await t.tap(find.text('30 days'));
      await t.pumpAndSettle();
      expect(find.text('Breakdown'), findsNothing);
    });
  });

  // ── the screen is called "Nerd stats" everywhere the user can read it ──
  //
  // The file, the class and the gallery keys still say `investigate`; that is
  // deliberate and invisible. What must never come back is the old word on
  // screen, in either of the two places it appeared: the scaffold's overline
  // and the link row every detail screen ends with.
  group('Nerd stats naming', () {
    testWidgets('the screen and its door both say Nerd stats', (t) async {
      t.view.physicalSize = const Size(390 * 3, 3000 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Investigate('hrv', data: InvestigateData(day: _day(0))),
      ));
      await t.pumpAndSettle();
      expect(find.text('NERD STATS'), findsOneWidget);
      expect(find.textContaining('INVESTIGATE'), findsNothing);

      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: Builder(builder: (c) => investigateRow(c, () {})),
        ),
      ));
      await t.pumpAndSettle();
      expect(find.text('Nerd stats'), findsOneWidget);
      expect(find.text('Investigate'), findsNothing);
    });
  });

  // ── CV-10: three states, and "not screened" is not "clear" ──
  group('irregular-rhythm strip', () {
    testWidgets('counts the days it ran and refuses to reassure', (t) async {
      t.view.physicalSize = const Size(390 * 3, 3000 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Investigate('hrv',
            data: InvestigateData(day: _day(0), rhythmPoints: [
              for (var i = 9; i >= 0; i--) (t: _noon(i), v: i == 3 ? 1.0 : 0.0),
            ])),
      ));
      await t.pumpAndSettle();
      expect(find.text('Irregular-rhythm screen'), findsOneWidget);
      expect(find.textContaining('Ran on 10 days, raised its flag on 1'),
          findsOneWidget);
      // The permanent line. Not a tooltip, and not optional.
      expect(find.textContaining('A clear strip is not a negative result'),
          findsOneWidget);
    });
  });

  // ── CV-09: daytime HRV by hour, weekly median, today excluded ──
  //
  // The gate is the feature (an ungated bin of walking enters as low HRV), so
  // the aggregation on top of it must not undo the honesty: never today alone,
  // never a mean an outlier can drag, and an hour with too few quiet stretches
  // behind it is ABSENT rather than drawn.
  group('daytime HRV by hour', () {
    /// One `daytime_hrv` block: bins at [hour] on the day [back] days ago.
    Map<String, dynamic> block(int back, int hour, List<double> vs) {
      final n = DateTime.now();
      final base = DateTime(n.year, n.month, n.day - back, hour)
              .millisecondsSinceEpoch ~/
          1000;
      return {
        'timeline': [
          for (var i = 0; i < vs.length; i++)
            {'t': base + i * 300, 'rmssd': vs[i], 'n': 9},
        ],
      };
    }

    test('an hour needs three stretches, and takes their middle value',
        () async {
      final d = await CircadianData.load(_FakeRepo(
        days: [for (var i = 1; i <= 3; i++) _day(i)],
        daytimeHrv: {
          // 09:00 gets three bins across three days -> drawn, median 40.
          _day(1): block(1, 9, [10, 40]),
          _day(2): block(2, 9, [90]),
          // 14:00 gets two -> not enough, absent.
          _day(3): block(3, 14, [50, 55]),
        },
      ));
      expect(d.hourly[9], 40, reason: 'the middle of 10, 40, 90 — not the mean');
      expect(d.hourly[14], isNull, reason: 'two stretches is not an hour');
      expect(d.hourlyN[9], 3);
      expect(d.hourlyDays, 3);
    });

    test('today is never in it', () async {
      final d = await CircadianData.load(_FakeRepo(
        days: [_day(0), _day(1)],
        daytimeHrv: {
          _day(0): block(0, 9, [10, 10, 10, 10]),
          _day(1): block(1, 20, [30, 30, 30]),
        },
      ));
      expect(d.hourly[9], isNull,
          reason: "today's own bins are a handful of windows, not a median");
      expect(d.hourly[20], 30);
      expect(d.hourlyDays, 1);
    });

    testWidgets('the card refuses to read as a stress meter', (t) async {
      t.view.physicalSize = const Size(390 * 3, 2600 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: CircadianDetail(
            data: CircadianData(
          hourly: [for (var h = 0; h < 24; h++) h.isEven ? 40.0 + h : null],
          hourlyN: List<int>.filled(24, 5),
          hourlyDays: 7,
          jetlag: const Metric(value: 1.5, confidence: .6, tier: MetricTier.estimate),
          midFreeH: 4.5,
          midWorkH: 3.0,
          nFree: 3,
          nWork: 9,
        )),
      ));
      await t.pumpAndSettle();
      expect(find.textContaining('Not a stress score'), findsOneWidget);
      // How deep each drawn hour is, not just a grand total.
      expect(find.textContaining('middle value of 5–5 five-minute stretches'),
          findsOneWidget);
      expect(find.textContaining('12 of 24 hours'), findsOneWidget);
      // The InsightCard this section was paid for with is gone, and its one
      // extra fact — the DIRECTION, which is the sign of free minus work — is
      // on the row it belongs to.
      expect(find.textContaining('free-day clock runs'), findsNothing);
      expect(find.text('1h 30m later'), findsOneWidget);
      expect(find.text('3 / 9'), findsOneWidget);
    });
  });

  // ── MIND-11: a shape and a window, and an abstention that must stay ────────
  //
  // The item's own note is that the abstention is what gets quietly removed
  // later if it is not pinned first. So it is pinned first.
  group('alertness forecast', () {
    Future<void> pumpC(WidgetTester t, CircadianData d,
        {double scale = 1}) async {
      t.view.physicalSize = Size(390 * 3, 4000 * 3 * scale);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: CircadianDetail(data: d),
        ),
      ));
      await t.pumpAndSettle();
    }

    testWidgets('no judged night, no forecast — and no explanation either',
        (t) async {
      await pumpC(t, const CircadianData());
      // Not an empty card, not a placeholder, not "we need more data". The
      // section is absent, because a model prediction nobody asked for is not
      // owed an apology.
      expect(find.text('Today, predicted'), findsNothing);
      expect(find.textContaining('flattest stretch'), findsNothing);
    });

    testWidgets('a shape, a named window, and the refusal on the card',
        (t) async {
      await pumpC(
        t,
        CircadianData(
          alertness: ana.alertnessForecast(
            wakeLocalHour: 7.0,
            sleepDurationHours: 7.5,
            circadianAcrophaseHours: 16.0,
          ),
        ),
      );
      expect(find.text('Today, predicted'), findsOneWidget);
      expect(find.textContaining('flattest stretch lands in'), findsOneWidget);
      // No score, and the chart says why there is no axis to read one off.
      expect(find.textContaining('No scale — the shape is the whole output'),
          findsOneWidget);
      // The safety refusal is COPY, on the card, in both directions.
      expect(find.textContaining('not a fitness-to-drive check'), findsOneWidget);
      expect(find.textContaining('does not say you are impaired'),
          findsOneWidget);
      expect(find.textContaining('a prediction, not a reading'), findsOneWidget);
    });

    testWidgets('the card survives 3.1x text', (t) async {
      // Any RenderFlex overflow anywhere in the pumped page fails this.
      await pumpC(
        t,
        CircadianData(
          alertness: ana.alertnessForecast(
              wakeLocalHour: 7.0, sleepDurationHours: 7.5),
        ),
        scale: 3.1,
      );
      expect(find.textContaining('flattest stretch lands in'), findsOneWidget);
    });

    testWidgets('the jargon battery is behind a tap, not on the screen',
        (t) async {
      await pumpC(
          t,
          const CircadianData(
              rhythmV: {'IS': .62, 'IV': .81, 'RA': .74},
              cosinorV: {'acrophase_hours': 15.2}));
      expect(find.text('Day-to-day stability'), findsNothing);
      await t.tap(find.text('Show'));
      await t.pumpAndSettle();
      expect(find.text('Day-to-day stability'), findsOneWidget);
    });
  });

  // ── RESP-01: across nights, never on one, and it may not reassure ─────────
  group('the across-nights breathing screen', () {
    /// [n] nights all at [rate], newest first, with the last [recent] raised.
    List<ana.CvhrNight> nights(int n,
        {double rate = 2.0, int recent = 0, double recentRate = 40.0}) => [
          for (var i = 0; i < n; i++)
            ana.CvhrNight(
              dayKey: _day(i),
              cvhrPerHour: i < recent ? recentRate : rate,
              analyzedHours: 6,
            ),
        ];

    Future<void> pumpI(WidgetTester t, ana.Metric<ana.CvhrDistribution> m,
        {double scale = 1}) async {
      t.view.physicalSize = Size(390 * 3, 4000 * 3 * scale);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Investigate('resp_rate',
              data: InvestigateData(day: _day(0), cvhrDist: m)),
        ),
      ));
      await t.pumpAndSettle();
    }

    testWidgets('it names no condition, no number and no severity', (t) async {
      await pumpI(t, ana.cvhrPersonalDistribution(nights(20, recent: 3)));
      expect(find.textContaining('ACROSS 20 OF YOUR OWN NIGHTS'), findsOneWidget);
      expect(find.textContaining('running higher'), findsOneWidget);
      // The vocabulary that turns a screen into a diagnosis, in any casing.
      final page = t
          .widgetList<Text>(find.byType(Text))
          .map((w) => (w.data ?? '').toLowerCase())
          .join(' ');
      for (final banned in const [
        'apnea',
        'apnoea',
        'hypopnea',
        'ahi',
        'mild',
        'moderate',
        'severe',
        'you have',
        'disorder',
      ]) {
        expect(page.contains(banned), isFalse, reason: 'said "$banned"');
      }
    });

    testWidgets('a quiet screen refuses to clear anything', (t) async {
      await pumpI(t, ana.cvhrPersonalDistribution(nights(20)));
      // The same-card refusal, in the state where a user most wants it to be
      // reassurance. Not a footnote, not a tooltip, not conditional.
      expect(find.textContaining('nothing here is a negative result'),
          findsOneWidget);
      expect(find.textContaining('a clinician can test that properly'),
          findsOneWidget);
      // And it never generalises from the aggregate to a night.
      expect(find.textContaining('says anything about any one night'),
          findsOneWidget);
    });

    testWidgets('too few nights says so instead of showing a partial one',
        (t) async {
      await pumpI(t, ana.cvhrPersonalDistribution(nights(3)));
      expect(find.text('Not enough nights for the across-nights view'),
          findsOneWidget);
      expect(find.textContaining('running higher'), findsNothing);
      // The pipeline's own reason, VERBATIM. This is Nerd stats — the raw
      // diagnostic is what the surface is FOR, and the prettifier that used to
      // rewrite `need_baseline:nights=3/5` into English threw away the one
      // detail someone opening this screen came for.
      expect(find.textContaining('need_baseline:nights=3/5'), findsOneWidget);
    });

    testWidgets('the card survives 3.1x text', (t) async {
      await pumpI(t, ana.cvhrPersonalDistribution(nights(20)), scale: 3.1);
      expect(find.textContaining('nothing here is a negative result'),
          findsOneWidget);
    });
  });

  // ── SLP-08: which two nights, and only over pairs the mask accepted ────────
  group('the pair that broke your regularity', () {
    /// The `regularity` envelope as `crossday_pipeline` emits it, with the two
    /// dates it resolves each pair's day index into.
    Map<String, dynamic> reg(List<(String, String, double)> pairs) => {
          'value': {
            'sri': 62.0,
            'days': pairs.length + 1,
            'cases': 1440 * pairs.length,
            'pairs': [
              for (final (a, b, s) in pairs)
                {'prev_date': a, 'date': b, 'sri': s, 'cases': 1440},
            ],
          },
          'tier': 'high',
          'confidence': .8,
        };

    Future<void> pumpR(WidgetTester t, CircadianData d,
        {double scale = 1}) async {
      t.view.physicalSize = Size(390 * 3, 4000 * 3 * scale);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: CircadianDetail(data: d),
        ),
      ));
      await t.pumpAndSettle();
    }

    test('the worst accepted pair leads, and a thin pair never gets here',
        () async {
      // The 12→13 pair is the worst of the three the analytics EMITTED. A pair
      // the validity mask left too thin is dropped upstream (phillipsSri's
      // `minPairCases`), so a half-unobserved weekend cannot top this list for
      // having no data — the fixture models that by simply not carrying it.
      final d = await CircadianData.load(_FakeRepo(insights: {
        'regularity': reg(const [
          ('2026-08-10', '2026-08-11', 71.0),
          ('2026-08-12', '2026-08-13', 18.0),
          ('2026-08-14', '2026-08-15', 55.0),
        ]),
      }));
      expect(d.sriPairs.length, 3);
      expect(d.sriPairs.first['date'], '2026-08-13');
      expect(d.sriPairs.first['sri'], 18.0);
    });

    testWidgets('two rows, behind a tap, and never a verdict', (t) async {
      final d = CircadianData(
        regularity: const Metric(
            value: 62, confidence: .8, tier: MetricTier.high),
        sriPairs: const [
          {'prev_date': '2026-08-12', 'date': '2026-08-13', 'sri': 18.0},
          {'prev_date': '2026-08-14', 'date': '2026-08-15', 'sri': 55.0},
        ],
      );
      await pumpR(t, d);
      // Density 2 is unchanged until it is asked for.
      expect(find.text('Regularity index'), findsOneWidget);
      expect(find.text('Nights least alike'), findsNothing);

      await t.tap(find.text('Which nights'));
      await t.pumpAndSettle();
      expect(find.text('12 Aug → 13 Aug'), findsOneWidget);
      expect(find.text('18 / 100'), findsOneWidget);
      // The pair that agreed MOST is not on screen — one row's worth of fact,
      // not a ranking of the user's weeks.
      expect(find.textContaining('14 Aug'), findsNothing);
      // The guard the item is mostly made of.
      expect(find.textContaining('The pair that matched least'), findsOneWidget);
      expect(find.textContaining('not a worse night'), findsOneWidget);
    });

    testWidgets('no pairs, no tap', (t) async {
      await pumpR(
        t,
        const CircadianData(
            regularity:
                Metric(value: 62, confidence: .8, tier: MetricTier.high)),
      );
      expect(find.text('Regularity index'), findsOneWidget);
      expect(find.text('Which nights'), findsNothing);
    });

    testWidgets('the rows survive 3.1x text', (t) async {
      await pumpR(
        t,
        const CircadianData(
          regularity:
              Metric(value: 62, confidence: .8, tier: MetricTier.high),
          sriPairs: [
            {'prev_date': '2026-08-12', 'date': '2026-08-13', 'sri': 18.0},
          ],
        ),
        scale: 3.1,
      );
      await t.tap(find.text('Which nights'));
      await t.pumpAndSettle();
      expect(find.text('12 Aug → 13 Aug'), findsOneWidget);
    });
  });

  // ── CV-06: a band, holes that stay holes, and no cause anywhere ───────────
  group('the shape of the night', () {
    /// `hrv_night_shape` as the pipeline emits it: [n] bins [width] apart, with
    /// the bins named in [gaps] under the beat floor and therefore null.
    Map<String, dynamic> shape(
            {int n = 9, int width = 1800, Set<int> gaps = const {}}) =>
        {
          'value': {
            'bins': [
              for (var i = 0; i < n; i++)
                {
                  't': i * width,
                  'n_beats': gaps.contains(i) ? 40 : 900,
                  'rmssd_ms': gaps.contains(i) ? null : 30.0 + i * 3,
                  'lo_ms': gaps.contains(i) ? null : 26.0 + i * 3,
                  'hi_ms': gaps.contains(i) ? null : 34.0 + i * 3,
                },
            ],
            'first_third_ms': 33.0,
            'last_third_ms': 51.0,
            'last_over_first': 1.545454,
          },
          'tier': 'high',
          'confidence': .7,
          'origin_ms': DateTime(2026, 8, 15, 23, 30).millisecondsSinceEpoch,
        };

    Future<void> pumpH(WidgetTester t, Map<String, dynamic> hrv,
        {double scale = 1}) async {
      t.view.physicalSize = Size(390 * 3, 6000 * 3 * scale);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Investigate('hrv',
              data: InvestigateData(day: _day(0), hrv: hrv)),
        ),
      ));
      await t.pumpAndSettle();
    }

    testWidgets('three lines on one axis — the band, not a line', (t) async {
      await pumpH(t, {'night_shape': shape()});
      expect(find.text('Shape of the night'), findsOneWidget);
      // The corridor is drawn as lo/hi/mid against ONE shared AxisSpec: an edge
      // drawn off an axis fitted to the middle is a clipped edge.
      final lines = t
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<LineChart>()
          .where((l) => l.axis != null)
          .toList();
      expect(lines.length, greaterThanOrEqualTo(3));
      expect(lines.map((l) => l.axis).toSet().length, 1);
      // The band's edges set the scale, so the top edge is inside it.
      expect(lines.first.axis!.max, greaterThanOrEqualTo(58.0));
      // The legend names the outer pair as the estimator's spread, and the
      // footnote refuses to explain the shape it just drew.
      expect(find.text('Sampling range'), findsOneWidget);
      expect(find.textContaining('describes the night and cannot explain it'),
          findsOneWidget);
      expect(find.textContaining('equally consistent with alcohol'),
          findsOneWidget);
      // The ratio is a ratio. No adjective, no direction, no colour.
      expect(find.text('1.55'), findsOneWidget);
      expect(find.text('9 of 9'), findsOneWidget);
      // The cut the item made on purpose: "time to the first bin within 10% of
      // the night's max" is not computed and must never be added — it jumps by
      // hours between adjacent nights on identical physiology.
      expect(find.textContaining('first bin'), findsNothing);
    });

    testWidgets('a bin under the beat floor stays a hole', (t) async {
      await pumpH(t, {'night_shape': shape(gaps: {3, 4})});
      expect(find.text('7 of 9'), findsOneWidget);
      expect(find.textContaining('gaps, not zeroes'), findsOneWidget);
      // The painter is handed the nulls, not a compacted series — that is what
      // makes it break the line across a charging gap instead of drawing over
      // it.
      final mid = t
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<LineChart>()
          .firstWhere((l) => l.axis != null && l.d.length == 9);
      expect(mid.d[3], isNull);
      expect(mid.d.whereType<double>().length, 7);
    });

    testWidgets('an abstaining night quotes the estimator, not a guess',
        (t) async {
      await pumpH(t, {
        'night_shape': {
          'value': '—',
          'tier': 'high',
          'note': 'night spans 1.2 h — under three 30-min bins there is no '
              'shape to describe',
        }
      });
      expect(find.text('No shape for this night'), findsOneWidget);
      expect(find.textContaining('under three 30-min bins'), findsOneWidget);
      expect(find.text('Shape of the night'), findsNothing);
    });

    testWidgets('a bundle without the key says nothing at all', (t) async {
      await pumpH(t, const {});
      expect(find.text('No shape for this night'), findsNothing);
      expect(find.text('Shape of the night'), findsNothing);
    });

    testWidgets('the panel survives 3.1x text', (t) async {
      await pumpH(t, {'night_shape': shape()}, scale: 3.1);
      expect(find.text('Shape of the night'), findsOneWidget);
    });
  });

  // ── RESP-05: a floor, outside sleep, and usually nothing at all ───────────
  group('resting breathing rate while awake', () {
    /// A `resp_day` line: [vs] as {t, v} at five-minute spacing from [from].
    List<Map<String, num>> line(int from, List<double> vs) => [
          for (var i = 0; i < vs.length; i++)
            {'t': from + i * 300, 'v': vs[i]},
        ];

    Future<void> pumpB(WidgetTester t, InvestigateData d,
        {double scale = 1}) async {
      t.view.physicalSize = Size(390 * 3, 5000 * 3 * scale);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Investigate('resp_rate', data: d),
        ),
      ));
      await t.pumpAndSettle();
    }

    testWidgets('the night is not the day — sleep windows are excluded',
        (t) async {
      const night = 1000000, morning = 1030000;
      await pumpB(
        t,
        InvestigateData(
          day: _day(0),
          windowStart: night,
          windowEnd: night + 25000,
          // Four windows inside the sleep window at a low nocturnal rate, three
          // outside it. Only the outside three may be read, so the "lowest" is
          // 14.1 and never the 11.0 the user was asleep for.
          timeline: {
            'resp': [
              ...line(night + 600, const [11.0, 11.4, 11.2, 12.0]),
              ...line(morning, const [15.2, 14.1, 16.8]),
            ],
          },
        ),
      );
      expect(find.text('3'), findsOneWidget);
      expect(find.text('14.1 br/min'), findsOneWidget);
      expect(find.text('16.8 br/min'), findsOneWidget);
      expect(find.textContaining('11.0'), findsNothing);
      // It is a floor and it says so, in both directions.
      expect(find.textContaining('A floor, not a rate for the day'),
          findsOneWidget);
      expect(find.textContaining('breathing while you move cannot be '
          'recovered'), findsOneWidget);
    });

    testWidgets('the common case is nothing, and it is written as such',
        (t) async {
      const night = 1000000;
      await pumpB(
        t,
        InvestigateData(
          day: _day(0),
          windowStart: night,
          windowEnd: night + 25000,
          timeline: {
            'resp': [...line(night + 600, const [11.0, 11.4, 11.2])],
          },
        ),
      );
      expect(find.text('No resting breathing rate away from sleep'),
          findsOneWidget);
      expect(find.textContaining('a day you were moving, not a day anything '
          'went wrong'), findsOneWidget);
      expect(find.text('Lowest'), findsNothing);
    });

    testWidgets('no sleep window means it abstains rather than counts the night',
        (t) async {
      await pumpB(
        t,
        InvestigateData(
          day: _day(0),
          timeline: {'resp': line(1030000, const [15.2, 14.1, 16.8, 15.9])},
        ),
      );
      // Four windows, and still nothing: with no window there is nothing to
      // subtract, and the stillest stretches of an unsegmented day are exactly
      // the ones that were sleep.
      expect(find.text('No resting breathing rate away from sleep'),
          findsOneWidget);
      expect(find.text('Lowest'), findsNothing);
    });

    testWidgets('the panel survives 3.1x text', (t) async {
      const night = 1000000;
      await pumpB(
        t,
        InvestigateData(
          day: _day(0),
          windowStart: night,
          windowEnd: night + 25000,
          timeline: {'resp': line(1030000, const [15.2, 14.1, 16.8])},
        ),
        scale: 3.1,
      );
      expect(find.text('Breathing at rest, awake'.toUpperCase()),
          findsOneWidget);
    });
  });
}
