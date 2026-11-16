@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/coverage_resolver.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/data/db.dart';

import 'support/ed2a_recalc_fixture.dart';

int _reads(DerivationEngine e) => e.snapshot()['raw_rows'] as int;
final _lo = (edStart ~/ 900) * 900;
final _hi = _lo + 5 * 900 - 1;
Future<Substrate> _load(DerivationEngine e, {int? lo, int? hi,
    Map<InputSignal, List<OwnedSpan>> ownership = const {}}) =>
    e.debugLoadSubstrate(lo ?? _lo, hi ?? _hi, day: edDay, ownership: ownership);

void main() {
  final originalZone = Platform.environment["TZ"] ?? "UTC";
  setUpAll(edInit);
  setUp(() async {
    await edFresh('ed2a_e13.db');
    await edRows(_lo, _lo + 4 * 900 + 200);
  });
  tearDown(() async { edSetZone(originalZone); await edDrop(); });

  test('unchanged load reuses retained arrays without rereading rows', () async {
    final e = DerivationEngine();
    final first = await _load(e);
    final reads = _reads(e);
    expect(reads, greaterThan(0));
    final next = await _load(e);
    expect(jsonEncode(next.toJson()), jsonEncode(first.toJson()));
    expect(_reads(e), reads, reason: 'unchanged load must not decode rows twice');
  });

  test('append rereads at most the open revision bucket and new tail', () async {
    final e = DerivationEngine();
    await _load(e);
    final reads = _reads(e);
    await edRows(_lo + 4 * 900 + 200, _hi + 1);
    final warm = await _load(e);
    final cold = await _load(DerivationEngine()..debugDisableSubstrateRetention = true);
    expect(jsonEncode(warm.toJson()), jsonEncode(cold.toJson()));
    expect(_reads(e) - reads, lessThanOrEqualTo(900),
        reason: 'four closed buckets must survive the tail append');
  });

  final changes = <String, Future<void> Function()>{
    'identical old-bucket revision': () => edRows(_lo + 30, _lo + 31),
    'old-bucket replacement': () => edRows(_lo + 30, _lo + 31, hr: 83),
    'delete seconds and beats': () async {
      final db = await LocalDb.instance;
      for (final table in ['decoded_onehz', 'decoded_rr']) {
        await db.delete(table, where: 'rec_ts >= ? AND rec_ts < ?',
            whereArgs: [_lo + 10, _lo + 20]);
      }
    },
    'late beat in retained bucket': () async {
      await (await LocalDb.instance).insert('decoded_rr', {'device_id': '',
        'ts_ms': (_lo + 30) * 1000, 'rec_ts': _lo + 30,
        'rr_ts_ms': (_lo + 30) * 1000, 'beat_index': 0, 'rr_ms': 850});
    },
    'zone': () async { edSetZone('Pacific/Auckland'); },
    'generation': () async { await LocalDb.close(); await LocalDb.instance; },
    'family': () async { await (await LocalDb.instance).update(
        'decoded_onehz', {'device_family': 'gen5'},
        where: 'rec_ts = ?', whereArgs: [_lo + 30]); },
    'device provenance': () => edRows(_lo + 30, _lo + 31, id: 'second'),
    'skin unit bucket': () async { await (await LocalDb.instance).update(
        'decoded_onehz', {'skin_temp_c': 33.1},
        where: 'rec_ts = ?', whereArgs: [_lo + 30]); },
  };
  for (final change in changes.entries) {
    test('${change.key}: invalidate, preserve every byte, then retain again', () async {
      final e = DerivationEngine();
      await _load(e);
      final reads = _reads(e);
      await change.value();
      final warm = await _load(e);
      expect(_reads(e), greaterThan(reads), reason: 'closed prefix must be reloaded');
      final cold = await _load(DerivationEngine()..debugDisableSubstrateRetention = true);
      expect(jsonEncode(warm.toJson()), jsonEncode(cold.toJson()));
      final afterReload = _reads(e);
      await _load(e);
      expect(_reads(e), afterReload, reason: 'newly retained key must hit');
    });
  }

  test('algorithm rekey rejects retained work and next load hits', () async {
    final e = DerivationEngine();
    await _load(e);
    final reads = _reads(e);
    e.debugRetainedSubstrateRekey(kAlgoVersion - 1);
    final warm = await _load(e);
    expect(_reads(e), greaterThan(reads));
    expect(jsonEncode(warm.toJson()), jsonEncode((await _load(DerivationEngine())).toJson()));
    final after = _reads(e);
    await _load(e);
    expect(_reads(e), after, reason: 'current-version retention should now hit');
  });

  for (final signal in [InputSignal.hr1Hz, InputSignal.rrIntervals]) {
    test('$signal ownership miss even if revisions are unchanged', () async {
      final e = DerivationEngine();
      await _load(e);
      final reads = _reads(e);
      final ownership = <InputSignal, List<OwnedSpan>>{signal: [
        (start: _lo, end: _hi, deviceId: 'other')]};
      final warm = await _load(e, ownership: ownership);
      final cold = await _load(DerivationEngine(), ownership: ownership);
      expect(jsonEncode(warm.toJson()), jsonEncode(cold.toJson()));
      expect(_reads(e), greaterThan(reads));
      final again = _reads(e);
      await _load(e, ownership: ownership);
      expect(_reads(e), again, reason: 'ownership belongs to the retained key');
    });
  }

  for (final window in ['from', 'to']) {
    test('$window window change reloads then hits', () async {
      final e = DerivationEngine();
      await _load(e);
      final reads = _reads(e);
      final lo = window == 'from' ? _lo + 1 : _lo;
      final hi = window == 'to' ? _hi - 1 : _hi;
      final warm = await _load(e, lo: lo, hi: hi);
      final cold = await _load(DerivationEngine(), lo: lo, hi: hi);
      expect(jsonEncode(warm.toJson()), jsonEncode(cold.toJson()));
      expect(_reads(e), greaterThan(reads));
      final after = _reads(e);
      await _load(e, lo: lo, hi: hi);
      expect(_reads(e), after);
    });
  }

  test('raw beat times, per-second beat offsets and bucket metadata survive retention', () async {
    final db = await LocalDb.instance;
    final rawTimes = <double>[];
    final intervals = <double>[];
    final starts = <int>[];
    final b = db.batch();
    b.delete('decoded_onehz', where: 'rec_ts = ?', whereArgs: [_lo + 1]);
    // Include beat-only seconds, missing beats, multiple beats and a backward
    // raw timestamp at the cut. Monotonizing a retained prefix twice loses it.
    for (var t = _lo; t < _lo + 4 * 900 + 200; t++) {
      starts.add(rawTimes.length);
      for (var i = 0; i < (t % 3 == 0 ? 0 : 1 + t % 2); i++) {
        final raw = t * 1000 - (i == 0 && t % 11 == 0 ? 1500 : i * 400);
        rawTimes.add(raw.toDouble());
        intervals.add((700 + t % 90).toDouble());
        b.insert('decoded_rr', {'device_id': '', 'ts_ms': t * 1000,
          'rec_ts': t, 'beat_index': i, 'rr_ts_ms': t * 1000,
          'beat_ts_ms': raw, 'rr_ms': 700 + t % 90});
      }
    }
    await b.commit(noResult: true);
    final e = DerivationEngine();
    final before = await _load(e);
    var runningMax = double.negativeInfinity;
    final axis = <double>[];
    for (final raw in rawTimes) {
      if (raw > runningMax) runningMax = raw;
      axis.add(runningMax);
    }
    expect(before.rrTsMs, axis, reason: 'hold backward placements; never sort or shift beats');
    expect(before.rrMs, intervals, reason: 'interval order is the recorded rhythm');
    final extras = e.debugRetainedSubstrate(edDay);
    expect(extras['rr_ts_raw'], rawTimes,
        reason: 'the raw axis must be retained separately from its running max');
    expect(extras['rr_start'], starts);
    expect((extras['meta'] as List).map((m) => (m as List).first),
        [for (var i = 0; i < 5; i++) _lo ~/ 900 + i]);
    expect(before.rrTsMs, isNot(rawTimes));
    await edRows(_lo + 4 * 900 + 200, _hi + 1);
    final warm = await _load(e);
    final cold = await _load(DerivationEngine());
    expect(jsonEncode(warm.toJson()), jsonEncode(cold.toJson()));
  });

  test('retention respects its day bound and evicts the oldest day', () async {
    final e = DerivationEngine()..debugRetainedSubstrateMaxDays = 2;
    for (var i = 0; i < 3; i++) {
      final lo = DateTime(2020, 1, 2 + i, 10).millisecondsSinceEpoch ~/ 1000;
      await edRows(lo, lo + 1200);
      await e.debugLoadSubstrate(lo, lo + 1200, day: edLabel(lo));
      expect(e.debugRetainedSubstrateDays.length, lessThanOrEqualTo(2));
    }
    expect(e.debugRetainedSubstrateDays, {'2020-01-03', '2020-01-04'},
        reason: 'a zero-sized stub must not satisfy the bound');
  });

  for (final boundary in ['background', 'memory pressure', 'dispose']) {
    test('$boundary clears populated retention and next load stays exact', () async {
      final e = DerivationEngine();
      final before = await _load(e);
      expect(e.debugRetainedSubstrateDays, contains(edDay), reason: 'populated before boundary');
      switch (boundary) {
        case 'background': e.trimForBackground();
        case 'memory pressure': e.handleMemoryPressure();
        case 'dispose': e.dispose();
      }
      expect(e.debugRetainedSubstrateDays, isEmpty);
      final receiver = boundary == 'dispose' ? DerivationEngine() : e;
      expect(jsonEncode((await _load(receiver)).toJson()), jsonEncode(before.toJson()));
    });
  }

  test('real day finalization drops retained day and beat data', () async {
    final e = DerivationEngine();
    await e.runDays(edProfile, {edDay});
    expect(e.debugRetainedSubstrateDays, contains(edDay));
    final later = DateTime(2020, 1, 6, 10).millisecondsSinceEpoch ~/ 1000;
    await edRows(later, later + 1200);
    await e.runDays(edProfile, {edDay});
    expect((await LocalDb.dayResult(edDay))!['finalized'], 1);
    expect(e.debugRetainedSubstrateDays, isNot(contains(edDay)));
    expect(e.debugRetainedSubstrate(edDay), isEmpty);
  });

  test('a pass with no preparable day releases previously retained rows', () async {
    final e = DerivationEngine();
    await _load(e);
    expect(e.debugRetainedSubstrateDays, contains(edDay));
    final db = await LocalDb.instance;
    await db.delete('decoded_onehz');
    await db.delete('decoded_rr');
    expect(await e.runDays(edProfile, {edDay}), 0);
    expect(e.debugRetainedSubstrateDays, isEmpty);
    expect(e.debugRetainedSubstrate(edDay), isEmpty);
  });

  test('existing fixture: retained and cold derive output exact before and after revision', () async {
    await edExistingFixture();
    final warm = DerivationEngine();
    final cold = DerivationEngine()..debugDisableSubstrateRetention = true;
    await edPreparedOutput(warm);
    expect(await edPreparedOutput(warm), await edPreparedOutput(cold));
    await edRows(edStart, edStart + 1, hr: 89);
    expect(await edPreparedOutput(warm), await edPreparedOutput(cold));
  });
}
