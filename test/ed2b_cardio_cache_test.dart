@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/derive_prepare.dart';
import 'package:openstrap_edge/compute/ed2b_stream_diagnostics.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/compute/vendor_sleep.dart';
import 'package:openstrap_edge/data/db.dart';

import 'support/ed2a_recalc_fixture.dart';

const _day = '2020-01-02';
int _sec(int hour) => DateTime(2020, 1, 2, hour).millisecondsSinceEpoch ~/ 1000;

// RR plus accelerometry forces cardio rows through the real stager; a sleepy
// HR-only fixture could pass output guards without ever exercising the cache.
Substrate _night({int endHour = 7, int fromHour = -2}) {
  final ts = <int>[], hr = <int>[];
  final ax = <double>[], ay = <double>[], az = <double>[];
  final rr = <double>[], rt = <double>[];
  var beat = _sec(fromHour) * 1000.0;
  for (var t = _sec(fromHour); t < _sec(endHour); t++) {
    final asleep = t >= _sec(-1) && t < _sec(6);
    final bpm = asleep ? 52 + t % 7 : 85 + t % 13;
    ts.add(t); hr.add(bpm);
    ax.add(asleep ? 0 : .3 * math.sin(t * .21));
    ay.add(asleep ? 0 : .2 * math.cos(t * .13));
    az.add(asleep ? 1 : 1 + .05 * math.sin(t * .07));
    while (beat < (t + 1) * 1000) {
      final ibi = 60000 / bpm + (asleep ? 40 : 12) * math.sin(t * .35);
      rt.add(beat); rr.add(ibi); beat += ibi;
    }
  }
  return Substrate(tsSec: ts, hr: hr, ax: ax, ay: ay, az: az,
    rrMs: rr, rrTsMs: rt, skinTemp: List.filled(ts.length, 3000),
    skinContact: List.filled(ts.length, 1), spo2Red: List.filled(ts.length, 1),
    spo2Ir: List.filled(ts.length, 1), deviceFamily: 'gen4');
}

String _candidate(Substrate sub, ana.CardioRowCache? cache,
    {SleepWindowOverride? override}) => jsonEncode(prepareSleepSessionCandidate(
      sub, targetDay: _day, rowCache: cache, override: override).toJson());

Future<void> _save(Substrate sub) async {
  final db = await LocalDb.instance; final b = db.batch();
  for (var i = 0; i < sub.tsSec.length; i++) {
    final t = sub.tsSec[i];
    b.insert('decoded_onehz', {'device_id': '', 'ts_ms': t * 1000,
      'rec_ts': t, 'counter': i, 'hr': sub.hr[i], 'ax': sub.ax[i],
      'ay': sub.ay[i], 'az': sub.az[i], 'device_family': 'gen4'});
  }
  final indexes = <int, int>{};
  for (var i = 0; i < sub.rrMs.length; i++) {
    final t = sub.rrTsMs[i] ~/ 1000;
    final index = indexes.update(t, (v) => v + 1, ifAbsent: () => 0);
    b.insert('decoded_rr', {'device_id': '', 'ts_ms': t * 1000,
      'rec_ts': t, 'rr_ts_ms': sub.rrTsMs[i], 'rr_ms': sub.rrMs[i],
      'beat_index': index});
  }
  await b.commit(noResult: true);
}

void _nearPrsa(Object? got, Object? want, [String path = r'$']) {
  if (got is double && want is double) {
    final tolerance = path.endsWith('.confidence') ? 1e-12 : 1e-9 + 1e-9 * want.abs();
    expect((got - want).abs(), lessThanOrEqualTo(tolerance), reason: path);
  } else if (want is Map) {
    final g = got as Map; expect(g.keys.toList(), want.keys.toList());
    for (final k in want.keys) { _nearPrsa(g[k], want[k], '$path.$k'); }
  } else if (want is List) {
    final g = got as List; expect(g.length, want.length);
    for (var i = 0; i < want.length; i++) { _nearPrsa(g[i], want[i], '$path[$i]'); }
  } else { expect(got, want, reason: path); }
}

void _checkNightOutput(Map<String, dynamic> input, Map<String, dynamic> output) {
  final cold = deriveDayBundle(input);
  final a = Map<String, dynamic>.from(output['clinical'] as Map);
  final b = Map<String, dynamic>.from(cold['clinical'] as Map);
  for (final k in ['prsa_dc', 'prsa_ac']) { _nearPrsa(a.remove(k), b.remove(k)); }
  expect(jsonEncode({...output, 'clinical': a}), jsonEncode({...cold, 'clinical': b}));
}

void main() {
  for (final path in ['candidate auto', 'candidate manual', 'candidate confirmed', 'payload', 'calendar']) {
    test('E6 $path shares the supplied CardioRowCache and stays byte-identical', () {
      final sub = _night(); final cache = ana.CardioRowCache();
      String run(ana.CardioRowCache? rows) {
        if (path == 'candidate auto') { return _candidate(sub, rows); }
        if (path == 'candidate confirmed' || path == 'candidate manual') { return _candidate(sub, rows,
          override: SleepWindowOverride(dayId: _day, onsetSec: _sec(0),
            offsetSec: _sec(5), source: path == 'candidate manual' ? 'manual' : 'confirmed')); }
        if (path == 'payload') { return jsonEncode(prepareDerivationPayload(sub,
          targetDay: _day, rowCache: rows).days.map((d) => d.toJson()).toList()); }
        return jsonEncode(calendarDays(sub, rowCache: rows)
          .map((d) => d.sleep.toJson()).toList());
      }
      final plain = run(null); expect(run(cache), plain); expect(run(cache), plain);
      expect(cache.length, greaterThan(0), reason: 'every actual staging call must populate shared rows');
      expect(cache.hits, greaterThan(0));
    });
  }

  test('E6 HR-led fallback shares the cache through its forced stager', () {
    // Include waking HR before the previous local noon so the fallback uses
    // an actual daytime baseline rather than a flat night percentile.
    final original = _night(fromHour: -13);
    final sub = Substrate.fromJson({...original.toJson(),
      // Keep valid moving vectors: all-zero missing accel would leave the
      // forced stager with no feature rows to cache even after E6 lands.
      'ax': [for (final t in original.tsSec) .3 * math.sin(t * .21)],
      'ay': [for (final t in original.tsSec) .2 * math.cos(t * .13)],
      'az': [for (final t in original.tsSec) 1 + .05 * math.sin(t * .07)]});
    final plain = prepareSleepSessionCandidate(sub, targetDay: _day);
    expect(plain.present, isTrue);
    expect(plain.sleepSource, 'auto_fallback', reason: 'fixture must reach the HR-led forced-window call');
    final cache = ana.CardioRowCache();
    expect(_candidate(sub, cache), jsonEncode(plain.toJson()));
    expect(_candidate(sub, cache), jsonEncode(plain.toJson()));
    expect(cache.hits, greaterThan(0));
  });

  test('E6 vendor-owned forced staging shares the same auto-stage row cache', () {
    final sub = _night();
    final plain = prepareSleepSessionCandidate(sub, targetDay: _day);
    expect(plain.present, isTrue);
    final start = plain.sleepOnsetSec, end = plain.sleepOffsetSec - 1;
    final step = (end - start) ~/ 3;
    final vendor = VendorNight(deviceId: '', source: 'gen4', decodedAtSec: _sec(7),
      epochs: [VendorEpoch(start, start + step, 'light'),
        VendorEpoch(start + step, start + step * 2, 'deep'),
        VendorEpoch(start + step * 2, end, 'rem')]);
    String run(ana.CardioRowCache? cache) {
      final got = prepareSleepSessionCandidate(sub, targetDay: _day,
        vendorNights: [vendor], rowCache: cache);
      expect(got.sleepSource, 'vendor_staged', reason: 'fixture must reach the vendor forced-window call');
      return jsonEncode(got.toJson());
    }
    final cold = run(null), cache = ana.CardioRowCache();
    expect(run(cache), cold); expect(run(cache), cold);
    expect(cache.hits, greaterThan(0));
  });

  test('E6 an append reuses settled rows and preserves cold candidate bytes', () {
    final cache = ana.CardioRowCache();
    _candidate(_night(endHour: 3), cache);
    final full = _night(); final got = _candidate(full, cache);
    expect(got, _candidate(full, null));
    expect(cache.hits, greaterThan(0), reason: 'earlier epochs survive a growing night');
  });

  test('guard: #99 malformed cardio cache refuses whole payload', () {
    for (final bad in [<String, dynamic>{'version': 99, 'rows': []},
        <String, dynamic>{'version': 2, 'rows': 'invalid'},
        <String, dynamic>{'version': 2, 'rows': [{'startSec': 1}]}]) {
      expect(() => ana.CardioRowCache.fromJson(bad), throwsFormatException);
    }
  });

  group('E6 engine owns encoded bytes and workers own row objects', () {
    setUpAll(edInit);
    setUp(() async { await edFresh('ed2b_cardio.db'); await _save(_night()); });
    tearDown(edDrop);

    test('real engine worker decodes, merges and prunes the shared row cache', () async {
      final e = DerivationEngine()..debugDisableStagedSleepCache = true;
      final first = await e.debugSleepCandidate(_day);
      final second = await e.debugSleepCandidate(_day);
      expect(jsonEncode(second.toJson()), jsonEncode(first.toJson()));
      expect(e.debugCardioRowBytes, isA<Uint8List>(), reason: 'UI isolate retains only the encoded payload');
      expect(e.debugCardioRowHits, greaterThan(0));
      expect(e.debugCardioRowWorkerOperations, containsAll(['decode:worker', 'merge:worker', 'prune:worker']));
      expect(e.debugCardioRowWorkerOperations.where((s) => s.endsWith(':caller')), isEmpty);
      final cold = DerivationEngine()..debugDisableStagedSleepCache = true
        ..debugDisableCardioRows = true;
      expect(jsonEncode((await cold.debugSleepCandidate(_day)).toJson()),
          jsonEncode(first.toJson()));
    });

    for (final key in ['input revision', 'generation', 'algorithm']) {
      test('$key rejects bytes then replacement cache hits with cold-exact staging', () async {
        final e = DerivationEngine()..debugDisableStagedSleepCache = true;
        final first = await e.debugSleepCandidate(_day);
        final firstMisses = e.debugCardioRowMisses;
        if (key == 'input revision') {
          final db = await LocalDb.instance;
          final row = (await db.query('decoded_onehz', limit: 1)).first;
          await db.update('decoded_onehz', {'hr': row['hr']},
            where: 'device_id = ? AND ts_ms = ?', whereArgs: [row['device_id'], row['ts_ms']]);
        } else if (key == 'generation') {
          await LocalDb.close(); await LocalDb.instance;
        } else {
          final fp = await LocalDb.inputDayFingerprint(_day);
          e.debugRekeyCardioRows(inputRevision: fp.revisionSum,
            generation: fp.generation, algorithm: 115);
        }
        final changed = await e.debugSleepCandidate(_day);
        expect(jsonEncode(changed.toJson()), jsonEncode(first.toJson()));
        expect(e.debugCardioRowMisses, greaterThan(firstMisses),
            reason: 'new provenance must reject existing encoded rows');
        final misses = e.debugCardioRowMisses, hits = e.debugCardioRowHits;
        await e.debugSleepCandidate(_day);
        expect(e.debugCardioRowMisses, misses);
        expect(e.debugCardioRowHits, greaterThan(hits), reason: 'new provenance must become reusable');
      });
    }
    test('E7-E11 real runDays retains night streams across worker dispatches', () async {
      await LocalDb.putSleepOverride(dayId: _day, onsetTs: _sec(1),
        offsetTs: _sec(1) + 1200, source: 'confirmed');
      var observed = 0;
      final e = DerivationEngine()..debugNightStreams = Ed2bStreamDiagnostics();
      e.debugOnNightBundle = (input, output) {
        observed++;
        _checkNightOutput(input, output);
      };
      expect(await e.runDays(edProfile, {_day}), 1);
      expect(observed, greaterThan(0));
      final before = e.debugNightStreams!;
      expect(before.processedNightBeats, greaterThan(0));
      final work = {for (final name in ['frequency', 'rsa', 'cvhr', 'prsa', 'rsa_bins'])
        name: before.processedBeats(name)};
      expect(await e.runDays(edProfile, {_day}), 1);
      expect(e.debugNightStreams!.processedNightBeats, before.processedNightBeats,
        reason: 'the production dispatch must return and retain the RAM night owner');
      for (final entry in work.entries) {
        expect(work[entry.key], greaterThan(0));
        expect(e.debugNightStreams!.processedBeats(entry.key), entry.value);
      }
      expect(e.debugNightStreams!.fullListDigests, greaterThan(0));
      expect(e.debugNightStreams!.maximumListDigestsPerIdentity, 1);
      expect(e.debugNightStreams!.identityMemoEntries, 0);
    });

    for (final change in ['revision', 'generation', 'algorithm']) {
      test('E7-E11 engine $change misses then retains the replacement worker state', () async {
        await LocalDb.putSleepOverride(dayId: _day, onsetTs: _sec(1),
          offsetTs: _sec(1) + 1200, source: 'confirmed');
        final e = DerivationEngine()..debugNightStreams = Ed2bStreamDiagnostics()
          ..debugOnNightBundle = _checkNightOutput;
        // Isolate the RAM generation contract: disk checkpoints legitimately
        // survive reopen and would otherwise hide the required RAM rebuild.
        if (change == 'generation') e.debugCheckpoints.disabled = true;
        expect(await e.runDays(edProfile, {_day}), 1);
        final before = e.debugNightStreams!.processedNightBeats;
        if (change == 'revision') {
          final db = await LocalDb.instance;
          final row = (await db.query('decoded_onehz', where: 'rec_ts = ?',
            whereArgs: [_sec(1) + 60], limit: 1)).first;
          await db.update('decoded_onehz', {'hr': row['hr']},
            where: 'device_id = ? AND ts_ms = ?', whereArgs: [row['device_id'], row['ts_ms']]);
        } else if (change == 'generation') {
          await LocalDb.close(); await LocalDb.instance;
        } else {
          final fp = await LocalDb.inputDayFingerprint(_day);
          e.debugNightStreams!.context(inputRevision: fp.revisionSum,
            generation: fp.generation, algorithm: 115);
        }
        expect(await e.runDays(edProfile, {_day}), 1);
        final miss = e.debugNightStreams!.processedNightBeats;
        expect(miss, greaterThan(before));
        final metricWork = {for (final s in ['frequency', 'rsa', 'cvhr', 'prsa', 'rsa_bins'])
          s: e.debugNightStreams!.processedBeats(s)};
        expect(await e.runDays(edProfile, {_day}), 1);
        expect(e.debugNightStreams!.processedNightBeats, miss);
        for (final s in metricWork.keys) {
          expect(e.debugNightStreams!.processedBeats(s), metricWork[s]);
        }
        expect(e.debugNightStreams!.identityMemoEntries, 0);
      });
    }
  });
}
