// NOOP stamps RR beats with whole seconds, so beats sharing a second are the
// normal case. Their arrival order is the strap's detection order; the
// time-sort that builds the Substrate must keep it rather than reshuffle it.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/import/noop_ingest.dart';

void main() {
  test('beats sharing a second keep their arrival order', () {
    // Long enough that List.sort leaves insertion sort for quicksort.
    final rrTs = <double>[];
    for (var s = 0; s < 500; s++) {
      rrTs
        ..add(s * 1000.0)
        ..add(s * 1000.0);
    }
    expect(NoopIngest.rrOrder(rrTs), List<int>.generate(rrTs.length, (i) => i));
  });

  test('out-of-order seconds are still sorted, ties stay in arrival order', () {
    final rrTs = <double>[2000, 1000, 2000, 1000, 0];
    expect(NoopIngest.rrOrder(rrTs), [4, 1, 3, 0, 2]);
  });
}
