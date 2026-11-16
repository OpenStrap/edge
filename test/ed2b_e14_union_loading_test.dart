@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/derive_prepare.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/ed2a_recalc_fixture.dart';

String _payload(PreparedDerivationDay day) => jsonEncode({
  'prepared': day.toJson(), 'bundle': edBundle(day)});

Future<void> _night() async {
  final start = DateTime(2020, 1, 1, 22).millisecondsSinceEpoch ~/ 1000;
  await edRows(start, start + 10 * 3600, hr: 55, az: 1);
  await edRows(edStart, edStart + 1200, hr: 85);
  final batch = (await LocalDb.instance).batch();
  // Multiple beats, beat-only seconds and backwards raw placements straddle
  // every revision bucket; worker cuts must restart the running maximum.
  for (var t = start; t < start + 10 * 3600; t += 17) {
    for (var i = 0; i < 2; i++) {
      batch.insert('decoded_rr', {'device_id': '', 'ts_ms': t * 1000,
        'rec_ts': t, 'rr_ts_ms': t * 1000, 'beat_index': i,
        'beat_ts_ms': t * 1000 - (t % 11 == 0 ? 9000 : i * 400),
        'rr_ms': 900 + t % 90}, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }
  await batch.commit(noResult: true);
}

DerivationEngine _cold() => DerivationEngine()
  ..debugDisableUnionLoads = true
  ..debugDisableSubstrateRetention = true
  ..debugDisableStagedSleepCache = true;

void main() {
  setUpAll(edInit);
  setUp(() async { await edFresh('ed2b_e14.db'); await _night(); });
  tearDown(edDrop);

  test('E14 search, calendar, nap and night come from one union load with worker cuts', () async {
    final loads = <(int, int, String)>[];
    final e = DerivationEngine()..debugDisableSubstrateRetention = true
      ..debugOnSubstrateLoad = (a, b, label) => loads.add((a, b, label));
    final day = await e.debugPrepareDay(edDay);
    expect(day, isNotNull);
    expect(day!.sleepSub.isEmpty, isFalse, reason: 'fixture must reach the staged-night cut');
    final cold = await _cold().debugPrepareDay(edDay);
    expect(_payload(day), _payload(cold!));
    expect(loads.length, 1,
        reason: 'overlapping search/day/night rows must be loaded once as a union');
    expect(e.debugUnionWorkerCuts, greaterThanOrEqualTo(3),
        reason: 'UI transfers encoded substrate; workers cut all requested windows');
  });

  test('E14 neighbouring days borrow overlap rather than loading it twice', () async {
    final next = DateTime(2020, 1, 3, 5).millisecondsSinceEpoch ~/ 1000;
    await edRows(next, next + 1200, hr: 57);
    final e = DerivationEngine();
    await e.debugPrepareDay(edDay);
    final before = e.snapshot()['raw_rows'] as int;
    final warm = await e.debugPrepareDay('2020-01-03');
    final cold = await _cold().debugPrepareDay('2020-01-03');
    expect(_payload(warm!), _payload(cold!));
    final reread = (e.snapshot()['raw_rows'] as int) - before;
    final coldEngine = _cold();
    await coldEngine.debugPrepareDay('2020-01-03');
    expect(reread, lessThan(coldEngine.snapshot()['raw_rows'] as int),
        reason: 'neighbour union must retain its earlier shared hours');
  });

  final changes = <String, Future<void> Function(DerivationEngine)>{
    'input revision': (_) => edRows(edStart, edStart + 1, hr: 91),
    'late RR': (_) async {
      await (await LocalDb.instance).insert('decoded_rr', {'device_id': '',
        'ts_ms': edStart * 1000, 'rec_ts': edStart, 'rr_ts_ms': edStart * 1000,
        'beat_index': 0, 'rr_ms': 850}, conflictAlgorithm: ConflictAlgorithm.replace);
    },
    'generation': (_) async { await LocalDb.close(); await LocalDb.instance; },
    'algorithm': (e) async { e.debugRekeyUnionAlgorithm(kAlgoVersion - 1); },
  };
  for (final change in changes.entries) {
    test('E14 ${change.key}: refuse stale union, cold bytes exact, then reuse worker cuts', () async {
      final e = DerivationEngine()..debugDisableStagedSleepCache = true;
      await e.debugPrepareDay(edDay);
      final before = e.snapshot()['raw_rows'] as int;
      await change.value(e);
      final warm = await e.debugPrepareDay(edDay);
      final cold = await _cold().debugPrepareDay(edDay);
      expect(_payload(warm!), _payload(cold!));
      final refreshed = e.snapshot()['raw_rows'] as int;
      expect(refreshed, greaterThan(before),
          reason: 'changed provenance must reload rather than hit a stale union');
      final cuts = e.debugUnionWorkerCuts;
      await e.debugPrepareDay(edDay);
      expect(e.snapshot()['raw_rows'], refreshed,
          reason: 'unchanged replacement provenance must reuse the refreshed union');
      expect(e.debugUnionWorkerCuts, greaterThan(cuts),
          reason: 'valid refreshed union supplies worker cuts after invalidation');
    });
  }

  test('E14 D35 endpoint: union cuts agree with a separately owned single second', () async {
    final db = await LocalDb.instance;
    final e = DerivationEngine();
    final range = e.debugTargetDayWindow(edDay);
    final end = range.$2;
    await edRows(end, end + 1, hr: 61);
    await edRows(end, end + 1, hr: 199, id: 'non-owner');
    await db.insert('device_coverage', {'device_id': '', 'signal': 'hr1Hz',
      'start_ts': range.$1, 'end_ts': end + 1});
    final day = await e.debugPrepareDay(edDay);
    expect(day!.daySub.hr.last, 61);
    final last = await DerivationEngine().debugLoadOwnedSubstrate(end, end, day: edDay);
    expect(last.hr, [61], reason: 'D35 is a prerequisite for exact union cuts');
    expect(last.hr, day.daySub.slice(end, end + 1).hr);
  });

  test('E14 disabled union diagnostic is behavior-neutral (guard)', () async {
    final ordinary = await DerivationEngine().debugPrepareDay(edDay);
    final disabled = await _cold().debugPrepareDay(edDay);
    expect(_payload(ordinary!), _payload(disabled!));
  });
}
