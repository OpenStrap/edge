// Bug: the rolling HRV timeline differenced straight down the compacted NN
// list, so the two beats either side of a recording gap or a dropped artifact
// run formed one large fake "successive difference" and the charted RMSSD
// spiked there.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';

void main() {
  test('no successive difference is taken across a hole in the beats', () {
    // 12 min of beats alternating 970/1030 ms (every diff = 60 ms), with a
    // 3-min hole at the 6-min mark after which the beats sit at 1300 ms.
    final nn = <double>[];
    final ts = <double>[];
    var t = 0.0;
    var k = 0;
    void beats(double base, double untilMs) {
      while (t < untilMs) {
        final rr = base + (k.isEven ? -30.0 : 30.0);
        t += rr;
        nn.add(rr);
        ts.add(t);
        k++;
      }
    }

    beats(1000, 6 * 60000);
    t += 3 * 60000; // strap off: clock advances, no beats
    beats(1300, 16 * 60000);

    final tl = rollingHrvTimeline(nn, ts, 1780000000000.0);
    expect(tl, isNotEmpty);
    for (final p in tl) {
      expect(p['v'], closeTo(60.0, 0.05), reason: 'point at t=${p['t']}');
    }
  });
}
