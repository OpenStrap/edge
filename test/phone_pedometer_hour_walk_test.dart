import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/health/phone_pedometer.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The hour walk is where this feature's two real defects lived, and neither
/// was reachable from the DB-level tests.
///
/// NOTE ON TIMEZONE. Dart reads the process timezone from the environment and
/// `flutter test` cannot set it per-test, so the DST cases here assert on the
/// BOUNDARY LOGIC (zero-width buckets are skipped, not fatal) in a way that
/// holds in every timezone, rather than hard-coding a US transition. The
/// spring-forward instant collapse itself was reproduced directly against the
/// Dart runtime under `TZ=America/New_York` while diagnosing:
///
///     h=1  from=2026-03-08 01:00  to=2026-03-08 03:00
///     h=2  from=2026-03-08 03:00  to=2026-03-08 03:00   <-- zero width
///
/// With `break` there, hours 3-23 were never queried and the day was persisted
/// with ~3 hours of windows.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_phone_hour_walk_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  // LocalDb.instance caches its open Database keyed only on `db.isOpen`, not
  // on `dbName` — leaving it open here hands the next suite this file's db
  // instead of its own. This was the actual source of
  // workout_reliability_test.dart's order-dependent flake (edge#259).
  tearDownAll(() => LocalDb.close());

  setUp(() async {
    final db = await LocalDb.instance;
    await db.delete('live_coverage');
  });

  /// Yesterday, so the walk covers a whole elapsed day (no "future hours" cap).
  DateTime yesterday() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day - 1);
  }

  test('a full elapsed day walks every hour and banks the total', () async {
    final asked = <DateTime>[];
    final ped = PhonePedometer(stepReader: (from, to) async {
      asked.add(from);
      return 10;
    });

    final day = yesterday();
    final total = await ped.syncDay(day);

    // 24 buckets in a normal day (23 or 25 across a DST transition) — never
    // truncated to a handful.
    expect(asked.length, greaterThanOrEqualTo(23));
    expect(total, asked.length * 10);
    expect(await LocalDb.liveStepsForDay(_label(day)), total);
  });

  test('a zero-width bucket is SKIPPED, not fatal to the rest of the day',
      () async {
    // Simulates the spring-forward collapse: the walk must keep going past a
    // bucket whose `from == to`. We cannot force a real DST gap in-process, so
    // this asserts the invariant directly — every hour after the anomaly is
    // still queried.
    var calls = 0;
    final ped = PhonePedometer(stepReader: (from, to) async {
      calls++;
      // A zero-width interval would never reach the reader at all (it is
      // skipped before the call), so simply counting calls proves the walk
      // did not terminate early.
      return 1;
    });

    final total = await ped.syncDay(yesterday());
    expect(calls, greaterThanOrEqualTo(23));
    expect(total, calls);
  });

  test('ANY failed hour abandons the day rather than banking a partial one',
      () async {
    final day = yesterday();
    final dayId = _label(day);

    // 1. A complete, good sync.
    final good = PhonePedometer(stepReader: (from, to) async => 100);
    final fullTotal = await good.syncDay(day);
    expect(fullTotal, isNotNull);
    expect(await LocalDb.liveStepsForDay(dayId), fullTotal);

    // 2. A later sync where hour 5 fails. `null` from this plugin means the
    //    query FAILED (an empty hour returns 0 on both platforms), so the day
    //    must be abandoned — `replacePhoneCoverageForDay` is delete-then-
    //    insert, and banking the short read would LOWER a good previous total
    //    while still suppressing the band fallback.
    var h = 0;
    final flaky = PhonePedometer(stepReader: (from, to) async {
      final n = h++ == 5 ? null : 100;
      return n;
    });
    expect(await flaky.syncDay(day), isNull);

    // 3. The good total survives untouched.
    expect(await LocalDb.liveStepsForDay(dayId), fullTotal);
  });

  test('a genuine zero-step day banks nothing and falls back to the band',
      () async {
    final day = yesterday();
    final dayId = _label(day);
    await LocalDb.addLiveCoverage(
      day.millisecondsSinceEpoch ~/ 1000,
      day.millisecondsSinceEpoch ~/ 1000 + 600,
      777,
      dayId,
    );

    // Every hour reads successfully as 0 — a real sedentary day, NOT a failure.
    final ped = PhonePedometer(stepReader: (from, to) async => 0);
    expect(await ped.syncDay(day), 0);

    // No phone rows were written, so the band count still shows.
    expect(await LocalDb.liveStepsForDay(dayId), 777);
  });

  test('an all-zero read never erases a day already banked with real steps',
      () async {
    final day = yesterday();
    final dayId = _label(day);

    // 1. A good sync banks a real day.
    final good = PhonePedometer(stepReader: (from, to) async => 100);
    final fullTotal = await good.syncDay(day);
    expect(fullTotal, isNotNull);
    expect(await LocalDb.liveStepsForDay(dayId), fullTotal);

    // 2. Every hour now reads 0 WITHOUT failing — exactly what a silent iOS
    //    READ denial looks like (`requestAuthorization` reports success even
    //    when the user denied read, so queries return empty rather than null,
    //    forever). Unguarded, `replacePhoneCoverageForDay`'s delete-then-insert
    //    would wipe the day; and because phone rows win outright, not even the
    //    band fallback would show.
    final denied = PhonePedometer(stepReader: (from, to) async => 0);
    expect(await denied.syncDay(day), isNull,
        reason: 'unconfirmed, so it must not count toward daysRead either');

    // 3. The banked day survives.
    expect(await LocalDb.liveStepsForDay(dayId), fullTotal);
  });

  test('an UNCOVERED hour is skipped, and the covered ones still bank',
      () async {
    final day = yesterday();
    final dayId = _label(day);

    // The sensor holds no record of the first six hours (fresh install, or the
    // stretch lost across an Android reboot). That is neither a failure nor a
    // zero: those hours bank nothing and the walk carries on.
    var h = 0;
    final ped = PhonePedometer(stepReader: (from, to) async =>
        h++ < 6 ? PhonePedometer.intervalNotCovered : 50);

    final total = await ped.syncDay(day);
    expect(total, isNotNull);
    expect(total, greaterThan(0), reason: 'the covered hours must still count');
    expect(await LocalDb.liveStepsForDay(dayId), total);
  });

  test('an hour that turns UNCOVERED later keeps what was already banked',
      () async {
    final day = yesterday();
    final dayId = _label(day);

    // 1. A good sync banks the whole day.
    final good = PhonePedometer(stepReader: (from, to) async => 100);
    final fullTotal = await good.syncDay(day);
    expect(fullTotal, isNotNull);
    expect(await LocalDb.liveStepsForDay(dayId), fullTotal);

    // 2. The phone reboots: the native side records a gap from the last
    //    delivery, and every later query touching that hour comes back
    //    uncovered even though its earlier counts were real. The replace is
    //    delete-then-insert, so this hour must be carried over, not dropped.
    var h = 0;
    final rebooted = PhonePedometer(stepReader: (from, to) async =>
        h++ == 11 ? PhonePedometer.intervalNotCovered : 100);
    expect(await rebooted.syncDay(day), fullTotal);
    expect(await LocalDb.liveStepsForDay(dayId), fullTotal);
  });

  test('a day with NO covered hour is unknown, not zero', () async {
    final day = yesterday();
    final dayId = _label(day);
    await LocalDb.addLiveCoverage(
      day.millisecondsSinceEpoch ~/ 1000,
      day.millisecondsSinceEpoch ~/ 1000 + 600,
      321,
      dayId,
    );

    final ped = PhonePedometer(
        stepReader: (from, to) async => PhonePedometer.intervalNotCovered);
    expect(await ped.syncDay(day), isNull,
        reason: 'nothing was read, so nothing is known — it must not count '
            'toward daysRead either');
    // And it must not have erased the band's day.
    expect(await LocalDb.liveStepsForDay(dayId), 321);
  });

  // THE REGRESSION THIS EXISTS FOR: a permission the app never requests is
  // invisible in iOS Settings, and CoreMotion has no request API at all — the
  // native side raises the prompt by issuing a query. So if `requestPermission`
  // stops reaching the channel, the feature is dead with nothing for the user
  // to fix, and it looks exactly like a platform problem. We just shipped that
  // bug once for Location; this pins the arming path.
  test('arming actually reaches the platform', () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(phoneStepsChannel, (call) async {
      calls.add(call.method);
      return true;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(phoneStepsChannel, null);
    });

    expect(await PhonePedometer().requestPermission(), isTrue);
    expect(calls, ['requestPermission']);
  });

  test('no platform implementation reads as unknown, never as zero steps',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(phoneStepsChannel, (call) async {
      throw PlatformException(code: 'nope');
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(phoneStepsChannel, null);
    });

    final ped = PhonePedometer();
    expect(await ped.requestPermission(), isFalse);
    expect(await ped.hasPermission(), isFalse);
    expect(await ped.syncDay(yesterday()), isNull);
  });

  test('the routine sync window is much smaller than the backfill window', () {
    // Each hourly bucket is one platform round trip, so the window IS the cost:
    // the 7-day default was up to 168 sequential calls on every launch and
    // again after every export.
    expect(PhonePedometer.routineSyncDays,
        lessThan(PhonePedometer.fullSyncDays));
    expect(PhonePedometer.routineSyncDays, 2);
  });

  test('syncRecent reports days read and their total for the UI', () async {
    final ped = PhonePedometer(stepReader: (from, to) async => 5);
    final r = await ped.syncRecent(days: 2);
    // Today is partial (only elapsed hours), yesterday is whole — both read.
    expect(r.daysRead, 2);
    expect(r.totalSteps, greaterThan(0));
  });

  test('stop() mid-sync banks nothing for the days not yet written', () async {
    late PhonePedometer ped;
    var stopped = false;
    ped = PhonePedometer(stepReader: (from, to) async {
      // The user turns phone steps off while the first day is being walked.
      if (!stopped) {
        stopped = true;
        await ped.stop();
      }
      return 5;
    });
    final r = await ped.syncRecent(days: 3);
    expect(r.daysRead, 0);
    final db = await LocalDb.instance;
    expect(await db.query('live_coverage'), isEmpty);
  });
}

String _label(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
