// The quiet-waking level through the REAL engine: decoded 1 Hz rows →
// DerivationEngine.run/runDays → day_result + metric_series.
//
// Strain is priced on the median of the PRIOR days' own `quiet_hrr`, read from
// one frozen snapshot per sweep. These pin what that means on disk: a first
// sync of a whole week must not leave the week blank, the persisted rows are
// replaced (not kept) when a re-derive abstains, a day needs 360 wake minutes
// to contribute a level, and the one-shot history seed runs even when there
// is nothing to derive.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/quiet_level_seed.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/series_codec.dart';

const _profile = Profile(
  ageYears: 35,
  sex: 'm',
  weightKg: 75,
  heightCm: 178,
  restingHrManual: 55,
);

int _localSec(String day, int hour) {
  final d = DateTime.parse(day);
  return DateTime(d.year, d.month, d.day, hour).millisecondsSinceEpoch ~/ 1000;
}

/// [wakeMin] minutes of daytime 1 Hz rows from 09:00 local: 45 min at 130 bpm,
/// the rest at ~62, with enough wrist motion to read as awake.
Future<void> _insertDay(String day, {int wakeMin = 400}) async {
  final db = await LocalDb.instance;
  final start = _localSec(day, 9);
  final batch = db.batch();
  for (var i = 0; i < wakeMin * 60; i++) {
    final ts = start + i;
    batch.insert('decoded_onehz', {
      'device_id': '',
      'ts_ms': ts * 1000,
      'rec_ts': ts,
      'counter': ts,
      'hr': i < 45 * 60 ? 130 : 62 + (i % 3) - 1,
      'ax': 0.05 * ((i % 60) / 60.0),
      'ay': 0.05 * ((i % 30) / 30.0),
      'az': 0.98,
      'device_family': 'gen4',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
  await batch.commit(noResult: true);
}

Future<void> _clear() async {
  final db = await LocalDb.instance;
  for (final t in const [
    'decoded_onehz',
    'day_result',
    'metric_series',
    'metric_series_version',
    'compute_freshness',
  ]) {
    await db.delete(t);
  }
  // The highest cutoff the raw prune has applied — carried across tests it
  // would mark later fixtures' nights as already cut.
  await db.delete('sync_cursor',
      where: 'name = ?', whereArgs: ['decoded_pruned_before']);
}

/// The stored `metric_series` row itself — `metricSeries` drops NULL values,
/// and a NULL row is exactly what an abstaining re-derive must leave.
Future<List<Map<String, Object?>>> _row(String day, String key) async {
  final db = await LocalDb.instance;
  return db.query('metric_series',
      where: 'date = ? AND key = ?', whereArgs: [day, key]);
}

/// Owed days right after a sweep: every day that can still reach three
/// levels ([mustOwe]) and, at most, the cold-start days before them. Those can
/// stay marked one pass longer — proving a day unreachable counts across two
/// reads, and an earlier day committing in between is counted on both sides,
/// the safe direction — and their next complete derive clears them.
Future<void> _expectOwedAfterSweep(
    List<String> days, Iterable<String> mustOwe) async {
  final owed = await _owed();
  expect(owed, containsAll(mustOwe));
  expect(owed.difference(mustOwe.toSet()),
      everyElement(isIn(days.sublist(1, 3))));
}

/// Days still owed a strain re-score (their durable markers).
Future<Set<String>> _owed() async => {
  for (final k in await LocalDb.computeFreshnessKeys(
      DerivationEngine.kQuietRepassKeyPrefix))
    k.substring(DerivationEngine.kQuietRepassKeyPrefix.length),
};

/// Decoded 1 Hz rows left on [day] (local calendar day).
Future<int> _decodedRows(String day) async {
  final db = await LocalDb.instance;
  final d = DateTime.parse(day);
  final start = _localSec(day, 0);
  // Next local midnight from the calendar, not +86400 (DST).
  final end = DateTime(d.year, d.month, d.day + 1).millisecondsSinceEpoch ~/ 1000;
  final rows = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM decoded_onehz WHERE rec_ts >= ? AND rec_ts < ?',
      [start, end]);
  return (rows.single['n'] as num).toInt();
}

Future<double?> _value(String day, String key) async {
  final rows = await _row(day, key);
  return rows.isEmpty ? null : (rows.single['value'] as num?)?.toDouble();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_quiet_level_engine_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('the seed runs even with an empty decoded ledger', () async {
    await _clear();
    // A restored install: bundles on disk, no 1 Hz rows, so run() returns at
    // "no decoded data" — after the seed, not before it.
    for (final day in const ['2026-02-01', '2026-02-02', '2026-02-03']) {
      await LocalDb.putDayResult(
        dayId: day,
        algoVersion: kAlgoVersion,
        payloadJson: SeriesCodec.encodePayloadJson(jsonEncode({
          'date': day,
          'max_hr_used': 183.5,
          'scalars': {'rhr_nocturnal': 55},
          'series': {
            'hr_curve': [
              for (var i = 0; i < 400; i++) {'t': i * 60, 'v': 62},
            ],
            'strain_curve': [
              for (var i = 0; i < 400; i++) {'t': i * 60, 'v': 0.0},
            ],
          },
        })),
        windowJson: '{}',
        finalized: true,
        source: 'band',
      );
    }
    expect(await DerivationEngine().run(_profile, heavy: true), 0);
    expect(await LocalDb.computeFreshness(kQuietHrrSeedKey), isNotNull);
    expect(await _value('2026-02-03', 'quiet_hrr'), closeTo(0.0545, 0.0005));
  });

  test('a seed that writes levels refreshes the rescan signature', () async {
    await _clear();
    // Every day finalized, nothing for a derive to do: the seed is the only
    // thing that moves the baseline, so it must move the gate too, or
    // rescanRecent never re-scores the days the new levels now price.
    for (final day in const ['2026-02-01', '2026-02-02', '2026-02-03']) {
      await LocalDb.putDayResult(
        dayId: day,
        algoVersion: kAlgoVersion,
        payloadJson: SeriesCodec.encodePayloadJson(jsonEncode({
          'date': day,
          'scalars': {'rhr_nocturnal': 55},
          'series': {
            'hr_curve': [
              for (var i = 0; i < 400; i++) {'t': i * 60, 'v': 62},
            ],
            'strain_curve': [
              for (var i = 0; i < 400; i++) {'t': i * 60, 'v': 0.0},
            ],
          },
        })),
        windowJson: '{}',
        finalized: true,
        source: 'band',
      );
    }
    final before = await debugBaselineSignature();
    await LocalDb.putBaseline(
        'rolling_artifact', jsonEncode({'signature': before}));
    await DerivationEngine().run(_profile, heavy: true);
    final after = await debugBaselineSignature();
    expect(after, isNot(before), reason: 'the seed moved the quiet levels');
    final stored = jsonDecode(
        (await LocalDb.baseline('rolling_artifact'))!['payload_json']
            as String) as Map;
    expect(stored['signature'], after);
  });

  // The tests below run real derives over 1 Hz rows — well past the default
  // 30 s once the suite is loaded, hence their explicit budgets.
  test('a first sync of a whole week does not leave it blank', () async {
    await _clear();
    const days = [
      '2026-03-01', '2026-03-02', '2026-03-03', '2026-03-04', //
      '2026-03-05', '2026-03-06', '2026-03-07',
    ];
    for (final d in days) {
      await _insertDay(d);
    }
    // ONE run, one frozen snapshot with no `quiet_hrr` in it at all.
    await DerivationEngine().run(_profile, heavy: true);

    for (final d in days) {
      expect(await _value(d, 'quiet_hrr'), isNotNull, reason: d);
    }
    // Days 1–3 have fewer than three prior levels: an honest cold start.
    for (final d in days.take(3)) {
      expect(await _value(d, 'strain'), isNull, reason: d);
    }
    // Day 4 on had three or more by the end of the sweep, and was re-scored
    // on them before its raw could be pruned — finalized or not, never blank.
    for (final d in days.skip(3)) {
      expect(await _value(d, 'strain'), isNotNull, reason: d);
      expect(await _value(d, 'trimp_net'), isNotNull, reason: d);
      final row = await LocalDb.dayResult(d);
      final scalars =
          (SeriesCodec.decodePayloadJson(row!['payload_json'])!['scalars']
              as Map);
      expect(scalars['strain'], isNotNull, reason: '$d bundle');
    }
    // Every day that could be scored was, and cleared its marker. Days 2–3
    // can never reach three levels; the next complete derive proves it and
    // releases them.
    await _expectOwedAfterSweep(days, const []);
    await DerivationEngine().run(_profile, heavy: true);
    expect(await _owed(), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 5)));

  // A failed second pass, or the app dying before it ran, must not cost the
  // days it owes: they stay unfinalized, their raw is held from the prune, and
  // the NEXT run — a fresh engine, a light pass — scores them.
  for (final (label, failAt) in const [
    ('a failed second pass', 'day'),
    ('the process dying between the passes', 'start'),
  ]) {
    test('$label leaves the owed days for the next run', () async {
      await _clear();
      const days = [
        '2026-06-01', '2026-06-02', '2026-06-03', '2026-06-04', //
        '2026-06-05', '2026-06-06', '2026-06-07',
      ];
      for (final d in days) {
        await _insertDay(d);
      }
      DerivationEngine.debugQuietRepassHook = (day) async {
        if ((day == null) == (failAt == 'start')) throw StateError('injected');
      };
      addTearDown(() => DerivationEngine.debugQuietRepassHook = null);
      await DerivationEngine().run(_profile, heavy: true);
      DerivationEngine.debugQuietRepassHook = null;

      final finalized = await LocalDb.finalizedDayIds(kAlgoVersion);
      await _expectOwedAfterSweep(days, days.skip(3));
      for (final d in days.skip(3)) {
        expect(await _value(d, 'strain'), isNull, reason: d);
        expect(finalized, isNot(contains(d)), reason: '$d is not locked');
      }
      // The prune ran and held every owed day's raw — day 4's included,
      // which is past the 3-day retention on its own.
      expect(await _decodedRows(days[3]), 400 * 60, reason: 'held whole');

      await DerivationEngine().run(_profile);
      for (final d in days.skip(3)) {
        expect(await _value(d, 'strain'), isNotNull, reason: d);
      }
      expect(await _owed(), everyElement(isIn(days.sublist(1, 3))));
      await DerivationEngine().run(_profile, heavy: true);
      expect(await _owed(), isEmpty);
    }, timeout: const Timeout(Duration(minutes: 5)));
  }

  test('persisted rows, replaced with NULL when the inputs go', () async {
    await _clear();
    for (var d = 1; d <= 7; d++) {
      await LocalDb.putMetricSeriesValue('2026-04-0$d', 'quiet_hrr', 0.20);
    }
    // Seeded already, so the run below does not try to backfill anything.
    await LocalDb.putComputeFreshness(kQuietHrrSeedKey, '{"done":true}');
    const day = '2026-04-10';
    await _insertDay(day);
    await DerivationEngine().runDays(_profile, {day});
    expect(await _value(day, 'quiet_hrr'), closeTo(0.0545, 0.002));
    expect(await _value(day, 'trimp_net'), greaterThan(0));
    expect(await _value(day, 'strain'), greaterThan(0));

    // No resting HR of any kind now: no reserve, so no level, no net load,
    // no strain — and the rows a previous derive wrote must not survive it.
    await DerivationEngine().runDays(
        const Profile(ageYears: 35, sex: 'm', weightKg: 75, heightCm: 178),
        {day});
    for (final key in const ['quiet_hrr', 'trimp_net', 'strain']) {
      final rows = await _row(day, key);
      expect(rows, hasLength(1), reason: '$key row is written');
      expect(rows.single['value'], isNull, reason: '$key is erased');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('360 wake minutes contribute a level, 359 do not', () async {
    await _clear();
    for (var d = 1; d <= 7; d++) {
      await LocalDb.putMetricSeriesValue('2026-05-0$d', 'quiet_hrr', 0.20);
    }
    await LocalDb.putComputeFreshness(kQuietHrrSeedKey, '{"done":true}');
    await _insertDay('2026-05-10', wakeMin: 359);
    await _insertDay('2026-05-11', wakeMin: 360);
    await DerivationEngine().runDays(_profile, {'2026-05-10', '2026-05-11'});

    // Guard: the wake series really is that long (no minute carved off).
    for (final (day, n) in const [('2026-05-10', 359), ('2026-05-11', 360)]) {
      final row = await LocalDb.dayResult(day);
      final series = SeriesCodec.decodePayloadJson(row!['payload_json'])![
          'series'] as Map;
      expect((series['strain_curve'] as List).length, n, reason: day);
    }
    expect(await _value('2026-05-10', 'quiet_hrr'), isNull);
    // …and still scored, on the prior days' level.
    expect(await _value('2026-05-10', 'strain'), greaterThan(0));
    expect(await _value('2026-05-11', 'quiet_hrr'), closeTo(0.0545, 0.002));
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a second-half timeout on the re-score keeps the day owed', () async {
    // The re-score's pipeline half DOES produce strain once the level exists;
    // its second half (the only producer of `trimp_net`) times out, and the
    // first pass's same-version row is carried forward. Strain present is not
    // proof the day was scored: the marker stays, the day stays unlocked with
    // its raw, and a later COMPLETE derive writes the net load.
    //
    // The first pass's second half times out too, so the row carried forward
    // is that pass's own headline-only row — the recovery the engine can
    // perform today. (Carrying a COMPLETE row's curves into a fresh pipeline
    // bundle currently throws before anything is written, which keeps the
    // marker by accident; it is not what this test is about.)
    await _clear();
    const days = [
      '2026-07-01', '2026-07-02', '2026-07-03', '2026-07-04', //
      '2026-07-05', '2026-07-06', '2026-07-07',
    ];
    for (final d in days) {
      await _insertDay(d);
    }
    final target = days[3];
    var calls = 0;
    DerivationEngine.debugSecondHalfHook = (day) async {
      // Both the first pass and the re-score time out on the second half.
      if (day == target && ++calls <= 2) {
        throw TimeoutException('injected second-half timeout');
      }
    };
    addTearDown(() => DerivationEngine.debugSecondHalfHook = null);
    await DerivationEngine().run(_profile, heavy: true);
    DerivationEngine.debugSecondHalfHook = null;
    expect(calls, 2, reason: 'the re-score reached the second half');

    expect(await _value(target, 'strain'), isNull,
        reason: 'a headline-only row never writes its series');
    final row = await LocalDb.dayResult(target);
    expect(
        (SeriesCodec.decodePayloadJson(row!['payload_json'])!['scalars']
            as Map)['strain'],
        isNotNull,
        reason: 'the re-score\'s pipeline half did score it');
    expect(await _owed(), contains(target));
    expect(await LocalDb.finalizedDayIds(kAlgoVersion), isNot(contains(target)));
    expect(await _value(target, 'trimp_net'), isNull);
    expect(await _decodedRows(target), 400 * 60, reason: 'held whole');

    // Restart: a fresh engine's light pass completes it.
    await DerivationEngine().run(_profile);
    expect(await _value(target, 'trimp_net'), isNotNull);
    expect(await _value(target, 'strain'), isNotNull);
    expect(await _owed(), isNot(contains(target)));
  }, timeout: const Timeout(Duration(minutes: 5)));

  // The race the old counting rule lost: it read the stored levels, then the
  // derived days, and a third earlier day committing its level AND its row
  // between those reads was counted by neither. The rule now asks only
  // whether ANY earlier day exists — as unfinalized raw, or as a stored
  // level — and a day's level lands in the same transaction as its row, so
  // every point of that interleaving answers "owed".
  test('owed holds at every point of a concurrent earlier commit', () async {
    await _clear();
    final engine = DerivationEngine();
    const days = ['2026-08-01', '2026-08-02', '2026-08-03', '2026-08-04'];
    final blocked = <String, dynamic>{
      'scalars': {'strain': null},
      'absent_notes': {'strain': 'need_baseline:have=2,need=3'},
    };
    Future<void> raw(String d) async {
      final db = await LocalDb.instance;
      final t = _localSec(d, 9);
      await db.insert('decoded_onehz', {
        'device_id': '',
        'ts_ms': t * 1000,
        'rec_ts': t,
        'counter': t,
        'hr': 62,
        'ax': 0.0,
        'ay': 0.0,
        'az': 1.0,
        'device_family': 'gen4',
      });
    }

    Future<void> commit(String d) => LocalDb.putDayResult(
          dayId: d,
          algoVersion: kAlgoVersion,
          payloadJson: '{"date":"$d"}',
          windowJson: '{}',
          finalized: true,
          source: 'band',
          series: {'quiet_hrr': 0.2},
        );

    for (final d in days) {
      await raw(d);
    }
    // Nothing earlier committed yet / two of three / all three committed.
    expect(await engine.debugQuietRepassOwed(days[3], blocked), isTrue);
    await commit(days[0]);
    await commit(days[1]);
    expect(await engine.debugQuietRepassOwed(days[3], blocked), isTrue);
    await commit(days[2]);
    expect(await engine.debugQuietRepassOwed(days[3], blocked), isTrue);
    // The interleaving itself: every earlier day finalized, so the raw read
    // finds nothing pending — then an earlier day commits its level and its
    // row before the level read. It is seen.
    await _clear();
    await raw(days[2]);
    await LocalDb.putDayResult(
      dayId: days[2],
      algoVersion: kAlgoVersion,
      payloadJson: '{"date":"${days[2]}"}',
      windowJson: '{}',
      finalized: true,
      source: 'band',
    );
    DerivationEngine.debugQuietBetweenReads = () => commit(days[2]);
    addTearDown(() => DerivationEngine.debugQuietBetweenReads = null);
    expect(await engine.debugQuietRepassOwed(days[3], blocked), isTrue);
    DerivationEngine.debugQuietBetweenReads = null;

    // Even with every earlier raw day gone, a stored level still counts.
    final db = await LocalDb.instance;
    await db.delete('decoded_onehz');
    expect(await engine.debugQuietRepassOwed(days[3], blocked), isTrue);

    // Never owed: the first day (nothing before it), or a strain that is
    // present or absent for another reason.
    await raw(days[0]);
    expect(await engine.debugQuietRepassOwed('2026-07-31', blocked), isFalse);
    expect(
        await engine.debugQuietRepassOwed(days[3], {
          'scalars': {'strain': 8.0},
        }),
        isFalse);
    expect(
        await engine.debugQuietRepassOwed(days[3], {
          'scalars': {'strain': null},
          'absent_notes': {'strain': 'need_input:resting_hr'},
        }),
        isFalse);
  });

  test('an owed day whose night the prune already cut is retired, not re-scored',
      () async {
    // Only the 14-day hold floor can cut into an owed day's night. Re-deriving
    // it then would replace a full-night result with a truncated one — the
    // case the rescan refuses — so its abstention becomes final instead.
    await _clear();
    const days = [
      '2026-09-01', '2026-09-02', '2026-09-03', '2026-09-04', //
      '2026-09-05', '2026-09-06', '2026-09-07',
    ];
    for (final d in days) {
      await _insertDay(d);
    }
    // Leave days 4–7 owed: no second pass ran.
    DerivationEngine.debugQuietRepassHook = (day) async {
      if (day == null) throw StateError('injected');
    };
    addTearDown(() => DerivationEngine.debugQuietRepassHook = null);
    await DerivationEngine().run(_profile, heavy: true);
    DerivationEngine.debugQuietRepassHook = null;
    await _expectOwedAfterSweep(days, days.skip(3));

    // As if the floor had cut at day 5's midnight: days 2–5's nights (from
    // the previous noon) are truncated, days 6–7's are whole.
    await LocalDb.setCursor(
        'decoded_pruned_before', '${_localSec(days[4], 0)}');
    await DerivationEngine().run(_profile);
    expect(await _owed(), isEmpty);
    for (final d in days.sublist(1, 5)) {
      expect(await _value(d, 'strain'), isNull, reason: '$d not re-scored');
    }
    for (final d in days.skip(5)) {
      expect(await _value(d, 'strain'), isNotNull, reason: d);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  // Clearing a marker on "can never reach three" COUNTS, so its reads must be
  // ordered against a concurrent commit: the derived set first, then the
  // levels. Read the other way round, an earlier day committing its level and
  // its row in between is seen by neither, and a day still owed a score is
  // "proven" unreachable and finalized blank.
  test('unreachable is never proven across a concurrent earlier commit',
      () async {
    await _clear();
    final engine = DerivationEngine();
    const days = ['2026-10-01', '2026-10-02', '2026-10-03', '2026-10-04'];
    Future<void> raw(String d) async {
      final db = await LocalDb.instance;
      final t = _localSec(d, 9);
      await db.insert('decoded_onehz', {
        'device_id': '',
        'ts_ms': t * 1000,
        'rec_ts': t,
        'counter': t,
        'hr': 62,
        'ax': 0.0,
        'ay': 0.0,
        'az': 1.0,
        'device_family': 'gen4',
      });
    }

    Future<void> commit(String d) => LocalDb.putDayResult(
          dayId: d,
          algoVersion: kAlgoVersion,
          payloadJson: '{"date":"$d","scalars":{"rhr":55}}',
          windowJson: '{}',
          finalized: true,
          source: 'band',
          rhr: 55,
          series: {'quiet_hrr': 0.2},
        );

    for (final d in days) {
      await raw(d);
    }
    await commit(days[0]);
    await commit(days[1]);
    // Two levels in hand and a third day still deriving: reachable.
    expect(await engine.debugQuietLevelUnreachable(days[3]), isFalse);
    // …and still reachable when that third day commits between the reads.
    DerivationEngine.debugQuietBetweenReads = () => commit(days[2]);
    addTearDown(() => DerivationEngine.debugQuietBetweenReads = null);
    expect(await engine.debugQuietLevelUnreachable(days[3]), isFalse);
    DerivationEngine.debugQuietBetweenReads = null;

    // Proven only when nothing in hand can lift it: day 2 has one level
    // before it and no earlier day still pending.
    expect(await engine.debugQuietLevelUnreachable(days[1]), isTrue);
    // Day 3: two levels before it, nothing earlier still pending.
    expect(await engine.debugQuietLevelUnreachable(days[2]), isTrue);
  });

  test('a cold start\'s days 2–3 are released: they can never be scored',
      () async {
    await _clear();
    const days = ['2026-11-01', '2026-11-02', '2026-11-03'];
    for (final d in days) {
      await _insertDay(d);
    }
    await DerivationEngine().run(_profile, heavy: true);
    await _expectOwedAfterSweep(days, const []);
    await DerivationEngine().run(_profile, heavy: true);
    expect(await _owed(), isEmpty);
    for (final d in days) {
      expect(await _value(d, 'strain'), isNull, reason: d);
      expect(await _value(d, 'quiet_hrr'), isNotNull, reason: d);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
