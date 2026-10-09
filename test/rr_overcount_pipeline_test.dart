// An RR stream that banks more beat-time than elapsed loses every RMSSD.
//
// A double-ingested or two-device-interleaved RR stream reads Σ RR ÷ wall span
// ≈ 2.0 and passes every other gate: duplicated beats add zero differences and
// deflate RMSSD by ~1/√2, interleaved streams inflate it, and neither looks
// like jitter. Analytics refuses RMSSD above 1.10; the pipeline has to hand
// that coverage to the whole-night and NREM estimators too, and store it.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';

const int _t0 = 1786700000;
const int _nightSec = 7 * 3600;

/// 7 h of RSA at HR 60 / 12 br/min (the jitter screen keeps it), optionally
/// with every (rr, ts) pair stored twice.
Map<String, dynamic> _night({bool duplicateBeats = false}) {
  final rr = <double>[], ts = <double>[];
  var tSec = 0.0;
  var t = _t0 * 1000.0;
  while (tSec < _nightSec - 2) {
    final v = 1000 + 30 * math.sin(2 * math.pi * (12 / 60) * tSec);
    tSec += v / 1000;
    t += v;
    rr.add(v);
    ts.add(t);
  }
  final sleepTs = <int>[for (var i = 0; i < _nightSec; i++) _t0 + i];
  final hr = List<int>.filled(_nightSec, 60);
  return deriveDayBundle(
    DayBundleInput(
      date: '2026-08-14',
      dayTsSec: sleepTs,
      dayHr: hr,
      sleepTsSec: sleepTs,
      sleepHr: hr,
      sleepRrMs: duplicateBeats ? [for (final v in rr) ...[v, v]] : rr,
      sleepRrTsMs: duplicateBeats ? [for (final x in ts) ...[x, x]] : ts,
      sleepSkinTemp: List<int>.filled(_nightSec, 0),
      sleepJson: const <String, dynamic>{
        'tst_sec': _nightSec,
        'efficiency_pct': 92.0,
      },
      hypnoStages: const [],
      sleepOnsetSec: _t0,
      sleepOffsetSec: (ts.last / 1000).ceil() + 1,
      profile: const {'age': 30, 'sex': 'm', 'weight_kg': 70, 'height_cm': 175},
      deviceFamily: 'gen4',
    ).toJson(),
  );
}

Map<String, dynamic> _m(Map<String, dynamic> b, String k) =>
    (b[k] as Map).cast<String, dynamic>();

void main() {
  test('an honest stream reads ≈ 1.0 and keeps its RMSSD, with diagnostics',
      () {
    final b = _night();
    final scalars = _m(b, 'scalars');
    final session = _m(_m(b, 'clinical'), 'rmssd_sleep_session');
    expect(scalars['rmssd'], isNotNull, reason: '${session['note']}');
    expect(session['windows'] as num, greaterThan(80));
    expect(session['diff_acf1'], isA<num>());
    expect(session['rr_coverage'] as num, closeTo(1.0, 0.02));
    expect(session['overcounted_windows'], 0);
    expect(_m(b, 'series')['hrv_timeline'] as List, isNotEmpty);
    expect(_m(b, 'hrv_night_shape')['value'], isNot(anyOf(isNull, '—')));
    final coverage = _m(b, 'coverage');
    expect(coverage['rr_coverage'] as num, closeTo(1.0, 0.02));
    expect(coverage['rr_duplicate_beats'], 0);
  });

  test('every beat duplicated: every RMSSD is refused as an over-count', () {
    final b = _night(duplicateBeats: true);
    final scalars = _m(b, 'scalars');
    final clinical = _m(b, 'clinical');
    final session = _m(clinical, 'rmssd_sleep_session');
    expect(scalars['rmssd'], isNull);
    expect(scalars['ln_rmssd'], isNull);
    expect(session['value'], '—');
    expect(session['note'] as String, startsWith('rr_overcount'));
    final coverage = _m(b, 'coverage');
    expect(coverage['rr_coverage'] as num, closeTo(2.0, 0.05));
    expect(coverage['rr_duplicate_beats'] as num, greaterThan(0));
    expect(scalars['rmssd_whole'], isNull,
        reason: 'whole-night RMSSD refuses the same over-count');
    final nocturnal = _m(clinical, 'rmssd_nocturnal');
    expect(nocturnal['value'], anyOf(isNull, '—'));
    expect(nocturnal['note'] as String, startsWith('rr_overcount'),
        reason: 'the NREM median refuses it too, by name');
    final shape = _m(b, 'hrv_night_shape');
    expect(shape['value'], anyOf(isNull, '—'));
    expect(shape['note'] as String, startsWith('rr_overcount'),
        reason: 'so does the nightly HRV shape, every bin of it');
    expect(_m(b, 'series')['hrv_timeline'] as List, isEmpty,
        reason: 'and the rolling RMSSD timeline is not drawn');
  });
}
