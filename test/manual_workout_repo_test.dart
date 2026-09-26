// Manual / retimed workout logging — the REPO path, against a real database.
//
// `manual_session_test.dart` pins the pure policy. This pins the wiring: that
// `logManualWorkout` / `setWorkoutWindow` actually read the 1 Hz substrate over
// the window they were given, persist a row the workout screens can render,
// retire the auto-detect suggestion they supersede, and — the reported bug —
// that widening a clipped window really does raise the numbers.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/compute/manual_session.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_edge/gps/route_models.dart';

/// A profile with every anchor the scored metrics need.
Map<String, dynamic> _profile() => {
      'age': 30,
      'weight_kg': 75.0,
      'height_cm': 180.0,
      'sex': 'm',
      'resting_hr': 55,
    };

Sample _sample(int ts, int counter, int hr) => Sample(
      tsEpoch: ts,
      counter: counter,
      hr: hr,
      rrIntervalsMs: const [],
      ax: 0,
      ay: 0,
      az: 0,
      spo2RedRaw: 0,
      spo2IrRaw: 0,
      skinTempRaw: 0,
    );

RawRecord _raw(int ts, int counter) => RawRecord(
      counter: counter,
      packetType: 47,
      hex: 'manual$counter',
      capturedAt: ts * 1000,
      recTs: ts,
    );

/// Lay down 1 Hz HR at [hr] bpm for [seconds] starting at [start].
/// One row per 10 s keeps the fixture small; the estimators weight each sample
/// by the elapsed gap, so the window is still covered end to end.
/// STAMPED gen4: since TS-03a the zone ceiling comes from `estimatedMaxHr(age,
/// family)`, so an UNSTAMPED window scores nothing at all — which is the
/// honest answer for an import or a pre-v41 row, and not what this fixture is
/// about. `commitSyncBatch` is the seam that carries the stamp.
Future<void> _seedHr(int start, int seconds, int hr,
    {String? deviceFamily = 'gen4'}) async {
  final raws = <RawRecord>[];
  final samples = <Sample?>[];
  for (var i = 0; i < seconds; i += 10) {
    final ts = start + i;
    raws.add(_raw(ts, ts));
    samples.add(_sample(ts, ts, hr));
  }
  await LocalDb.commitSyncBatch(raws, samples, deviceFamily: deviceFamily);
}

void main() {
  // A fixed, comfortably-past window so nothing here depends on wall clock
  // beyond "this is in the past", which it always is.
  final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final sessionStart = nowSec - 6 * 3600;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_manual_workout_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  final repo = LocalRepositoryImpl(getProfileMap: _profile);

  test(
    'logManualWorkout scores a past window from the 1 Hz substrate',
    () async {
      // An hour at 150 bpm.
      await _seedHr(sessionStart, 3600, 150);

      final res = await repo.logManualWorkout(
        startTs: sessionStart,
        endTs: sessionStart + 3600,
        type: 'run',
      );
      expect(res['unscored'], isFalse);
      expect(res['hr_samples'], greaterThan(0));

      final w = await repo.getWorkout(res['workout_id'] as String);
      expect(w['status'], 'done');
      expect(w['source'], 'manual');
      expect(w['type'], 'run');
      expect(w['duration_min'], 60);
      // Scored from real HR — not inferred from the duration.
      expect(w['strain'], isNotNull);
      expect(w['calories'], isNotNull);
      expect(w['avg_hr'], 150);
      // getWorkout's on-read enrichment fills the detail screen's chart.
      expect((w['hr'] as List?) ?? const [], isNotEmpty);
      expect((w['zone_bands'] as List?) ?? const [], isNotEmpty);
    },
  );

  test(
    'an UNSTAMPED window still scores off the AGE estimate',
    () async {
      // REVERSAL of the TS-03a over-application. The ceiling here is Tanaka
      // `208 − 0.7·age` — a population regression that reads no sensor — so an
      // unstamped window (every pre-schema-41 row, every import, every raw
      // replay) is banded on it exactly as a stamped one is. Gating it on
      // `device_family` cost zones/strain/calories on a user's whole history
      // for a number the strap cannot move.
      //
      // What DOES still refuse for an unstamped strap is the ceiling the band
      // MEASURED (analytics `observed_max_hr.dart`, whose motion-corroboration
      // floor is 0.10 g on gen4 and 0.04 g on gen5) — see the seam's own tests.
      const unstampedStart = 1_700_100_000;
      await _seedHr(unstampedStart, 3600, 150, deviceFamily: null);

      final res = await repo.logManualWorkout(
        startTs: unstampedStart,
        endTs: unstampedStart + 3600,
        type: 'run',
      );
      final w = await repo.getWorkout(res['workout_id'] as String);
      expect(w['avg_hr'], 150);
      expect(w['strain'], isNotNull);
      expect(w['calories'], isNotNull);
      expect((w['zone_bands'] as List?) ?? const [], isNotEmpty);
      expect((w['zone_min'] as List?) ?? const [], isNotEmpty);
    },
  );

  test(
    'a window with no substrate is still saved, just honestly unscored',
    () async {
      // Two days before anything we seeded — no decoded_onehz rows at all.
      final start = sessionStart - 2 * 86400;
      final res = await repo.logManualWorkout(
        startTs: start,
        endTs: start + 1800,
        type: 'strength',
      );
      expect(res['unscored'], isTrue);
      expect(res['hr_samples'], 0);

      final w = await repo.getWorkout(res['workout_id'] as String);
      // The athlete's assertion about the window is kept...
      expect(w['duration_min'], 30);
      expect(w['type'], 'strength');
      // ...but nothing is invented to fill the gaps.
      expect(w['strain'], isNull);
      expect(w['calories'], isNull);
      expect(w['max_hr'], isNull);
    },
  );

  test(
    'setWorkoutWindow widening a clipped detection raises the numbers — '
    'the whole point of the feature',
    () async {
      // A 2 h block of real training at 150 bpm.
      final start = sessionStart - 5 * 86400;
      await _seedHr(start, 7200, 150);

      // What the detector reported: the hard-effort CORE only, 25 minutes of a
      // two-hour session, written the way _logDetectedSession writes one.
      const detectedMin = 25;
      await LocalDb.putSession({
        'id': 'auto:$start',
        'start_ts': start,
        'end_ts': start + detectedMin * 60,
        'type': 'cardio',
        'status': 'done',
        'duration_min': detectedMin,
        'source': 'auto',
        'created_at': start * 1000,
      });

      // Score it over the detected window first, for a like-for-like baseline.
      final narrow = await repo.setWorkoutWindow(
        'auto:$start',
        startTs: start,
        endTs: start + detectedMin * 60,
      );
      final before = await repo.getWorkout(narrow['workout_id'] as String);

      // Now say what actually happened: the full two hours.
      final wide = await repo.setWorkoutWindow(
        'auto:$start',
        startTs: start,
        endTs: start + 7200,
      );
      final after = await repo.getWorkout(wide['workout_id'] as String);

      expect(after['duration_min'], 120);
      expect(
        (after['strain'] as num).toDouble(),
        greaterThan((before['strain'] as num).toDouble()),
        reason: 'a longer window at the same intensity must score more strain',
      );
      expect(
        (after['calories'] as num).toDouble(),
        greaterThan((before['calories'] as num).toDouble()),
      );
      // Retiming must not re-attribute how the session was captured, and must
      // not fork a second row.
      expect(after['id'], 'auto:$start');
      expect(after['source'], 'auto');
    },
  );

  test(
    'retiming does not leave the old row behind as a duplicate',
    () async {
      final start = sessionStart - 9 * 86400;
      await LocalDb.putSession({
        'id': 'w-retime',
        'start_ts': start,
        'end_ts': start + 600,
        'type': 'run',
        'status': 'done',
        'duration_min': 10,
        'source': 'manual',
        'created_at': start * 1000,
      });
      await repo.setWorkoutWindow('w-retime',
          startTs: start, endTs: start + 3600);

      final rows = await LocalDb.sessionsInRange(start - 60, start + 7200);
      expect(rows.where((r) => r['id'] == 'w-retime').length, 1);
      expect(rows.firstWhere((r) => r['id'] == 'w-retime')['duration_min'], 60);
    },
  );

  test(
    'logging a session retires the auto-detect suggestion it covers',
    () async {
      final start = sessionStart - 12 * 86400;
      await LocalDb.putWorkoutSuggestion({
        'id': 'sug-covered',
        'date': '2026-01-01',
        'start_ts': start + 900, // the fragment, inside the real session
        'end_ts': start + 2400,
        'duration_min': 25,
        'sport': 'cardio',
        'created_at': start * 1000,
      });
      await LocalDb.putWorkoutSuggestion({
        'id': 'sug-elsewhere',
        'date': '2026-01-01',
        'start_ts': start + 40000, // an unrelated effort later that day
        'end_ts': start + 42000,
        'duration_min': 33,
        'sport': 'run',
        'created_at': start * 1000,
      });

      await repo.logManualWorkout(
        startTs: start,
        endTs: start + 3600,
        type: 'cardio',
      );

      final active = await LocalDb.activeWorkoutSuggestions();
      final ids = [for (final s in active) s['id']];
      expect(ids, isNot(contains('sug-covered')),
          reason: 'the fragment the athlete just superseded must not keep '
              'asking "did you work out?"');
      expect(ids, contains('sug-elsewhere'),
          reason: 'an unrelated suggestion must survive');
    },
  );

  group('GPS routes follow the session window', () {
    // A run tracked for 90 min, one fix every 30 s heading due east.
    Future<void> seedRoute(String id, int start, int seconds) async {
      final rows = <Map<String, Object?>>[];
      for (var i = 0, seq = 0; i < seconds; i += 30, seq++) {
        rows.add(RoutePoint(
          seq: seq,
          tsMs: (start + i) * 1000,
          lat: 51.5,
          lng: -0.12 + seq * 0.0005, // ~35 m per step
        ).toRow(id));
      }
      await LocalDb.appendRoutePoints(id, rows);
    }

    test(
      'narrowing a session clips its route — no 90 minutes of GPS under a '
      '60 minute hero',
      () async {
        final start = sessionStart - 30 * 86400;
        await _seedHr(start, 5400, 140);
        await LocalDb.putSession({
          'id': 'w-route',
          'start_ts': start,
          'end_ts': start + 5400, // 90 min as recorded
          'type': 'run',
          'status': 'done',
          'duration_min': 90,
          'source': 'manual',
          'created_at': start * 1000,
        });
        await seedRoute('w-route', start, 5400);

        final full = await repo.getWorkoutRoute('w-route');
        expect(full, isNotNull);
        final fullPoints = full!.points.length;
        final fullDistance = full.distanceMeters;

        // You actually ran an hour and forgot to stop the watch.
        await repo.setWorkoutWindow('w-route',
            startTs: start, endTs: start + 3600);
        final clipped = await repo.getWorkoutRoute('w-route');

        expect(clipped, isNotNull);
        expect(clipped!.points.length, lessThan(fullPoints));
        expect(clipped.distanceMeters, lessThan(fullDistance));
        // Every surviving fix sits inside the corrected window.
        for (final p in clipped.points) {
          expect(p.tsMs, greaterThanOrEqualTo((start - 5) * 1000));
          expect(p.tsMs, lessThanOrEqualTo((start + 3600 + 5) * 1000));
        }
      },
    );

    test(
      'clipping to a window with under two fixes yields no map at all',
      () async {
        final start = sessionStart - 33 * 86400;
        await LocalDb.putSession({
          'id': 'w-route-tiny',
          'start_ts': start,
          'end_ts': start + 3600,
          'type': 'run',
          'status': 'done',
          'duration_min': 60,
          'source': 'manual',
          'created_at': start * 1000,
        });
        // All the GPS sits in the SECOND hour.
        await seedRoute('w-route-tiny', start + 3600, 1800);

        // A single orphaned pin and a zero-length distance is worse than
        // honestly showing no route.
        expect(await repo.getWorkoutRoute('w-route-tiny'), isNull);
      },
    );

    test('a manually logged workout simply has no route', () async {
      final start = sessionStart - 36 * 86400;
      final res = await repo.logManualWorkout(
          startTs: start, endTs: start + 1800, type: 'run');
      expect(await repo.getWorkoutRoute(res['workout_id'] as String), isNull);
    });

    test('retiming preserves the route rows themselves (id is stable)',
        () async {
      // Self-contained: this used to read the rows the narrowing test above
      // happened to leave behind, so it failed the moment it ran alone.
      final start = sessionStart - 46 * 86400;
      await LocalDb.putSession({
        'id': 'w-route-keep',
        'start_ts': start,
        'end_ts': start + 5400,
        'type': 'run',
        'status': 'done',
        'duration_min': 90,
        'source': 'manual',
        'created_at': start * 1000,
      });
      await seedRoute('w-route-keep', start, 5400);
      final before = (await LocalDb.routePoints('w-route-keep')).length;
      await repo.setWorkoutWindow('w-route-keep',
          startTs: start, endTs: start + 3600);

      // The cascade delete lives on deleteSession; putSession must not touch
      // workout_route, or widening back would silently lose the map forever.
      final rows = await LocalDb.routePoints('w-route-keep');
      expect(rows.length, before);
      expect(rows.length, greaterThan(2),
          reason: 'the full route must survive a narrowing retime, so the '
              'athlete can widen the window back again');
    });
  });

  test('savedSessionSpans surfaces saved windows for the overlap check',
      () async {
    // Seed our own row rather than leaning on whatever earlier tests left.
    final start = sessionStart - 50 * 86400;
    await repo.logManualWorkout(
        startTs: start, endTs: start + 1800, type: 'walk');

    final spans = await repo.savedSessionSpans();
    expect(spans, isNotEmpty);
    expect(spans.map((e) => e.id), contains(manualSessionId(start)));
    // Every span is a real, ordered window.
    for (final s in spans) {
      expect(s.endSec, greaterThan(s.startSec));
      expect(s.id, isNotEmpty);
    }
  });

  group('the write seam re-validates — the form is not the only guard', () {
    test('an overlapping window is refused, not silently written', () async {
      final start = sessionStart - 20 * 86400;
      await repo.logManualWorkout(
          startTs: start, endTs: start + 3600, type: 'run');

      // A second session landing in the middle of the first.
      // await: expect() on an async callback returns before the future
      // settles, so the "nothing was written" query below would race it.
      await expectLater(
        () => repo.logManualWorkout(
            startTs: start + 1800, endTs: start + 5400, type: 'cycle'),
        throwsA(isA<ManualWindowException>().having(
            (e) => e.error, 'error', ManualWindowError.overlapsExisting)),
      );

      // Nothing was written.
      final rows = await LocalDb.sessionsInRange(start + 1800, start + 1800);
      expect(rows.where((r) => r['start_ts'] == start + 1800), isEmpty);
    });

    test('a future window is refused', () async {
      final future = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 7200;
      await expectLater(
        () => repo.logManualWorkout(
            startTs: future, endTs: future + 3600, type: 'run'),
        throwsA(isA<ManualWindowException>()
            .having((e) => e.error, 'error', ManualWindowError.inFuture)),
      );
    });

    test('a sub-minute window is refused', () async {
      final start = sessionStart - 25 * 86400;
      await expectLater(
        () => repo.logManualWorkout(
            startTs: start, endTs: start + 30, type: 'run'),
        throwsA(isA<ManualWindowException>()
            .having((e) => e.error, 'error', ManualWindowError.tooShort)),
      );
    });

    test('retiming a session never collides with its own existing span',
        () async {
      // Regression: without editingId, widening ANY saved session overlaps
      // itself and would be permanently unfixable.
      final start = sessionStart - 40 * 86400;
      await LocalDb.putSession({
        'id': 'w-self-overlap',
        'start_ts': start,
        'end_ts': start + 600,
        'type': 'run',
        'status': 'done',
        'duration_min': 10,
        'source': 'manual',
        'created_at': start * 1000,
      });
      await expectLater(
        repo.setWorkoutWindow('w-self-overlap',
            startTs: start, endTs: start + 7200),
        completes,
      );
    });

    test('a still-live session cannot be retimed', () async {
      // buildManualSessionRow always writes status 'done', so retiming a
      // running session would silently end it.
      final start = sessionStart - 43 * 86400;
      await LocalDb.putSession({
        'id': 'w-live',
        'start_ts': start,
        'end_ts': null,
        'type': 'run',
        'status': 'live',
        'source': 'manual',
        'created_at': start * 1000,
      });
      // A live row with no end_ts now overlap-checks through "now" — clean
      // it up so it doesn't shadow every later test's window.
      addTearDown(() => LocalDb.deleteSession('w-live'));
      await expectLater(
        repo.setWorkoutWindow('w-live', startTs: start, endTs: start + 3600),
        throwsA(isA<StateError>()),
      );
      final row = await LocalDb.session('w-live');
      expect(row!['status'], 'live', reason: 'must not have been ended');
    });

    test(
        'confirming a manual window that overlaps a still-live session is '
        'refused, not double-booked', () async {
      // Regression: a live row's null end_ts used to drop it out of
      // savedSessionSpans entirely, so a manual confirm overlapping the
      // still-running session would go through and double-count the effort.
      final start = sessionStart - 44 * 86400;
      await LocalDb.putSession({
        'id': 'w-live-overlap',
        'start_ts': start,
        'end_ts': null,
        'type': 'run',
        'status': 'live',
        'source': 'manual',
        'created_at': start * 1000,
      });
      addTearDown(() => LocalDb.deleteSession('w-live-overlap'));
      await expectLater(
        () => repo.logManualWorkout(
            startTs: start + 60, endTs: start + 3660, type: 'run'),
        throwsA(isA<ManualWindowException>().having(
            (e) => e.error, 'error', ManualWindowError.overlapsExisting)),
      );
    });
  });

  test(
    're-logging the identical window replaces rather than duplicates',
    () async {
      final start = sessionStart - 15 * 86400;
      final a = await repo.logManualWorkout(
          startTs: start, endTs: start + 1800, type: 'yoga');
      final b = await repo.logManualWorkout(
          startTs: start, endTs: start + 1800, type: 'yoga');
      expect(a['workout_id'], b['workout_id']);

      final rows = await LocalDb.sessionsInRange(start - 60, start + 3600);
      expect(rows.where((r) => r['id'] == a['workout_id']).length, 1);
    },
  );
}
