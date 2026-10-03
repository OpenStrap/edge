// Regression tests for three quieter derivation defects:
//
//  * the deliberate widening of the nocturnal search window was a NO-OP,
//    because the coordinator only ever LOADED substrate back to the previous
//    18:00 while the day model searches from the previous NOON — so
//    `searchStart = max(dataStart, …)` clipped it straight back and any sleep
//    onset before 18:00 was truncated to the slice start;
//  * the habitual-midsleep prior converted HISTORICAL sleep blocks using the
//    CURRENT UTC offset, so re-deriving days from the other side of a DST
//    transition (or a trip) shifted them by an hour and could change which
//    candidate sleep was selected;
//  * `_buildWakeDayFeatures` substituted age 30 / 70 kg / sex 'm' / RHR 60 for
//    a user who never entered a profile and then PERSISTED strain / calories /
//    calories_total as real scalars — fabricated numbers wearing real numbers'
//    clothes, against the never-impute contract the rest of the layer keeps.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/data/db.dart';

/// A flat 1 Hz substrate over [durSec] starting at [startSec], HR [hr].
Substrate _synthDay(int startSec, int durSec, {int hr = 82}) {
  final ts = <int>[];
  final hrs = <int>[];
  final ax = <double>[], ay = <double>[], az = <double>[];
  for (var i = 0; i < durSec; i++) {
    ts.add(startSec + i);
    hrs.add(hr + (i % 7)); // gentle deterministic variation, never 0
    // Enough orientation change to produce real motion minutes.
    ax.add(0.05 * ((i % 60) / 60.0));
    ay.add(0.05 * ((i % 30) / 30.0));
    az.add(0.98);
  }
  final n = ts.length;
  return Substrate(
    tsSec: ts,
    hr: hrs,
    rrTsMs: const [],
    rrMs: const [],
    ax: ax,
    ay: ay,
    az: az,
    spo2Red: List<int>.filled(n, 0),
    spo2Ir: List<int>.filled(n, 0),
    skinTemp: List<int>.filled(n, 3000),
    skinContact: List<int>.filled(n, 0),
    // Stamped, or there is no HR ceiling and everything banded on it (strain,
    // TRIMP, zones, calories) abstains — see hr_max.dart.
    deviceFamily: 'gen4',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_day_window_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  // ── the loaded window must cover the whole documented search window ────────

  group('target-day substrate window', () {
    test('reaches back to the previous local NOON, not 18:00', () {
      const dayId = '2026-04-10';
      final dayStart = DateTime(2026, 4, 10).millisecondsSinceEpoch ~/ 1000;
      final dayEnd = DateTime(2026, 4, 11).millisecondsSinceEpoch ~/ 1000;

      final (from, to) = DerivationEngine().debugTargetDayWindow(dayId);

      expect(dayStart - from, kNocturnalSearchLookbackSec,
          reason: 'calendarDays searches from dayStart − '
              'kNocturnalSearchLookbackSec; loading less means '
              '`searchStart = max(dataStart, …)` silently clips it back');
      expect(dayStart - from, 12 * 3600, reason: 'the previous local NOON');
      expect(from, lessThan(dayStart - 6 * 3600),
          reason: 'strictly wider than the old prev-18:00 window, which made '
              'the documented widening a no-op');
      expect(to, dayEnd - 1);
    });

    test('the constant the loader uses is the one the day model searches with',
        () {
      // Two call sites, one constant — they cannot drift apart again.
      const dayId = '2026-10-25'; // a European DST-transition date
      final dayStart = DateTime(2026, 10, 25).millisecondsSinceEpoch ~/ 1000;
      final (from, _) = DerivationEngine().debugTargetDayWindow(dayId);
      expect(from, dayStart - kNocturnalSearchLookbackSec);
    });
  });

  // ── the habitual-midsleep prior is resolved AT THE DAY, not at "now" ───────

  group('historical timezone offset', () {
    test('tzOffsetSecondsAt resolves per instant, not once for today', () {
      final jan = DateTime(2020, 1, 15, 3, 0).millisecondsSinceEpoch ~/ 1000;
      final jul = DateTime(2020, 7, 15, 3, 0).millisecondsSinceEpoch ~/ 1000;
      for (final t in [jan, jul]) {
        expect(
          tzOffsetSecondsAt(t),
          DateTime.fromMillisecondsSinceEpoch(t * 1000, isUtc: false)
              .timeZoneOffset
              .inSeconds,
          reason: 'must ask the platform for the offset that applied THEN',
        );
      }
      // In a DST-observing zone the two instants disagree; a constant
      // "today's offset" cannot equal both.
      final janOff = tzOffsetSecondsAt(jan);
      final julOff = tzOffsetSecondsAt(jul);
      if (janOff != julOff) {
        final nowOff = DateTime.now().timeZoneOffset.inSeconds;
        expect(janOff == nowOff && julOff == nowOff, isFalse);
      }
    });

    test('the habitual prior is fed STORED history and resolved per block', () {
      // Zone-independent: inject the resolver and inspect what it was asked
      // for. The old code never asked at all — it read
      // `DateTime.now().timeZoneOffset`, a constant applied to every
      // historical day regardless of the offset actually in effect then.
      //
      // It also could never ask, because the only history it had was the days
      // inside THIS call and a live call spans ~36 h against a 14-day minimum.
      // `priorSleep` is the stored history; the resolver is asked once per
      // history block, so being asked at all proves the prior ran.
      final dayStart = DateTime(2020, 1, 15).millisecondsSinceEpoch ~/ 1000;
      final sub = _synthDay(dayStart + 3600, 900);
      // 14 nights of 23:00 → 07:00, one per day, ending the day before.
      final prior = <({int startSec, int endSec, String dayKey})>[
        for (var d = 14; d >= 1; d--)
          (
            startSec: dayStart - d * 86400 - 3600,
            endSec: dayStart - d * 86400 + 7 * 3600,
            dayKey: '2020-01-${(15 - d).toString().padLeft(2, '0')}',
          ),
      ];
      List<int> askedWith(List<({int startSec, int endSec, String dayKey})> h) {
        final asked = <int>[];
        final days = calendarDays(
          sub,
          // An override forces the segmentation branch (and therefore the
          // habitual-midsleep prior) to run on a short synthetic capture.
          override: SleepWindowOverride(
            dayId: '2020-01-15',
            onsetSec: dayStart + 3700,
            offsetSec: dayStart + 4300,
            source: 'manual',
          ),
          priorSleep: h,
          tzOffsetAt: (t) {
            asked.add(t);
            return DateTime.fromMillisecondsSinceEpoch(t * 1000).timeZoneOffset
                .inSeconds;
          },
        );
        expect(days, isNotEmpty);
        return asked;
      }

      expect(askedWith(const []), isEmpty,
          reason: 'no history → the prior abstains, nothing to convert');

      final asked = askedWith(prior);
      expect(asked, isNotEmpty,
          reason: 'stored history must REACH the prior — without it the '
              'selector is stuck on the 03:30 cold-start anchor forever');
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      for (final t in asked) {
        expect((t - nowSec).abs(), greaterThan(86400),
            reason: 'a historical instant, emphatically not "now"');
        expect(t, lessThan(dayStart),
            reason: 'each block converts at ITS OWN instant, not one frozen '
                'offset for the whole history (the DST bypass)');
      }
    });
  });

  // ── never impute a profile ────────────────────────────────────────────────

  group('absent profile abstains instead of imputing', () {
    // 2 h of daytime 1 Hz data on one calendar day — no sleep, so every minute
    // is wake and the wake-day feature block runs in full.
    final dayStart = DateTime(2026, 4, 10).millisecondsSinceEpoch ~/ 1000;

    Future<Map<String, double?>> deriveWith(
      Profile profile,
      String dayLabel,
      int localDayStart,
    ) async {
      final sub = _synthDay(localDayStart + 9 * 3600, 2 * 3600);
      await DerivationEngine()
          .deriveImportedDays(sub, profile, {dayLabel});
      final out = <String, double?>{};
      for (final key in const [
        'strain',
        'trimp',
        'calories',
        'calories_total',
        'steps',
      ]) {
        out[key] = await LocalDb.metricValueOn(dayLabel, key);
      }
      return out;
    }

    test('no profile → no strain, no calories, no TDEE', () async {
      final got = await deriveWith(const Profile(), '2026-04-10', dayStart);
      expect(got['strain'], isNull,
          reason: 'Banister TRIMP needs a real resting HR, HRmax and sex — '
              'age 30 / RHR 60 / sex m were fabricated');
      expect(got['calories'], isNull,
          reason: 'Keytel needs real age, weight and sex');
      expect(got['calories_total'], isNull,
          reason: 'Mifflin BMR needs real anthropometrics');
    });

    test('a day with no gait-capable source has NO step count at all',
        () async {
      // This test used to assert the opposite ("steps still compute without a
      // profile"), and it passed only because the old code persisted a hard
      // 0.0 for an abstaining estimator — a fabricated measurement dressed as
      // data. There is no `live_coverage` row in this fixture, so nothing that
      // can resolve gait measured this day, so the honest output is nothing.
      //
      // A 1 Hz wrist stream cannot count steps: gait is sub-Nyquist there, and
      // wrist amplitude ranks arm work above walking. See kAlgoVersion v55.
      final got = await deriveWith(const Profile(), '2026-04-11',
          DateTime(2026, 4, 11).millisecondsSinceEpoch ~/ 1000);
      expect(got['steps'], isNull,
          reason: 'no real pedometer covered this day — absent, not zero');

      // ...and it must be ABSENT, not a zero sitting in the series where it
      // would drag every average and "most steps" record down.
      expect(await LocalDb.metricValueOn('2026-04-11', 'steps'), isNull);

      // The bundle's own `steps` block must be absent-shaped too, not just
      // value-less. (The previous assertion here checked `got.containsKey`,
      // which was VACUOUS: `got` is built by the local helper above, which
      // seeds every key unconditionally, so it could never fail whatever the
      // derivation did.)
      final row = await LocalDb.dayResult('2026-04-11');
      final bundle =
          jsonDecode(row!['payload_json'] as String) as Map<String, dynamic>;
      final steps = bundle['steps'] as Map<String, dynamic>;
      expect(steps['value'], isNull);
      expect(steps['confidence'], 0.0);
      expect(steps['inputs_used'], isEmpty,
          reason: 'nothing was used, because nothing was measured');
      // NOT 'ESTIMATE': `Metric.parse` maps that tier to `beta: true` and would
      // badge a card that has no number on it as an estimate. Nothing here
      // estimates anything — that is the entire point of this change.
      expect(steps['tier'], isNull);
    });

    test('a real profile still produces strain and calories', () async {
      final got = await deriveWith(
        const Profile(
          ageYears: 34,
          weightKg: 72,
          heightCm: 178,
          sex: 'm',
          restingHrManual: 55,
        ),
        '2026-04-12',
        DateTime(2026, 4, 12).millisecondsSinceEpoch ~/ 1000,
      );
      expect(got['strain'], isNotNull,
          reason: 'the abstention must be about MISSING inputs only');
      expect(got['calories'], isNotNull);
      expect(got['calories_total'], isNotNull);
    });
  });

  // ── absent accel is not stillness ─────────────────────────────────────────

  group('a day with no gravity vector publishes no movement figure', () {
    // gen5 thin 1 Hz and gen4 R10-historical decode HR without a usable accel,
    // so the whole day lands as exact (0,0,0) — the absent sentinel. Both
    // `_activeMinutes` and `_restlessness` skip every such second and then
    // returned the zeros they started with: "0 active minutes" and "a
    // perfectly still, unbroken night", measured from nothing.
    test('active_min is absent, not 0', () async {
      const dayLabel = '2026-04-13';
      final dayStart = DateTime(2026, 4, 13).millisecondsSinceEpoch ~/ 1000;
      final sub = _synthDay(dayStart + 9 * 3600, 2 * 3600);
      final flat = Substrate(
        tsSec: sub.tsSec,
        hr: sub.hr,
        rrTsMs: const [],
        rrMs: const [],
        ax: List<double>.filled(sub.length, 0),
        ay: List<double>.filled(sub.length, 0),
        az: List<double>.filled(sub.length, 0),
        spo2Red: sub.spo2Red,
        spo2Ir: sub.spo2Ir,
        skinTemp: sub.skinTemp,
        skinContact: sub.skinContact,
        deviceFamily: sub.deviceFamily,
      );
      await DerivationEngine().deriveImportedDays(flat, const Profile(), {
        dayLabel,
      });
      expect(
        await LocalDb.metricValueOn(dayLabel, 'active_min'),
        isNull,
        reason: 'no gravity vector all day — absent, not a measured zero',
      );

      // Control: the SAME day with a real gravity vector does publish one, so
      // the null above is about the absent accel and not about the fixture.
      const ctlLabel = '2026-04-14';
      final ctlStart = DateTime(2026, 4, 14).millisecondsSinceEpoch ~/ 1000;
      await DerivationEngine().deriveImportedDays(
        _synthDay(ctlStart + 9 * 3600, 2 * 3600),
        const Profile(),
        {ctlLabel},
      );
      expect(await LocalDb.metricValueOn(ctlLabel, 'active_min'), isNotNull);
    });
  });

  // An import day's substrate exists only in the importer's buffer, which is
  // evicted right after the call, so a day skipped as busy is lost for good.
  test('an import day waits out a running derive instead of being skipped',
      () async {
    final engine = DerivationEngine();
    final aStart = DateTime(2026, 4, 20).millisecondsSinceEpoch ~/ 1000;
    final bStart = DateTime(2026, 4, 21).millisecondsSinceEpoch ~/ 1000;
    final a = engine.deriveImportedDays(
      _synthDay(aStart + 9 * 3600, 2 * 3600),
      const Profile(),
      {'2026-04-20'},
    );
    final b = engine.deriveImportedDays(
      _synthDay(bStart + 9 * 3600, 2 * 3600),
      const Profile(),
      {'2026-04-21'},
    );
    expect(await Future.wait([a, b]), [1, 1]);
  });
}
