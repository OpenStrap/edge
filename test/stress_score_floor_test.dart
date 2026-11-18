// #631: the Baevsky SI → 0-100 stress score clamped every genuinely low night
// to a flat 0, because the scale floor sat at SI 20 while Baevsky's own "low"
// band is SI < 50. High-HRV sleepers (nightly SI ~10-14) saw 0 on every night,
// which reads as "no data" rather than "low". The floor is now 5, so the low
// end varies again. This pins the mapping, which the live derive and the
// one-shot history rescale both call.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart'
    show stressScoreFromSi, kStressScoreFloorSi, kStressScoreCeilingSi;

void main() {
  group('stressScoreFromSi', () {
    test('no usable index is absence, never 0', () {
      expect(stressScoreFromSi(null), isNull);
      expect(stressScoreFromSi(0), isNull);
      expect(stressScoreFromSi(-1), isNull);
      expect(stressScoreFromSi(double.nan), isNull);
      expect(stressScoreFromSi(double.infinity), isNull);
    });

    test('the floor is 0 and the ceiling is 100', () {
      expect(stressScoreFromSi(kStressScoreFloorSi), 0.0);
      expect(stressScoreFromSi(kStressScoreCeilingSi), 100.0);
      expect(stressScoreFromSi(kStressScoreCeilingSi * 2), 100.0); // clamped
      expect(stressScoreFromSi(kStressScoreFloorSi / 2), 0.0); // clamped
    });

    test('genuinely low nights no longer flatten to 0 (the #631 symptom)', () {
      // Under the old floor of 20 every one of these was exactly 0.
      for (final si in const [10.0, 12.0, 14.0, 18.0]) {
        expect(stressScoreFromSi(si), greaterThan(0.0),
            reason: 'SI $si used to clamp to 0');
      }
      expect(stressScoreFromSi(10), closeTo(14.5, 0.6));
      expect(stressScoreFromSi(20), closeTo(29.0, 0.6));
    });

    test('monotonic in the index', () {
      double last = -1;
      for (final si in const [5.0, 10.0, 20.0, 50.0, 150.0, 600.0]) {
        final s = stressScoreFromSi(si)!;
        expect(s, greaterThanOrEqualTo(last));
        last = s;
      }
    });
  });
}
