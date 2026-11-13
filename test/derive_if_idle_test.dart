// The automatic VACUUM runs through DerivationEngine.ifIdle: never while a
// derive (and the archive replay inside it) holds the latch, and skipped
// rather than queued when one does.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';

void main() {
  test('skips while a pass holds the latch, runs once it is free', () async {
    expect(await DerivationEngine.acquireForReset(), isTrue);
    var ran = false;
    try {
      final r = await DerivationEngine.ifIdle(-1, () async {
        ran = true;
        return 1;
      });
      expect(r, -1);
      expect(ran, isFalse);
    } finally {
      DerivationEngine.releaseForReset();
    }
    expect(
        await DerivationEngine.ifIdle(-1, () async {
          ran = true;
          // The latch is held while the body runs.
          expect(await DerivationEngine.ifIdle(-2, () async => 0), -2);
          return 1;
        }),
        1);
    expect(ran, isTrue);
  });
}
