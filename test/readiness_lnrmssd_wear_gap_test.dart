// The Plews rolling-7 lnRMSSD baseline was handed only values, so it took the
// last 7 stored ROWS. After a wear gap those are nights from weeks ago, and
// the first night back got a confident suppressed/normal/elevated band scored
// against them. With the dates passed through, the window is 7 calendar
// nights and abstains until it refills.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';

const int _t0 = 1786700000;
const int _nightSec = 2 * 3600;

String _label(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}'
    '-${d.day.toString().padLeft(2, '0')}';

Map<String, dynamic> _lnReadiness({
  required List<String> historyDates,
  bool withDates = true,
  bool tonightRr = true,
}) {
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
  final b = deriveDayBundle(
    DayBundleInput(
      date: '2026-08-14',
      dayTsSec: sleepTs,
      dayHr: hr,
      sleepTsSec: sleepTs,
      sleepHr: hr,
      sleepRrMs: tonightRr ? rr : const <double>[],
      sleepRrTsMs: tonightRr ? ts : const <double>[],
      sleepSkinTemp: List<int>.filled(_nightSec, 0),
      sleepJson: const <String, dynamic>{'tst_sec': _nightSec},
      hypnoStages: const [],
      sleepOnsetSec: _t0,
      sleepOffsetSec: (ts.last / 1000).ceil() + 1,
      profile: const {'age': 30, 'sex': 'm', 'weight_kg': 70, 'height_cm': 175},
      deviceFamily: 'gen4',
      lnRmssdHistory: [
        for (var i = 0; i < historyDates.length; i++) 3.4 + 0.05 * (i % 3)
      ],
      lnRmssdDates: withDates ? historyDates : const [],
    ).toJson(),
  );
  return ((b['clinical'] as Map)['readiness_lnrmssd'] as Map)
      .cast<String, dynamic>();
}

List<String> _nightsEnding(DateTime last, int n) => [
      for (var i = n - 1; i >= 0; i--)
        _label(DateTime(last.year, last.month, last.day - i))
    ];

void main() {
  test('nights from before a three-week gap are not a rolling-7 baseline', () {
    // 21 nights ending Jul 24, nothing since; tonight is Aug 14.
    final env =
        _lnReadiness(historyDates: _nightsEnding(DateTime(2026, 7, 24), 21));
    expect(env['value'], isNot(isA<Map>()));
    expect(env['note'] as String, startsWith('need_baseline:'));
  });

  test('without dates it still falls back to the rows window', () {
    final env = _lnReadiness(
        historyDates: _nightsEnding(DateTime(2026, 7, 24), 21),
        withDates: false);
    expect(env['value'], isA<Map>());
  });

  test('an unbroken week before tonight still computes', () {
    final env =
        _lnReadiness(historyDates: _nightsEnding(DateTime(2026, 8, 13), 21));
    expect(env['value'], isA<Map>());
    expect((env['value'] as Map)['band'], isNotNull);
  });

  test('a night with no RMSSD does not score the previous night as tonight',
      () {
    final env = _lnReadiness(
        historyDates: _nightsEnding(DateTime(2026, 8, 13), 21),
        tonightRr: false);
    expect(env['value'], isNot(isA<Map>()));
    expect(env['note'] as String, contains('no sleep-session RMSSD'));
  });
}
