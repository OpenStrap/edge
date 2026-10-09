import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/health/health_export.dart';

void main() {
  // 8 h night, RR drifting 800 -> 1200 ms, ±30 ms respiratory swing on top.
  final nn = <double>[];
  final times = <double>[];
  var t = 0.0;
  const n = 30000;
  for (var i = 0; i < n; i++) {
    final rr = 800 + 400 * i / n + 30 * math.sin(i * 2 * math.pi / 4);
    t += rr;
    nn.add(rr);
    times.add(t);
  }

  test('#315 windowed SDNN ignores overnight HR drift', () {
    final m = nn.reduce((a, b) => a + b) / nn.length;
    final whole = math.sqrt(
      nn.fold<double>(0, (s, x) => s + (x - m) * (x - m)) / (nn.length - 1),
    );
    final windowed = sleepSdnnIndex(nn, times)!;
    expect(whole, greaterThan(100)); // the drift the old export carried
    expect(windowed, inInclusiveRange(20, 25)); // ~ the 30 ms swing's SD
  });

  test('a thin window across a dropout does not join the mean', () {
    final withEdge = [...nn, 300.0, 2000.0, 300.0];
    final edgeTimes = [...times, t + 3.6e6, t + 3.6e6 + 2000, t + 3.6e6 + 2300];
    expect(sleepSdnnIndex(withEdge, edgeTimes), sleepSdnnIndex(nn, times));
    expect(sleepSdnnIndex(const [800, 810], const [800, 1610]), isNull);
  });

  test('Apple export writes sdnn_window, never the whole-night sdnn', () {
    final b = <String, dynamic>{
      'scalars': {'sdnn': 197.0, 'sdnn_window': 52.4, 'rmssd': 96.0},
      'clinical': {
        'hrv_time': {
          'value': {'sdnn_ms': 197.0, 'sdnn_index_ms': 55.0},
        },
      },
    };
    expect(healthHrvExportValue(b, apple: true), 52.4);
    expect(healthHrvExportValue(b, apple: false), 96.0);
    // A bundle derived before sdnn_window: its stored SDNN index.
    (b['scalars'] as Map).remove('sdnn_window');
    expect(healthHrvExportValue(b, apple: true), 55.0);
    b.remove('clinical');
    expect(healthHrvExportValue(b, apple: true), isNull);
  });
}
