// Integration test for the on-device compute path:
//   real raw frames (whoop_hist.jsonl) → decode (openstrap_protocol)
//   → DayInput → deriveDayBundle (the pure isolate entry, called SYNCHRONOUSLY)
//   → assert a sane derived bundle (RHR, an HRV value, no crash).
//
// Also shapes the bundle the way LocalRepositoryImpl.getToday() does and asserts
// it is a well-formed Today map.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';

void main() {
  // The backfill/insert fix: rec_ts must come from the frame's REAL device time,
  // never from receive time. decodeRecTs is the pure resolver used at insert AND
  // in the v6 migration backfill — if it returned the fallback (≈now) the whole
  // multi-day backfill would collapse into one "today" bucket and hang derivation.
  test('decodeRecTs reads the frame\'s real ts, not the fallback', () {
    final candidates = ['../whoop_hist.jsonl', '../../whoop_hist.jsonl', 'whoop_hist.jsonl'];
    File? f;
    for (final c in candidates) {
      if (File(c).existsSync()) { f = File(c); break; }
    }
    expect(f, isNotNull, reason: 'whoop_hist.jsonl fixture not found');

    const sentinelFallback = 111; // a value the real ts can never equal
    final dayLabels = <String>{};
    var decodedCount = 0;
    for (final line in f!.readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      final hex = (jsonDecode(line) as Map<String, dynamic>)['hex'] as String?;
      if (hex == null) continue;
      final ts = LocalDb.decodeRecTs(hex, fallbackSec: sentinelFallback);
      if (ts == sentinelFallback) continue; // undecodable frame (events etc.)
      decodedCount++;
      expect(ts, greaterThan(1600000000), reason: 'a real 2020+ epoch, not fallback');
      final d = DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: false);
      dayLabels.add('${d.year}-${d.month}-${d.day}');
    }
    expect(decodedCount, greaterThan(50), reason: 'decoded real frames');
    // Every decoded frame bucketed by its own real day (here all one day).
    expect(dayLabels, isNotEmpty);
  });

  test('deriveDayBundle on real raw frames produces a sane bundle', () {
    // The fixture sits next to the worktree: whoop-master/whoop_hist.jsonl.
    final candidates = [
      '../whoop_hist.jsonl',
      '../../whoop_hist.jsonl',
      'whoop_hist.jsonl',
    ];
    File? f;
    for (final c in candidates) {
      final file = File(c);
      if (file.existsSync()) {
        f = file;
        break;
      }
    }
    expect(f, isNotNull, reason: 'whoop_hist.jsonl fixture not found');

    final hexes = <String>[];
    for (final line in f!.readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      final m = jsonDecode(line) as Map<String, dynamic>;
      final hex = m['hex'] as String?;
      if (hex != null) hexes.add(hex);
    }
    expect(hexes.length, greaterThan(100), reason: 'expected real frames');

    // ── decode → 1 Hz series (mirrors DerivationEngine._buildDayInput) ────────
    final hrTs = <int>[], hrBpm = <int>[];
    final rrTsMs = <double>[], rrMs = <double>[];
    final aTs = <double>[], ax = <double>[], ay = <double>[], az = <double>[];
    final skinTemp = <int>[], spo2Red = <int>[], spo2Ir = <int>[];

    for (final hex in hexes) {
      final r = proto.parseR24(proto.hexToBytes(hex));
      if (r == null || r.tsEpoch <= 0) continue;
      hrTs.add(r.tsEpoch);
      hrBpm.add(r.hr);
      final t = r.tsEpoch * 1000.0;
      for (final rr in r.rrIntervalsMs) {
        if (rr > 0) {
          rrMs.add(rr.toDouble());
          rrTsMs.add(t);
        }
      }
      if (r.accelG.length == 3) {
        aTs.add(r.tsEpoch.toDouble());
        ax.add(r.accelG[0]);
        ay.add(r.accelG[1]);
        az.add(r.accelG[2]);
      }
      skinTemp.add(r.skinTempRaw);
      spo2Red.add(r.spo2RedRaw);
      spo2Ir.add(r.spo2IrRaw);
    }

    // Sanity on decode itself.
    expect(hrBpm.where((h) => h > 0).length, greaterThan(50),
        reason: 'decoded valid HR samples');
    expect(rrMs.length, greaterThan(50), reason: 'decoded RR beats');

    // The fixture is ~9 min of real frames. Nocturnal RHR needs ≥~15 min of
    // valid HR (a half-window). Tile the REAL decoded HR/accel forward in time
    // to ~30 min so the night-grade clinical metrics (RHR, dip) exercise on
    // genuine values — no synthetic numbers, just real samples repeated along a
    // continuous timeline.
    final tiles = (1800 / hrBpm.length).ceil() + 1; // ≥30 min @1 Hz
    final baseTs = hrTs.first;
    final n0 = hrBpm.length;
    final a0 = ax.length;
    final hrBpm0 = List<int>.from(hrBpm);
    final ax0 = List<double>.from(ax);
    final ay0 = List<double>.from(ay);
    final az0 = List<double>.from(az);
    final st0 = List<int>.from(skinTemp);
    final sr0 = List<int>.from(spo2Red);
    final si0 = List<int>.from(spo2Ir);
    for (var t = 1; t < tiles; t++) {
      for (var i = 0; i < n0; i++) {
        hrTs.add(baseTs + t * n0 + i);
        hrBpm.add(hrBpm0[i]);
      }
      for (var i = 0; i < a0; i++) {
        aTs.add((baseTs + t * n0 + i).toDouble());
        ax.add(ax0[i]);
        ay.add(ay0[i]);
        az.add(az0[i]);
        skinTemp.add(st0[i]);
        spo2Red.add(sr0[i]);
        spo2Ir.add(si0[i]);
      }
    }

    final input = DayInput(
      date: '2026-06-24',
      hrTsSec: hrTs,
      hrBpm: hrBpm,
      rrTsMs: rrTsMs,
      rrMs: rrMs,
      accelTsSec: aTs,
      ax: ax,
      ay: ay,
      az: az,
      skinTempRaw: skinTemp,
      spo2RedRaw: spo2Red,
      spo2IrRaw: spo2Ir,
      profile: const Profile(
        ageYears: 30, weightKg: 75, heightCm: 178, sex: 'm').toMap(),
    ).toJson();

    // ── run the pure pipeline synchronously (the isolate entry fn) ───────────
    final bundle = deriveDayBundle(input);

    // Bundle is well-formed + JSON-serializable.
    expect(bundle['date'], '2026-06-24');
    expect(() => jsonEncode(bundle), returnsNormally);

    final scalars = (bundle['scalars'] as Map).cast<String, dynamic>();
    // RHR present + physiologically plausible.
    expect(scalars['rhr'], isNotNull, reason: 'nocturnal RHR computed');
    expect(scalars['rhr'] as num, inInclusiveRange(25, 220));
    // An HRV value present + positive.
    expect(scalars['rmssd'], isNotNull, reason: 'RMSSD computed');
    expect(scalars['rmssd'] as num, greaterThan(0));

    // Clinical envelopes carry the honest {value,confidence,tier} shape.
    final clinical = (bundle['clinical'] as Map).cast<String, dynamic>();
    final hrvTime = (clinical['hrv_time'] as Map).cast<String, dynamic>();
    expect(hrvTime['tier'], anyOf('HIGH', 'AUTH'));
    expect(hrvTime['confidence'] as num, greaterThan(0));

    // Coverage diagnostics.
    final cov = (bundle['coverage'] as Map).cast<String, dynamic>();
    expect(cov['nn_clean'] as num, greaterThan(0));

    // ── shape it like getToday() and assert a well-formed Today map ──────────
    final today = _shapeToday(bundle);
    expect(today['daily'], isA<Map>());
    final daily = (today['daily'] as Map).cast<String, dynamic>();
    final rhrMetric = (daily['resting_hr'] as Map).cast<String, dynamic>();
    expect(rhrMetric['value'], isNotNull);
    expect(rhrMetric['value'], isNot('—'));
  });
}

/// Minimal mirror of LocalRepositoryImpl.getToday() shaping (no DB).
Map<String, dynamic> _shapeToday(Map<String, dynamic> b) {
  final scalars = (b['scalars'] as Map).cast<String, dynamic>();
  num? sc(String k) => scalars[k] as num?;
  Map<String, dynamic> m(num? v, String tier) => {
        'value': v ?? '—',
        'confidence': v == null ? 0 : 0.8,
        'tier': tier,
        'inputs_used': const [],
      };
  return {
    'daily': {
      'readiness': m(sc('readiness'), 'HIGH'),
      'resting_hr': m(sc('rhr')?.round(), 'HIGH'),
      'strain': m(sc('trimp'), 'ESTIMATE'),
    },
    'sleep': const {},
    'hrv': {'rmssd': sc('rmssd'), 'sdnn': sc('sdnn')},
    'step_goal': 10000,
  };
}
