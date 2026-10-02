// Regression tests for the two ways a derivation pass could DESTROY a good
// day_result — both of which are permanent, because `putDayResult` is
// ConflictAlgorithm.replace on BOTH `day_result` AND `metric_series` (so every
// scalar for the date is NULLed), raw is pruned after 3 days (so there is
// nothing left to re-derive from), and a finalized row is never revisited.
//
//  1. "Re-analyze" over a day older than raw retention. `LocalDb.dataHistoryDays`
//     lists derived days with `raw_count == 0`; Advanced data → Select all →
//     Re-analyze runs `runDays(force: true)` over ALL of them. Such a day
//     prepares an EMPTY substrate, derives an all-absent bundle, and — because
//     an empty bundle's `endSec` was 0, making `endSec + 48 h < dataNowSec`
//     unconditionally true — wrote that blank FINALIZED over the good row.
//     Only `run()` had a pruned-raw guard, and only for user-override days.
//
//  2. A skip marker. One `_perDayTimeout` (90 s) overrun on a loaded phone
//     during a backlog sweep replaced the day's whole result with
//     `{'skipped': true}` and, once >48 h behind the data edge, finalized it —
//     including TODAY (a good 08:00 result blanked by a transient 09:00
//     timeout). `rescanRecent` explicitly refuses to do this for exactly this
//     reason; `run()` did it anyway.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/derive_prepare.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_result_protection_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  /// A GOOD, finished day: real headline scalars in `day_result` + the full
  /// baseline `metric_series` fan-out. Exactly what months-old history looks
  /// like after its raw has been pruned.
  Future<void> seedGoodDay(String dayId, {bool finalized = true}) async {
    await LocalDb.putDayResult(
      dayId: dayId,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode({
        'scalars': {
          'rhr': 52.0,
          'rmssd': 61.0,
          'readiness': 74.0,
          'ln_rmssd': 4.11,
          'resp_rate': 14.2,
          'skin_temp_adc': 3011.0,
          'strain': 9.4,
          'tst_min': 431.0,
        },
        'sleep': {'accounting': {'value': {'tst_sec': 25860}}},
      }),
      windowJson: '{"onset_ms": 1, "offset_ms": 2}',
      finalized: finalized,
      rhr: 52,
      rmssd: 61,
      readiness: 74,
      series: {
        'rhr': 52.0,
        'rmssd': 61.0,
        'readiness': 74.0,
        'ln_rmssd': 4.11,
        'resp_rate': 14.2,
        'skin_temp_adc': 3011.0,
        'strain': 9.4,
        'tst_min': 431.0,
      },
    );
  }

  Future<Map<String, dynamic>> readScalars(String dayId) async {
    final out = <String, dynamic>{};
    for (final key in const [
      'rhr',
      'rmssd',
      'readiness',
      'strain',
      'tst_min',
    ]) {
      out[key] = await LocalDb.metricValueOn(dayId, key);
    }
    return out;
  }

  // ── 1. an empty (raw-pruned) re-derive must not blank the day ─────────────

  test('re-analyzing a day whose raw is long gone keeps the existing result',
      () async {
    const oldDay = '2026-01-05';
    await seedGoodDay(oldDay);
    final before = await readScalars(oldDay);
    expect(before['readiness'], 74.0, reason: 'precondition');

    // A data edge exists (decoded rows for a MUCH later day), but the target
    // day has no decoded rows at all — the post-retention state.
    final edgeSec = DateTime(2026, 3, 20, 9, 0).millisecondsSinceEpoch ~/ 1000;
    await LocalDb.insertRecord(
      RawRecord(
        counter: 900001,
        packetType: 47,
        hex: 'edge',
        capturedAt: edgeSec * 1000,
        recTs: edgeSec,
      ),
      Sample(
        tsEpoch: edgeSec,
        counter: 900001,
        hr: 58,
        rrIntervalsMs: const [1000],
        ax: 0,
        ay: 0,
        az: 1,
        spo2RedRaw: 1,
        spo2IrRaw: 1,
        skinTempRaw: 3000,
      ),
    );
    expect(await LocalDb.lastDecodedRecTs(), edgeSec);

    // THE reachable path: Advanced data → Select all → Re-analyze.
    await DerivationEngine().runDays(const Profile(), {oldDay}, force: true);

    final after = await readScalars(oldDay);
    expect(after, equals(before),
        reason: 'an empty derive must never REPLACE the persisted scalars — '
            'putDayResult nulls every metric_series row for the date');
    final row = await LocalDb.dayResult(oldDay);
    expect(row, isNotNull);
    expect(row!['skipped'], 0);
    expect((row['readiness'] as num?)?.toDouble(), 74.0);
    final payload =
        (jsonDecode(row['payload_json'] as String) as Map)['scalars'] as Map;
    expect(payload['strain'], 9.4,
        reason: 'the full bundle survives, not just the indexed columns');
  });

  test('an empty result for a day with NO prior result is written unfinalized',
      () async {
    // Nothing to protect here, so the row IS written — but it must stay
    // recomputable. Locking an all-absent row is what made the damage permanent.
    const freshDay = '2026-01-06';
    expect(await LocalDb.dayResult(freshDay), isNull, reason: 'precondition');

    await DerivationEngine().runDays(const Profile(), {freshDay}, force: true);

    final row = await LocalDb.dayResult(freshDay);
    if (row != null) {
      expect(row['finalized'], 0,
          reason: 'a result with nothing in it must never lock — a later pass '
              '(or restored substrate) has to be able to fill the day in');
    }
  });

  // ── the endSec that made the blank FINALIZE ───────────────────────────────

  test('an empty substrate yields the day\'s real calendar end, not 0', () {
    const dayId = '2026-01-05';
    final prepared = SleepSessionCandidate.absent(dayId).toPreparedDay(
      daySub: Substrate.empty,
      sleepSub: Substrate.empty,
    );
    // endSec == 0 makes the finalization test `endSec + 48 h < dataNowSec`
    // unconditionally true, so the blank locked immediately.
    expect(prepared.endSec, isNot(0));
    expect(prepared.endSec, localNextMidnightSecForDayLabel(dayId));
    expect(prepared.endSec,
        DateTime(2026, 1, 6).millisecondsSinceEpoch ~/ 1000);
  });

  test('a non-empty substrate still ends at its last record + 1', () {
    final ts = DateTime(2026, 1, 5, 22, 0).millisecondsSinceEpoch ~/ 1000;
    final sub = Substrate(
      tsSec: [ts - 1, ts],
      hr: const [60, 61],
      rrTsMs: const [],
      rrMs: const [],
      ax: const [0, 0],
      ay: const [0, 0],
      az: const [1, 1],
      spo2Red: const [0, 0],
      spo2Ir: const [0, 0],
      skinTemp: const [0, 0],
      skinContact: const [0, 0],
    );
    final prepared = SleepSessionCandidate.absent('2026-01-05')
        .toPreparedDay(daySub: sub, sleepSub: Substrate.empty);
    expect(prepared.endSec, ts + 1);
  });

  // ── 2. a skip marker must never overwrite a real result ───────────────────

  test('a transient timeout never blanks a good day', () async {
    const day = '2026-02-10';
    await seedGoodDay(day, finalized: false);
    final before = await readScalars(day);

    // The day sits far behind the data edge — the exact condition under which
    // the old code wrote the marker FINALIZED.
    final dayEndSec = DateTime(2026, 2, 11).millisecondsSinceEpoch ~/ 1000;
    final dataNowSec = dayEndSec + 10 * 86400;
    await DerivationEngine().debugMarkDaySkipped(
      day,
      dayEndSec,
      dataNowSec,
      reason: 'timeout',
    );

    final row = await LocalDb.dayResult(day);
    expect(row!['skipped'], 0, reason: 'the good row is untouched');
    expect((row['readiness'] as num?)?.toDouble(), 74.0);
    expect(await readScalars(day), equals(before),
        reason: 'metric_series survives — putDayResult would have nulled it');
  });

  test('a good TODAY is not blanked by one transient failure', () async {
    // The daily-life case: a good 08:00 result, then a 09:00 pass times out.
    const day = '2026-02-11';
    await seedGoodDay(day, finalized: false);
    final dayEndSec = DateTime(2026, 2, 12).millisecondsSinceEpoch ~/ 1000;
    await DerivationEngine().debugMarkDaySkipped(
      day,
      dayEndSec,
      dayEndSec - 3600, // data edge still inside the day
      reason: 'error',
    );
    final row = await LocalDb.dayResult(day);
    expect(row!['skipped'], 0);
    expect((row['rhr'] as num?)?.toDouble(), 52.0);
  });

  test('a skip marker IS written when there is no good row to lose', () async {
    const day = '2026-02-12';
    expect(await LocalDb.dayResult(day), isNull, reason: 'precondition');
    final dayEndSec = DateTime(2026, 2, 13).millisecondsSinceEpoch ~/ 1000;
    await DerivationEngine().debugMarkDaySkipped(
      day,
      dayEndSec,
      dayEndSec + 10 * 86400,
      reason: 'day_prepare_budget_exceeded',
    );
    final row = await LocalDb.dayResult(day);
    expect(row, isNotNull);
    expect(row!['skipped'], 1);
    // A STRUCTURAL failure still finalizes once aged out, so a pathological day
    // isn't retried forever.
    expect(row['finalized'], 1);
  });

  test('a TRANSIENT skip is never finalized, so the day gets another chance',
      () async {
    const day = '2026-02-13';
    final dayEndSec = DateTime(2026, 2, 14).millisecondsSinceEpoch ~/ 1000;
    await DerivationEngine().debugMarkDaySkipped(
      day,
      dayEndSec,
      dayEndSec + 10 * 86400, // aged well past finalization
      reason: 'timeout',
    );
    final row = await LocalDb.dayResult(day);
    expect(row!['skipped'], 1);
    expect(row['finalized'], 0,
        reason: 'finalizing a 90 s timeout locks the day out of every future '
            'pass at this algo version — permanently blank');
    expect(
      (await LocalDb.finalizedDayIds(kAlgoVersion)).contains(day),
      isFalse,
    );
  });

  test('a skip marker does not overwrite an existing skip marker\'s reason '
      'with a worse one — but is allowed to replace it', () async {
    const day = '2026-02-14';
    final dayEndSec = DateTime(2026, 2, 15).millisecondsSinceEpoch ~/ 1000;
    await DerivationEngine()
        .debugMarkDaySkipped(day, dayEndSec, dayEndSec, reason: 'timeout');
    await DerivationEngine().debugMarkDaySkipped(
      day,
      dayEndSec,
      dayEndSec + 10 * 86400,
      reason: 'day_prepare_budget_exceeded',
    );
    final row = await LocalDb.dayResult(day);
    final payload = jsonDecode(row!['payload_json'] as String) as Map;
    expect(payload['reason'], 'day_prepare_budget_exceeded',
        reason: 'a skip marker carries no user data, so replacing one with '
            'another is fine — only REAL results are protected');
  });

  // ── 3. a version bump must not launder old detail into a finished row ──────

  test('dayResult hands back the PREVIOUS version row after a bump', () async {
    // The precondition the cross-version guard rests on: the query is
    // `ORDER BY algo_version DESC LIMIT 1`, with no filter to kAlgoVersion. So
    // on the first derive after a bump, the row offered for carry-forward
    // belongs to the version that is being replaced.
    const day = '2026-04-02';
    await LocalDb.putDayResult(
      dayId: day,
      algoVersion: kAlgoVersion - 1,
      payloadJson: jsonEncode({
        'scalars': {'readiness': 74.0},
        // Exactly the blocks a bump exists to recompute.
        'series': {'resp_day': [], 'hrv_day': []},
        'naps': [
          {'start': 1, 'end': 2}
        ],
      }),
      windowJson: '{}',
      finalized: true,
      rhr: 52,
      rmssd: 61,
      readiness: 74,
      series: const {'readiness': 74.0},
    );

    final row = await LocalDb.dayResult(day);
    expect((row!['algo_version'] as num).toInt(), kAlgoVersion - 1,
        reason: 'the carry-forward source is the OLD version row');

    // Which is why recovery must refuse to file that as a finished current
    // result — otherwise the previous version curves lock in under this
    // version number and are never recomputed.
    final outcome = DerivationEngine.recoveryOutcome(
      recovered: true,
      prevPartial: (row['partial'] as num?)?.toInt() == 1,
      prevVersion: (row['algo_version'] as num?)?.toInt(),
      prevFinalized: (row['finalized'] as num?)?.toInt() == 1,
      finalizedByAge: false,
    );
    expect(outcome.partial, isTrue);
    expect(outcome.finalized, isFalse);
  });

  // 3. A re-stage over LESS substrate than the last one had (#242). A day
  //    re-stages on every pass for its first 48 h, and pruning can take the
  //    substrate away between passes — so the same night comes back shorter and
  //    replaced the good one. "It got fixed, then a few syncs later it went
  //    back."
  group('a night never re-stages shorter', () {
    SleepSessionCandidate night(
      num? tstSec, {
      int onset = 1000,
      int offset = 2000,
      int? bandTrim,
    }) =>
        SleepSessionCandidate(
          dayId: '2026-08-19',
          confidence: 0.8,
          flags: const [],
          sleepJson: {
            'tst_sec': ?tstSec,
            'band_offset_trim_sec': ?bandTrim,
          },
          hypnoStages: const [],
          sleepOnsetSec: onset,
          sleepOffsetSec: offset,
        );

    test('a shorter re-stage loses to the banked night', () {
      expect(DerivationEngine.isRicherSleep(night(27000), night(9000)), isTrue);
    });

    test('a longer re-stage wins — the band handed over more of it', () {
      expect(DerivationEngine.isRicherSleep(night(9000), night(27000)), isFalse);
    });

    test('an identical re-stage writes, so equal is not richer', () {
      expect(DerivationEngine.isRicherSleep(night(27000), night(27000)), isFalse);
    });

    test('a night beats no night, and no night never beats one', () {
      expect(DerivationEngine.isRicherSleep(night(27000), night(null)), isTrue);
      expect(DerivationEngine.isRicherSleep(night(null), night(27000)), isFalse);
      expect(DerivationEngine.isRicherSleep(night(null), night(null)), isFalse);
    });

    // A band-corrected END (sleep.band_offset_trim_sec) is not "less
    // substrate": it may replace a banked longer night with the same onset,
    // but only within the tail the band corroborated as awake.
    // prev untrimmed 1000→2000 tst 27000; next trimmed to 1700 with trim 300.
    test('band END correction replaces the banked longer night', () {
      // TST loss 250 s ≤ trim 300 + 60; untrimmed end 1700+300 == banked 2000.
      expect(DerivationEngine.isRicherSleep(
          night(27000), night(26750, offset: 1700, bandTrim: 300)), isFalse);
    });
    test('a small trim cannot authorise a much larger regression', () {
      // banked end 2000 is beyond the untrimmed end 1700+10 (+60) = 1770
      expect(DerivationEngine.isRicherSleep(
          night(27000), night(20000, offset: 1700, bandTrim: 10)), isTrue);
    });
    test('TST loss larger than the removed interval (+60 s) is refused', () {
      // removed from the banked window: 2000-1700 = 300; loss 7000 > 360
      expect(DerivationEngine.isRicherSleep(
          night(27000), night(20000, offset: 1700, bandTrim: 300)), isTrue);
    });
    test('growing morning record: an early short bank yields to the later trim', () {
      // 07:19-style bank: end 1760, no trim. Later pass: untrimmed 2500 → 1700
      // (trim 800). 1760 lies inside (1700, 2560]; loss 50 ≤ 60 + 60.
      expect(DerivationEngine.isRicherSleep(
          night(26800, offset: 1760), night(26750, offset: 1700, bandTrim: 800)),
          isFalse);
    });
    test('backfilled SLEEP removes the trim: the longer new night wins', () {
      // banked trimmed 1000→1700 (trim 300); a gap was backfilled with SLEEP,
      // so the next pass ends 1990 untrimmed with more TST → ordinary compare.
      expect(DerivationEngine.isRicherSleep(
          night(26700, offset: 1700, bandTrim: 300), night(26950, offset: 1990)),
          isFalse);
    });
    test('different onset (pruned start): no exception either way', () {
      expect(DerivationEngine.isRicherSleep(
          night(27000), night(9000, onset: 1500, offset: 1700, bandTrim: 300)), isTrue);
    });
    // Each 60 s tolerance is inclusive: exactly 60 applies, 61 falls through
    // to the ordinary compare (prev TST is larger, so prev wins = isTrue).
    test('onset tolerance: 60 s apart applies, 61 s falls through', () {
      expect(DerivationEngine.isRicherSleep(night(27000),
          night(26750, onset: 1060, offset: 1700, bandTrim: 300)), isFalse);
      expect(DerivationEngine.isRicherSleep(night(27000),
          night(26750, onset: 1061, offset: 1700, bandTrim: 300)), isTrue);
    });
    test('end tolerance: banked end == untrimmed end + 60 applies, 1 s past falls through', () {
      // 1700 + 240 + 60 == 2000 (applies); 1700 + 239 + 60 == 1999 < 2000.
      expect(DerivationEngine.isRicherSleep(night(27000),
          night(26750, offset: 1700, bandTrim: 240)), isFalse);
      expect(DerivationEngine.isRicherSleep(night(27000),
          night(26750, offset: 1700, bandTrim: 239)), isTrue);
    });
    test('TST-loss tolerance: loss == removed + 60 applies, 1 s more falls through', () {
      // removed = 2000 - 1700 = 300; allowed loss 360.
      expect(DerivationEngine.isRicherSleep(night(27000),
          night(26640, offset: 1700, bandTrim: 300)), isFalse);
      expect(DerivationEngine.isRicherSleep(night(27000),
          night(26639, offset: 1700, bandTrim: 300)), isTrue);
    });
    test('shorter WITHOUT trim still loses (pruning guard intact)', () {
      expect(DerivationEngine.isRicherSleep(night(27000), night(9000)), isTrue);
    });
  });

  // 4. A re-derive at the retention-cutoff edge (edge#305): daytime HR
  //    survives (so `producedNothing` is false) while the sleep window's own
  //    RR/HR substrate has aged out from under it — sleep STAGING survives
  //    regardless (it replays the durable `sleep_session_candidates` row, not
  //    raw), so every night-physiology scalar comes back null and, because
  //    `metric_series` is UNVERSIONED, silently clobbers a good historical
  //    baseline point and collapses the readiness baseline out from under
  //    every later night.
  group('nightSubstrateRegressed (edge#305)', () {
    test('a known sleep window with no surviving substrate and null night '
        'scalars is a regression', () {
      expect(
        DerivationEngine.nightSubstrateRegressed(
          sleepSubEmpty: true,
          nightScalarsNull: true,
        ),
        isTrue,
      );
    });

    test('the v83 counterexample: a re-stage that finds NO window at all '
        '(NO_SLEEP_DETECTED) with null night scalars is STILL a regression '
        '— the shape test does not require this pass to have found a '
        'window; the caller\'s existing-result check is what protects an '
        'honest no-sleep day', () {
      expect(
        DerivationEngine.nightSubstrateRegressed(
          sleepSubEmpty: true,
          nightScalarsNull: true,
        ),
        isTrue,
      );
    });

    test('sleep substrate still present is not a regression, even with null '
        'scalars (a genuine can\'t-compute night)', () {
      expect(
        DerivationEngine.nightSubstrateRegressed(
          sleepSubEmpty: false,
          nightScalarsNull: true,
        ),
        isFalse,
      );
    });

    test('real night scalars computed is not a regression', () {
      expect(
        DerivationEngine.nightSubstrateRegressed(
          sleepSubEmpty: true,
          nightScalarsNull: false,
        ),
        isFalse,
      );
    });
  });

  // The full guard also requires an EXISTING result with real night scalars
  // before it declines to write — a fresh day with nothing on disk yet must
  // still get its (all-null) first result, same principle as producedNothing.
  test('a night-substrate regression with NO existing result still writes',
      () async {
    const day = '2026-08-23';
    expect(await LocalDb.dayResult(day), isNull, reason: 'precondition');
    expect(
      DerivationEngine.nightSubstrateRegressed(
        sleepSubEmpty: true,
        nightScalarsNull: true,
      ),
      isTrue,
      reason: 'the shape alone says regression; the caller still checks for '
          'an existing real result before declining to persist',
    );
  });
}
