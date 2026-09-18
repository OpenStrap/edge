// The home-widget / watch snapshot is a WRITE-ONLY surface: whatever Dart puts
// in the App Group is what the user sees on their lock screen, with no chance
// to notice it was invented. Every int key uses -1 for "no data" and the native
// readers gate on it — so a nullable metric must never be written as a plausible
// default instead.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart'
    show kAlgoVersion;
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/models/payloads.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart' show readinessBand;
import 'package:openstrap_edge/widget/widget_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, Object?> written;
  late List<String> iosConfigCalls;

  setUp(() {
    written = {};
    iosConfigCalls = [];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('home_widget'),
        (call) async {
      if (call.method == 'saveWidgetData') {
        final args = (call.arguments as Map).cast<String, Object?>();
        written[args['id'] as String] = args['data'];
      }
      return true;
    });
    messenger.setMockMethodCallHandler(
        const MethodChannel('openstrap/ios_config'), (call) async {
      iosConfigCalls.add(call.method);
      return call.method == 'appGroupIdentifier' ? 'group.test' : null;
    });
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('home_widget'), null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('openstrap/ios_config'), null);
  });

  // THROUGH THE REAL PAYLOAD, deliberately. These two used to hand
  // `WidgetService.push` a `TodayData.fromJson({'sleep': {'duration_min': 437}})`
  // that `getToday()` never produces — the seam wrote `need_min: 480`
  // unconditionally — so the guard passed while every widget, the Watch and the
  // lock screen drew their sleep ring against a fabricated 8 h denominator.
  // Driving `LocalRepositoryImpl.getToday()` is the whole point: the sentinel is
  // only reachable if the PAYLOAD omits the key.
  group('sleep need, end to end from the repository', () {
    late LocalRepositoryImpl repo;

    // 437 min asleep, and a stored crossday need of 462 min for the second test.
    String todayBundle() => jsonEncode({
          'date': todayLabel(),
          'scalars': {'readiness': 74.0, 'rhr': 52.0},
          'sleep': {
            'accounting': {
              'value': {'tst_sec': 437 * 60, 'efficiency_pct': 91.0},
            },
          },
        });

    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'openstrap_widget_sentinels_test.db';
      await databaseFactory.deleteDatabase(
        p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
      );
      repo = LocalRepositoryImpl(getProfileMap: () => const {});
    });

    tearDownAll(() async {
      await LocalDb.close();
      await databaseFactory.deleteDatabase(
        p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
      );
    });

    setUp(() async {
      final db = await LocalDb.instance;
      await db.delete('day_result');
      await db.delete('baselines');
      await LocalDb.putDayResult(
        dayId: todayLabel(),
        algoVersion: kAlgoVersion,
        payloadJson: todayBundle(),
        windowJson: '{}',
      );
      await LocalDb.refreshComputeFreshness();
    });

    test('an unlearned sleep need reaches the App Group as the -1 sentinel, '
        'never as a fabricated 8h00m', () async {
      // No crossday artifact at all — the ordinary state until enough
      // undisturbed nights exist for `sleepNeed` to estimate one.
      final t = TodayData.fromJson(await repo.getToday());
      expect(t.sleepNeed.isEmpty, isTrue);

      await WidgetService.push(t);
      expect(written['sleep_min'], 437);
      // 480 here put a hard 8h00m need on the home widget AND the watch, and
      // the sleep ring was drawn as a fraction of that invented denominator.
      expect(written['sleep_need_min'], -1);
    });

    test('a LEARNED sleep need is published as itself', () async {
      await LocalDb.putBaseline(
        'crossday',
        jsonEncode({
          'algo_version': kAlgoVersion,
          'built_for_day': todayLabel(),
          'sleep_coach': {
            'need': {
              'value': {'need_sec': 462 * 60},
              'confidence': 0.7,
              'tier': 'ESTIMATE',
            },
          },
        }),
      );

      await WidgetService.push(TodayData.fromJson(await repo.getToday()));
      // 462, the value `crossday_pipeline` computed — the only sleep need this
      // app has.
      expect(written['sleep_need_min'], 462);
    });
  });

  // `readinessBand` is the ONLY copy of the readiness cut-offs. The widget, the
  // Watch and Siri each used to carry their own, so a score of 65 was green on
  // the phone, orange on the widget and yellow on the wrist — and 38 was red
  // here and yellow there. They now render the published tier and label, which
  // makes these boundaries a four-surface contract.
  group('readiness banding', () {
    test('tiers at the boundaries', () {
      expect(readinessBand(100).tier, 3);
      expect(readinessBand(61).tier, 3);
      expect(readinessBand(60.9).tier, 2);
      expect(readinessBand(50).tier, 2);
      expect(readinessBand(37).tier, 2);
      expect(readinessBand(36.9).tier, 1);
      expect(readinessBand(26).tier, 1);
      expect(readinessBand(25.9).tier, 0);
      expect(readinessBand(0).tier, 0);
    });

    // The bug the cut-offs above exist to fix (#250): the score's centre is 50
    // by construction, so whatever band contains 50 is the one a typical night
    // gets. It must not be a warning.
    test('a night at personal median is the neutral band, not a warning', () {
      expect(readinessBand(50).label, 'Steady');
    });

    test('an unscored day is tier -1, which every native reader paints grey',
        () {
      expect(readinessBand(null).tier, -1);
    });

    test('every scored tier has a label to say out loud', () {
      for (final v in const [0, 40, 60, 80, 100]) {
        expect(readinessBand(v).label, isNotEmpty);
      }
    });

    test('the tier and its label are published for the native surfaces',
        () async {
      await WidgetService.push(TodayData.fromJson({
        'daily': {'readiness': 50},
      }));
      expect(written['readiness'], 50);
      expect(written['readiness_tier'], 2);
      expect(written['readiness_band'], 'Steady');
    });

    test('an unscored readiness publishes the -1 / "" sentinels, never a band',
        () async {
      await WidgetService.push(TodayData.fromJson({'daily': const {}}));
      expect(written['readiness'], -1);
      expect(written['readiness_tier'], -1);
      expect(written['readiness_band'], '');
    });

    test('clear() blanks both — the widget outlives the database', () async {
      await WidgetService.clear();
      expect(written['readiness_tier'], -1);
      expect(written['readiness_band'], '');
    });
  });

  // Every mutator that writes to the App Group snapshot must also mirror it
  // to the paired Apple Watch (`_syncWatch`) — otherwise the watch keeps
  // rendering a stale value until some unrelated write happens to fire next.
  // `setThemeDark` used to omit this call.
  group('watch sync fires on every mutator', () {
    test('setThemeDark syncs the watch', () async {
      await WidgetService.setThemeDark(true);
      expect(iosConfigCalls, contains('syncWatch'));
    });

    test('push syncs the watch', () async {
      await WidgetService.push(TodayData.fromJson({'daily': const {}}));
      expect(iosConfigCalls, contains('syncWatch'));
    });

    test('pushBattery syncs the watch', () async {
      await WidgetService.pushBattery(80, false, 'Strap');
      expect(iosConfigCalls, contains('syncWatch'));
    });

    test('clear syncs the watch', () async {
      await WidgetService.clear();
      expect(iosConfigCalls, contains('syncWatch'));
    });
  });

  // The three home rings, resolved in Dart because two of their four states
  // CANNOT be worked out natively: the calibration counts and the pipeline's
  // reason both live in a metric's `note`, which never used to cross the App
  // Group. The widget drew one dimmed empty circle for both, so "four more
  // nights and this fills in" and "the band recorded nothing" were the same
  // picture, forever.
  group('the home rings', () {
    test('a measured ring publishes the number, what it is out of, and a sweep',
        () async {
      await WidgetService.push(TodayData.fromJson({
        'daily': {
          'readiness': 74,
          'strain': 12.4,
        },
        'sleep': {'duration_min': 437, 'need_min': 465},
      }));
      expect(written['ring_recovery_state'], 0);
      expect(written['ring_recovery_value'], '74');
      expect(written['ring_recovery_sub'], 'Good to go');
      expect(written['ring_strain_value'], '12.4');
      expect(written['ring_strain_sub'], 'of 21');
      expect(written['ring_sleep_value'], '7h 17m');
      expect(written['ring_sleep_sub'], 'of 7h 45m');
      expect(written['ring_sleep_frac'], closeTo(437 / 465, 1e-9));
      // Nothing is missing, so nothing has a reason.
      expect(written['ring_recovery_why'], '');
    });

    // The one absence that is PROGRESS rather than a gap, and the only one a
    // ring may honestly draw an arc for.
    test('a baseline still filling is calibration progress, not a low score',
        () async {
      await WidgetService.push(TodayData.fromJson({
        'daily': {
          'readiness': {'value': null, 'note': 'need_baseline:have=2,need=5'},
        },
      }));
      expect(written['readiness'], -1);
      expect(written['ring_recovery_state'], 1);
      expect(written['ring_recovery_value'], 'Calibrating');
      expect(written['ring_recovery_sub'], '2 of 5 nights');
      expect(written['ring_recovery_frac'], closeTo(0.4, 1e-9));
    });

    test('an absence is a word and a reason — never a dash, never an arc',
        () async {
      await WidgetService.push(TodayData.fromJson({
        'daily': {'readiness': null},
        'sleep': const {},
      }));
      expect(written['ring_sleep_state'], 2);
      expect(written['ring_sleep_value'], 'No sleep');
      expect(written['ring_sleep_frac'], -1.0);
      // Every absent ring says something. A blank circle says nothing at all,
      // which on a home screen is worse than a number.
      for (final r in const ['recovery', 'strain', 'sleep']) {
        expect(written['ring_${r}_value'], isNotEmpty, reason: r);
        expect(written['ring_${r}_value'], isNot(contains('—')), reason: r);
        expect(written['ring_${r}_why'], isNotEmpty, reason: r);
      }
    });

    test('sleep with no learned need is measured but unscaled, not filled to 8h',
        () async {
      await WidgetService.push(TodayData.fromJson({
        'sleep': {'duration_min': 437},
      }));
      expect(written['ring_sleep_state'], 0);
      expect(written['ring_sleep_value'], '7h 17m');
      expect(written['ring_sleep_sub'], 'No target yet');
      expect(written['ring_sleep_frac'], -1.0);
    });
  });

  // `getToday` holds the last night that scored over until today's settles, so
  // every morning before the first sync the overnight block belongs to the
  // night BEFORE last. Home refuses those numbers rather than printing them in
  // the today slot (`overnightMetric`), and a home screen is the surface where
  // a number is read as today's hardest of all.
  group('a night that is not today\'s', () {
    Map<String, dynamic> heldOver(String state) => {
          'daily': {'readiness': 74, 'resting_hr': 52, 'strain': 9.1},
          'sleep': {'duration_min': 437},
          'hrv': {'rmssd': 62.0, 'baseline': 58.0},
          'status': {
            'showing_prior_overnight': true,
            'overnight_state': state,
            'overnight_day': todayLabel(),
          },
        };

    test('its numbers are refused and the reason travels in their place',
        () async {
      await WidgetService.push(TodayData.fromJson(heldOver('missing')));
      expect(written['readiness'], -1);
      expect(written['readiness_tier'], -1);
      expect(written['sleep_min'], -1);
      expect(written['hrv'], -1);
      expect(written['rhr'], -1);
      expect(written['ring_recovery_value'], 'Not scored');
      expect(written['ring_recovery_why'],
          'Nothing from last night has reached the app yet.');
      expect(written['overnight_why'],
          'Nothing from last night has reached the app yet.');
    });

    test('a night still being worked out is a different sentence — it resolves '
        'on its own and asks nothing of anyone', () async {
      await WidgetService.push(TodayData.fromJson(heldOver('building')));
      expect(written['ring_sleep_why'], 'Last night is still being worked out.');
    });

    test('the DAY\'s strain is not an overnight figure and survives', () async {
      await WidgetService.push(TodayData.fromJson(heldOver('missing')));
      expect(written['strain'], 9.1);
      expect(written['ring_strain_value'], '9.1');
    });
  });

  // The widget, the Watch mirror and the Siri intents all render whatever was
  // last written here, with no way to notice how old it is — the native readers
  // gate on `has_data` and nothing else. So a snapshot the app KNOWS is old has
  // to fall through to their no-data state rather than sit on a lock screen
  // looking like this morning's number.
  group('staleness', () {
    TodayData at(String day) => TodayData.fromJson({
          'daily': {
            'readiness': {'value': 74},
          },
          'sleep': {'duration_min': 437},
          'status': {'today_day': day, 'overnight_day': day},
        });

    String label(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';

    final now = DateTime(2026, 8, 15);

    test('today is fresh', () {
      expect(WidgetService.isStale(at(label(now)), now: now), isFalse);
    });

    test('last night is fresh — it is the normal state of every metric here',
        () {
      expect(
          WidgetService.isStale(at(label(DateTime(2026, 8, 14))), now: now),
          isFalse);
    });

    test('anything older is stale', () {
      expect(WidgetService.isStale(at(label(DateTime(2026, 8, 13))), now: now),
          isTrue);
      expect(WidgetService.isStale(at(label(DateTime(2026, 7, 30))), now: now),
          isTrue);
    });

    test('an unknown age is not a claim of staleness', () {
      expect(
          WidgetService.isStale(TodayData.fromJson({'daily': const {}}),
              now: now),
          isFalse);
    });

    test('a stale snapshot is published with has_data false', () async {
      await WidgetService.push(at('2020-01-01'));
      expect(written['has_data'], isFalse);
      // The numbers are still written — the native readers just don't show
      // them — so nothing has to be invented when the app catches up.
      expect(written['sleep_min'], 437);
    });
  });
}
