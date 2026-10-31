// Bug: the night's breathing rate (`rsaRespRate` over the corrected sleep NN)
// is withheld when more than 30% of beats needed correction, but the per-window
// rates feeding breathing-rate variability were computed from the same
// corrected NN with `artifactFraction: 0.0` hard-coded. On a loose-strap night
// the screen showed resp_rate as "—" and still published brv_cv/brv_slope
// directly underneath it, built from interpolated beats.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';

void main() {
  // 3 h of beats at ~60 bpm with a clean 15 br/min (0.25 Hz) RSA modulation.
  (List<double>, List<double>) rsaNight() {
    final nn = <double>[];
    final ts = <double>[];
    var t = 1780000000000.0;
    while (t < 1780000000000.0 + 3 * 3600 * 1000) {
      final rr = 1000.0 + 60.0 * math.sin(2 * math.pi * 0.25 * t / 1000.0);
      t += rr;
      nn.add(rr);
      ts.add(t);
    }
    return (nn, ts);
  }

  test('windows resolve on a clean night', () {
    final (nn, ts) = rsaNight();
    final clean = respPerWindow(nn, ts, artifactFraction: 0.0);
    expect(clean.length, greaterThanOrEqualTo(3));
    // Below the gate the fraction only moves confidence, never the rate.
    expect(respPerWindow(nn, ts, artifactFraction: 0.10), clean);
  });

  test('windows carry the night-level artifact gate', () {
    final (nn, ts) = rsaNight();
    expect(respPerWindow(nn, ts, artifactFraction: 0.38), isEmpty);
  });
}
