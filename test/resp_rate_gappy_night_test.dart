// A sensor gap does not cost the night its respiratory rate.
//
// The RSA estimator used to read the beat-rate Nyquist off span/(n−1). Across
// a dropout that is the beat interval DIVIDED BY COVERAGE, so a 55 bpm night
// missing a quarter of its beats "beat" at ~41 bpm and was withheld whole as an
// alias — `scalars.resp_rate` null, the readiness resp driver and the resp
// baseline gone, and a note blaming a heart rate the user never had. The alias
// guard itself is real and stays: at a genuinely low heart rate the beats are
// too slow to resolve normal breathing, and the note now says so truthfully.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';

const int _t0 = 1786700000;
const int _nightSec = 7 * 3600;

/// 7 h of RSA at [hrBpm], 40 ms at 15 br/min. Beats whose time falls in
/// [holeSec] (seconds from onset) happened but were never recorded.
Map<String, dynamic> _night({required double hrBpm, (int, int)? holeSec}) {
  final base = 60000.0 / hrBpm, f = 15.0 / 60.0;
  final rr = <double>[], ts = <double>[];
  var tMs = 0.0;
  while (tMs < _nightSec * 1000) {
    final v = base + 40 * math.sin(2 * math.pi * f * tMs / 1000);
    tMs += v;
    final sec = tMs / 1000;
    if (holeSec != null && sec >= holeSec.$1 && sec < holeSec.$2) continue;
    rr.add(v);
    ts.add(_t0 * 1000.0 + tMs);
  }
  final sleepTs = <int>[for (var i = 0; i < _nightSec; i++) _t0 + i];
  final hr = List<int>.filled(_nightSec, hrBpm.round());
  return deriveDayBundle(
    DayBundleInput(
      date: '2026-08-14',
      dayTsSec: sleepTs,
      dayHr: hr,
      sleepTsSec: sleepTs,
      sleepHr: hr,
      sleepRrMs: rr,
      sleepRrTsMs: ts,
      sleepSkinTemp: List<int>.filled(_nightSec, 0),
      sleepJson: const <String, dynamic>{
        'tst_sec': _nightSec,
        'efficiency_pct': 92.0,
      },
      hypnoStages: const [],
      sleepOnsetSec: _t0,
      sleepOffsetSec: _t0 + _nightSec,
      profile: const {'age': 30, 'sex': 'm', 'weight_kg': 70, 'height_cm': 175},
      deviceFamily: 'gen4',
    ).toJson(),
  );
}

Map<String, dynamic> _m(Map<String, dynamic> b, String k) =>
    (b[k] as Map).cast<String, dynamic>();

void main() {
  test('a night with a 1 h 45 min hole still publishes its breathing rate', () {
    final b = _night(hrBpm: 55, holeSec: (2 * 3600, 3 * 3600 + 45 * 60));
    final rsa = _m(_m(b, 'respiration'), 'rsa');
    final scalars = _m(b, 'scalars');
    expect(scalars['resp_rate'], isNotNull, reason: '${rsa['note']}');
    expect(scalars['resp_rate'] as num, closeTo(15, 1.0));
    expect(rsa['note'] as String, isNot(contains('beat rate')));
  });

  test('a genuinely low heart rate is still withheld, and the note says so',
      () {
    final b = _night(hrBpm: 45);
    final rsa = _m(_m(b, 'respiration'), 'rsa');
    expect(_m(b, 'scalars')['resp_rate'], isNull);
    expect(rsa['note'] as String, contains('alias'));
    expect(rsa['note'] as String, contains('45'));
  });
}
