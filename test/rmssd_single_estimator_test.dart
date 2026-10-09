// `rmssd` is ONE estimator: the sleep-session mean of 5-min-window RMSSDs, the
// same number `ln_rmssd` (→ readiness) is the log of, or it is absent.
//
// It used to fall back to the NREM median (`nocturnalRmssd`) and then to the
// whole-night RMSSD (`hrvTime`) whenever the session estimator abstained. Those
// are different statistics over differently-cleaned beats, so the charted HRV
// series, its baseline, the widget, the coach and the Health Connect export
// mixed three estimators, and on a fallback night the "HRV" shown was not the
// HRV readiness scored. The other two still publish, under their own keys.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';

const int _t0 = 1786700000;
const int _nightSec = 2 * 3600;

Map<String, dynamic> _night({required bool session}) {
  final rr = <double>[], ts = <double>[];
  var t = _t0 * 1000.0;
  for (var i = 0; i < _nightSec; i++) {
    final v = 1000.0 + 16.0 * math.sin(2 * math.pi * i / 12);
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
      sleepRrMs: rr,
      sleepRrTsMs: ts,
      sleepSkinTemp: List<int>.filled(_nightSec, 0),
      sleepJson: const <String, dynamic>{'tst_sec': _nightSec},
      hypnoStages: const [],
      sleepOnsetSec: session ? _t0 : 0,
      sleepOffsetSec: session ? (ts.last / 1000).ceil() + 1 : 0,
      profile: const {'age': 30, 'sex': 'm', 'weight_kg': 70, 'height_cm': 175},
      deviceFamily: 'gen4',
      rmssdHistory: [for (var i = 0; i < 14; i++) 5.5 + 0.2 * (i % 5)],
    ).toJson(),
  );
}

Map<String, dynamic> _m(Map<String, dynamic> b, String k) =>
    (b[k] as Map).cast<String, dynamic>();

void main() {
  test('no session estimate: rmssd is absent, not a stand-in', () {
    final b = _night(session: false);
    final scalars = _m(b, 'scalars');
    final clinical = _m(b, 'clinical');
    expect(_m(clinical, 'rmssd_sleep_session')['value'], '—');
    // Before: scalars.rmssd == clinical.rmssd_nocturnal.value here, while
    // ln_rmssd was null — two keys describing different quantities.
    expect(scalars['rmssd'], isNull);
    expect(scalars['ln_rmssd'], isNull);
    // The other estimators still publish, under their own keys.
    expect(_m(clinical, 'rmssd_nocturnal')['value'], isA<num>());
    expect(scalars['rmssd_whole'], isNotNull);
    // Nothing downstream folds a stand-in either.
    expect(_m(_m(b, 'baselines'), 'hrv')['value'], isNull);
    expect(_m(b, 'stress')['rmssd'], isNull);
  });

  test('with a session: rmssd IS the session estimate, and ln_rmssd its log',
      () {
    final b = _night(session: true);
    final scalars = _m(b, 'scalars');
    final session = _m(_m(b, 'clinical'), 'rmssd_sleep_session');
    expect(session['value'], isA<num>());
    expect(scalars['rmssd'] as num,
        closeTo(session['value'] as num, 0.05)); // envelope rounds to 1 dp
    expect(math.exp(scalars['ln_rmssd'] as num),
        closeTo(scalars['rmssd'] as num, 1e-9));
    expect(session['windows'] as num, greaterThanOrEqualTo(20));
    expect(session['thin_windows'], isA<int>());
    expect(session['min_diffs_per_window'], 20);
  });

  test("Today's HRV confidence is the headline's own, not the whole night's",
      () {
    // The block shows the session estimate, so it carries that estimate's
    // confidence. It used to carry `hrv_time`'s, a different estimator.
    expect(
        hrvConfidenceForToday({
          'rmssd_sleep_session': {'value': 61.0, 'confidence': 0.82},
          'hrv_time': {'confidence': 0.3},
        }),
        0.82);
    // A bundle derived BEFORE this change can hold a fallback rmssd beside an
    // absent session envelope: it keeps the confidence it was served with.
    expect(
        hrvConfidenceForToday({
          'rmssd_sleep_session': {'value': '—', 'confidence': 0},
          'hrv_time': {'confidence': 0.62},
        }),
        0.62);
    // Malformed rows only: fall back as before rather than throw.
    expect(hrvConfidenceForToday({'hrv_time': {'confidence': 0.3}}), 0.3);
    expect(hrvConfidenceForToday(const {}), 0.5);
  });
}
