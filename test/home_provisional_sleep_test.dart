// #638 — the morning after sleep, the Sleep tab already showed last night
// while Home said "Last night is still being worked out" for about an hour,
// and for hours if the band stopped recording at wake.
//
// Root cause: `LocalDb.refreshComputeFreshness` holds today's row back as an
// overnight until `overnightSettled()` — the data edge an hour past wake —
// because mid-drain the stager closes the window wherever the sync stopped
// (#448). That is the right gate for READINESS, and it is the gate the Sleep
// tab never had. So `getToday` now serves the held row's SLEEP summary on its
// own key, marked provisional, and nothing on the recovery side reads it.
//
// These pin both halves: Home gets the night's sleep figures as soon as the
// stored row has them, and readiness / HRV / resting HR stay withheld until it
// settles (#448, #578).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/models/payloads.dart' show todayHeadlineOf;
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Map<String, dynamic> _env(num v) => {
      'value': v,
      'confidence': .8,
      'tier': 'ESTIMATE',
      'unit': 'min',
    };

const _needInsights = {
  'sleep_coach': {
    'need': {
      'value': {'need_sec': 27720}, // 462 min
      'confidence': .7,
      'tier': 'ESTIMATE',
    },
  },
};

/// A `getToday` payload for a morning whose night is still arriving: the
/// overnight block is refused (`sleep` empty), and the sleep summary rides on
/// `sleep_provisional`.
Map<String, dynamic> _provisionalToday() => {
      'daily': const {},
      'sleep': const {},
      'sleep_provisional': {
        'duration_min': _env(360),
        'efficiency': _env(88),
        'provisional': true,
      },
      'status': {
        'today_day': '2026-10-09',
        'overnight_state': 'building',
        'recovery_state': 'night_in_progress',
      },
    };

const _deepStages = {
  'deep_min': 70,
  'rem_min': 95,
  'light_min': 165,
  'awake_min': 30,
};

// ── a fake repository, for the loaders ─────────────────────────────────────

class _Repo extends LocalRepository {
  _Repo({
    this.today = const {},
    this.insights = const {},
    this.nights = const {},
  });

  final Map<String, dynamic> today, insights;

  /// Stored nights by day, so a test can prove WHICH day was asked for.
  final Map<String, Map<String, dynamic>> nights;

  /// Every day `getDaySleepV2` was asked for, in order.
  final List<String> asked = [];

  @override
  Future<Map<String, dynamic>> getToday() async => today;
  @override
  Future<Map<String, dynamic>> getInsights() async => insights;
  @override
  Future<Map<String, dynamic>> getProfile() async => const {};
  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async {
    asked.add(date);
    return nights[date] ?? const {};
  }
}

// ── rendering ──────────────────────────────────────────────────────────────

Metric _min(num v) =>
    Metric(value: v, unit: 'min', confidence: .8, tier: MetricTier.estimate);

Future<void> _pump(WidgetTester t, HomeData d) async {
  t.view.physicalSize = const Size(390 * 3, 800 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: MediaQuery(
      data: const MediaQueryData(size: Size(390, 800)),
      child: Scaffold(body: SingleChildScrollView(child: RingTrio(d: d))),
    ),
  ));
  await t.pumpAndSettle();
}

void main() {
  group('getToday: the night on screen while it is still arriving', () {
    late Database db;
    late String dir;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    setUp(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'openstrap_home_provisional_sleep_test.db';
      dir = await databaseFactory.getDatabasesPath();
      await LocalDb.close();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
      db = await LocalDb.instance;
    });

    tearDown(() async {
      await LocalDb.close();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });

    Future<void> seed({
      required String day,
      required int wakeSec,
      required int edgeSec,
      required int tstSec,
      num? readiness,
      num? rmssd,
    }) async {
      await db.insert('day_result', {
        'day_id': day,
        'algo_version': kAlgoVersion,
        'payload_json': jsonEncode({
          'scalars': {'rmssd': ?rmssd, 'readiness': ?readiness},
          'sleep': {
            'window': {
              'value': {'offset_ms': wakeSec * 1000},
            },
            'accounting': {
              'value': {'tst_sec': tstSec, 'efficiency_pct': 88},
            },
          },
        }),
        'window_json': jsonEncode({'offset_ms': wakeSec * 1000}),
        'computed_at': 1,
        'finalized': 0,
      });
      await db.insert('decoded_onehz', {
        'ts_ms': edgeSec * 1000,
        'rec_ts': edgeSec,
        'counter': edgeSec,
        'hr': 60,
      });
    }

    Future<Map<String, dynamic>> today() =>
        LocalRepositoryImpl(getProfileMap: () => const {}).getToday();

    /// The `compute_freshness` row the pipeline would hold for TODAY.
    ///
    /// Needed only for a seed at a FIXED hour: `recoveryStateOf` settles a
    /// wake == edge night once the REAL clock is 12 h past that wake, so a
    /// literal 03:00 seed would stop being `night_in_progress` whenever this
    /// suite ran after 15:00. The state below is the one it derives at 03:05,
    /// asserted with it in the 03:00 test.
    Future<void> seedFreshness({required String recoveryState}) =>
        LocalDb.putComputeFreshness(
            'today',
            jsonEncode({
              'today_day': todayLabel(),
              'activity_day': todayLabel(),
              'activity_state': 'ready',
              'overnight_day': null,
              'overnight_state': 'building',
              'recovery_state': recoveryState,
              'showing_prior_overnight': false,
            }));

    test('a window the drain has not passed is served as provisional sleep',
        () async {
      // The measured 08:40 export: the stager closed the window at the newest
      // record, so wake IS the edge and the night has not settled.
      final wake = nowSec - 10 * 60;
      await seed(
          day: todayLabel(),
          wakeSec: wake,
          edgeSec: wake,
          tstSec: 6 * 3600,
          readiness: 2);

      final t = await today();
      expect((t['status'] as Map)['overnight_state'], isNot('ready'));
      expect((t['status'] as Map)['recovery_state'], 'night_in_progress');

      final prov = t['sleep_provisional'] as Map?;
      expect(prov, isNotNull, reason: 'the stored night is on screen');
      expect(prov!['provisional'], true,
          reason: 'a consumer cannot read it as a settled night by shape');
      expect((prov['duration_min'] as Map)['value'], 360);
      expect((prov['efficiency'] as Map)['value'], 88);
    });

    test('the provisional block carries the sleep half only', () async {
      final wake = nowSec - 10 * 60;
      await seed(
          day: todayLabel(),
          wakeSec: wake,
          edgeSec: wake,
          tstSec: 6 * 3600,
          readiness: 2,
          rmssd: 11);

      final t = await today();
      expect(t['sleep_provisional'], isNotNull);
      // #448 / #578 unchanged: no held-over night and no settled night means
      // every recovery figure is absent, the same as before this change.
      expect(t['hrv'], isNull);
      expect(t['nocturnal'], isNull);
      final daily = t['daily'] as Map;
      expect(Metric.parse(daily['readiness']).value, isNull);
      expect(Metric.parse(daily['resting_hr']).value, isNull);
      expect(todayHeadlineOf(t)['recovery'], isNull);
    });

    test('a settled night rides in `sleep` and is not served twice', () async {
      final wake = nowSec - 3 * 3600;
      await seed(
          day: todayLabel(),
          wakeSec: wake,
          edgeSec: wake + 2 * 3600,
          tstSec: 6 * 3600,
          readiness: 61);

      final t = await today();
      expect((t['status'] as Map)['overnight_state'], 'ready');
      expect(t['sleep_provisional'], isNull);
      expect(((t['sleep'] as Map)['duration_min'] as Map)['value'], 360);
      expect(((t['daily'] as Map)['readiness'] as Map)['value'], 61);
    });

    test('a 03:00 look at a night whose wake is the edge is night_in_progress',
        () async {
      // #739: `night_in_progress` covers two different moments. At 08:40 the
      // drain has not yet confirmed the wake, so "Finishing up" is right. At
      // 03:00 the user is still ASLEEP — the recovery ring says "Sleeping…" —
      // and the sleep note must not answer the same night with another word.
      final now = DateTime.now();
      final wake =
          DateTime(now.year, now.month, now.day, 3).millisecondsSinceEpoch ~/
              1000;
      await seed(
          day: todayLabel(), wakeSec: wake, edgeSec: wake, tstSec: 3 * 3600);
      await seedFreshness(recoveryState: 'night_in_progress');
      // The state the pipeline derives from exactly this row at 03:05: awake,
      // wake sitting on the edge, so nothing has confirmed the night is over.
      expect(
          recoveryStateOf(wakeSec: wake, dataEdgeSec: wake, nowSec: wake + 300),
          RecoveryState.nightInProgress);

      final payload =
          await LocalRepositoryImpl(getProfileMap: () => const {}).getToday();
      expect((payload['status'] as Map)['recovery_state'], 'night_in_progress');
      expect((payload['sleep_provisional'] as Map)['provisional'], true);
      // The card half of this — that state's note reads "Sleeping…" — is
      // pinned in `the ring and the card` below, off the same field.
    });

    test('a held-over prior night stays in `sleep` while today is provisional',
        () async {
      final now = DateTime.now();
      final yesterday = dayLabelOf(DateTime(now.year, now.month, now.day - 1));
      final wake = nowSec - 10 * 60;
      await seed(
          day: yesterday,
          wakeSec: nowSec - 24 * 3600,
          edgeSec: nowSec - 20 * 3600,
          tstSec: 7 * 3600,
          readiness: 70,
          rmssd: 77);
      await seed(
          day: todayLabel(),
          wakeSec: wake,
          edgeSec: wake,
          tstSec: 6 * 3600,
          readiness: 2,
          rmssd: 11);

      final t = await today();
      expect((t['status'] as Map)['showing_prior_overnight'], true);
      // `sleep` is still the night the caption names...
      expect(((t['sleep'] as Map)['duration_min'] as Map)['value'], 420);
      // ...and today's own night travels separately, so the two cannot be
      // confused for one another.
      final prov = t['sleep_provisional'] as Map;
      expect((prov['duration_min'] as Map)['value'], 360);
      // The recovery half is untouched: still the held-over night's (#578).
      expect((t['hrv'] as Map)['rmssd'], 77);
    });
  });

  group('HomeData.load', () {
    test('shows today\'s own night, marked provisional, with its own stages',
        () async {
      final repo = _Repo(
        today: _provisionalToday(),
        insights: _needInsights,
        nights: {'2026-10-09': _deepStages},
      );

      final d = await HomeData.load(repo);
      expect(d.sleepMin.value, 360);
      expect(d.sleepProvisional, isTrue);
      expect(d.sleepNeedMin.value, 462);
      expect(d.recoveryState, 'night_in_progress');
      // The recovery half is still withheld: readiness has no number.
      expect(d.readiness.value, isNull);
      // Stages come from TODAY's night, not from a prior one.
      expect(repo.asked, ['2026-10-09']);
      expect(d.sleepStages?.deep, 70);
      expect(d.sleepStages?.light, 165);
    });

    test('a settled night is not provisional', () async {
      final repo = _Repo(
        today: {
          'daily': {
            'readiness': {
              'value': 61,
              'confidence': .8,
              'tier': 'HIGH',
            },
          },
          'sleep': {'duration_min': _env(360)},
          'status': {
            'today_day': '2026-10-09',
            'overnight_state': 'ready',
            'recovery_state': 'final',
            'overnight_day': '2026-10-09',
            'showing_prior_overnight': false,
          },
        },
        insights: _needInsights,
        nights: {'2026-10-09': _deepStages},
      );

      final d = await HomeData.load(repo);
      expect(d.sleepMin.value, 360);
      expect(d.sleepProvisional, isFalse);
      expect(d.readiness.value, 61);
    });

    test('a held-over night with no provisional block stays absent', () async {
      // Today's row has no sleep window at all (a night not started), so there
      // is nothing of today's to show and the note must claim nothing.
      final repo = _Repo(
        today: {
          'daily': const {},
          'sleep': const {},
          'status': {
            'today_day': '2026-10-09',
            'overnight_state': 'building',
            'overnight_day': '2026-10-08',
            'showing_prior_overnight': true,
            'recovery_state': 'night_in_progress',
          },
        },
        insights: _needInsights,
        nights: {'2026-10-08': _deepStages},
      );

      final d = await HomeData.load(repo);
      expect(d.sleepMin.value, isNull);
      expect(d.sleepProvisional, isFalse);
      expect(d.sleepStages, isNull, reason: 'another night\'s stages');
      expect(d.sleepMin.note, isNotNull, reason: 'the reason travels');
      expect(repo.asked, isEmpty);
    });
  });

  group('the ring and the card', () {
    HomeData provisional(
            {bool provisional = true, String? recoveryState = 'provisional'}) =>
        HomeData(
          dayId: '2026-10-09',
          recoveryState: recoveryState,
          sleepMin: _min(360),
          sleepNeedMin: _min(462),
          sleepProvisional: provisional,
          sleepStages: const SleepStageMin(
              deep: 70, rem: 95, light: 165, awake: 30),
        );

    StageRing stageRing(WidgetTester t) => t
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => w.painter)
        .whereType<StageRing>()
        .single;

    testWidgets('the figure is drawn and the card says it is finishing up',
        (t) async {
      await _pump(t, provisional());
      expect(find.text('6h 00m'), findsOneWidget);
      expect(find.byKey(const ValueKey('home-note:provisional:sleep')),
          findsOneWidget);
      expect(find.text('Finishing up'), findsOneWidget);
      // 360 of a 462 need is 78% — under the 85% that presses, but a number
      // that can still move is never something to press on.
      expect(find.byKey(const ValueKey('home-why:sleep')), findsNothing);
    });

    testWidgets('while the night is in progress the note says Sleeping…, the '
        'recovery ring\'s own word', (t) async {
      await _pump(t, provisional(recoveryState: 'night_in_progress'));
      final note = find.byKey(const ValueKey('home-note:provisional:sleep'));
      expect(note, findsOneWidget);
      expect(find.descendant(of: note, matching: find.text('Sleeping…')),
          findsOneWidget);
      expect(find.text('Finishing up'), findsNothing);
      expect(find.text('Sleeping…'), findsNWidgets(2),
          reason: 'the recovery ring and the sleep note say one thing');
    });

    testWidgets('a provisional night\'s stage arcs are muted and keep their '
        'fractions', (t) async {
      final staged = provisional();
      await _pump(t, staged);
      final p = P.of(t.element(find.byType(RingTrio)));
      final muted = stageRing(t);
      expect(muted.arcs.map((a) => a.color).toSet(), {p.ink3},
          reason: 'a figure that can still move is drawn grey, arcs included');
      final model = sleepRingModel(
          durationMin: 360, stages: staged.sleepStages, needMin: 462);
      expect(muted.arcs.map((a) => a.fraction),
          model.arcs.map((a) => a.fraction),
          reason: 'only the colour is provisional; the split is the night\'s');

      await _pump(t, provisional(provisional: false, recoveryState: 'final'));
      final settled = stageRing(t);
      expect(settled.arcs.map((a) => a.color).toSet().contains(p.ink3), isFalse,
          reason: 'a settled night wears its stage colours');
    });

    testWidgets('the same figure once settled is a plain number with the '
        'short-of-need panel', (t) async {
      await _pump(t, provisional(provisional: false, recoveryState: 'final'));
      expect(find.text('6h 00m'), findsOneWidget);
      expect(find.byKey(const ValueKey('home-note:provisional:sleep')),
          findsNothing);
      expect(find.text('Finishing up'), findsNothing);
      expect(find.byKey(const ValueKey('home-why:sleep')), findsOneWidget);
    });
  });
}
