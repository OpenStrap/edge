// Issue #206: a live session's strain is accumulated in RAM by the foreground
// app. Backgrounded (iOS suspends the 1 Hz timer) or killed mid-workout, that
// accumulator misses most of the workout — commonly leaving a handful of
// sub-resting minutes whose Banister TRIMP is exactly 0, which `strainScore`
// reports as a confident 0.0 next to a real duration and real HR.
//
// `reconcileSessionScore` merges that partial tally with a re-score of the same
// window from the 1 Hz substrate the band banked. These tests pin the merge
// rule (max, because both sides are lower bounds over subsets of one window's
// minutes) and the properties that make repeated application safe.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/manual_session.dart';

ManualSessionStats _substrate({
  double? strain,
  double? calories,
  int? maxHr,
  List<double> zone = const [],
  int samples = 1800,
}) => ManualSessionStats(
  strain: strain,
  calories: calories,
  maxHr: maxHr,
  zoneMinutes: zone,
  hrSampleCount: samples,
);

void main() {
  test('a 0.0 live tally is replaced by the substrate score', () {
    final r = reconcileSessionScore(
      liveStrain: 0.0, // the app was awake only for sub-resting minutes
      liveCalories: 3.0,
      liveMaxHr: 71,
      liveZoneMinutes: const [2, 0, 0, 0, 0],
      substrate: _substrate(
        strain: 11.4,
        calories: 480,
        maxHr: 168,
        zone: const [4, 12, 20, 9, 1],
      ),
    );
    expect(r.strain, 11.4);
    expect(r.calories, 480);
    expect(r.maxHr, 168);
    expect(r.zoneMinutes, const [4, 12, 20, 9, 1]);
    expect(r.changed, isTrue);
  });

  test('an empty substrate leaves the live tally untouched', () {
    // Right after a workout the band has not offloaded the window yet. The live
    // tally is all the evidence there is — it must not be wiped to null.
    final r = reconcileSessionScore(
      liveStrain: 8.2,
      liveCalories: 300,
      liveMaxHr: 160,
      liveZoneMinutes: const [1, 2, 3, 0, 0],
      substrate: _substrate(samples: 0),
    );
    expect(r.strain, 8.2);
    expect(r.calories, 300);
    expect(r.maxHr, 160);
    expect(r.zoneMinutes, const [1, 2, 3, 0, 0]);
    expect(r.changed, isFalse, reason: 'nothing improved — no write');
  });

  test('a partially drained window never LOWERS a better live tally', () {
    // The band has offloaded only the first few minutes so far.
    final r = reconcileSessionScore(
      liveStrain: 9.0,
      liveCalories: 400,
      liveMaxHr: 171,
      liveZoneMinutes: const [1, 5, 10, 4, 0],
      substrate: _substrate(
        strain: 2.1,
        calories: 90,
        maxHr: 140,
        zone: const [1, 2, 0, 0, 0],
        samples: 300,
      ),
    );
    expect(r.strain, 9.0);
    expect(r.calories, 400);
    expect(r.maxHr, 171);
    expect(r.zoneMinutes, const [1, 5, 10, 4, 0]);
    expect(r.changed, isFalse);
  });

  test('absent stays absent — an unscored session never becomes 0.0', () {
    final r = reconcileSessionScore(
      liveStrain: null, // no profile anchor, so nothing was ever scored
      liveCalories: null,
      liveMaxHr: null,
      liveZoneMinutes: const [],
      substrate: _substrate(strain: null, calories: null, maxHr: 150),
    );
    expect(r.strain, isNull);
    expect(r.calories, isNull);
    expect(r.maxHr, 150, reason: 'max HR is measurable without a profile');
  });

  test('a null live strain is filled from the substrate', () {
    final r = reconcileSessionScore(
      liveStrain: null,
      liveCalories: null,
      liveMaxHr: null,
      liveZoneMinutes: const [],
      substrate: _substrate(strain: 6.5, calories: 210, maxHr: 155),
    );
    expect(r.strain, 6.5);
    expect(r.calories, 210);
    expect(r.changed, isTrue);
  });

  test('a genuinely zero-load window stays 0.0 rather than being hidden', () {
    // Sitting still for 30 minutes and calling it a workout IS zero strain.
    // The fix must not turn every real zero into an absence.
    final r = reconcileSessionScore(
      liveStrain: 0.0,
      liveCalories: 0.0,
      liveMaxHr: 68,
      liveZoneMinutes: const [],
      substrate: _substrate(strain: 0.0, calories: 0.0, maxHr: 68),
    );
    expect(r.strain, 0.0);
    expect(r.changed, isFalse);
  });

  test('repeated application converges — the merge is monotone', () {
    // Each pass sees more of the drained window; the value only ever rises and
    // re-running on an already-merged row is a no-op.
    var strain = 0.0;
    for (final partial in [1.0, 4.4, 7.9, 11.2, 11.2]) {
      final r = reconcileSessionScore(
        liveStrain: strain,
        liveCalories: null,
        liveMaxHr: null,
        liveZoneMinutes: const [],
        substrate: _substrate(strain: partial),
      );
      expect(r.strain! >= strain, isTrue, reason: 'never regresses');
      strain = r.strain!;
    }
    expect(strain, 11.2);

    final again = reconcileSessionScore(
      liveStrain: strain,
      liveCalories: null,
      liveMaxHr: null,
      liveZoneMinutes: const [],
      substrate: _substrate(strain: 11.2),
    );
    expect(again.changed, isFalse, reason: 'converged — stops writing');
  });

  test('a complete substrate REPLACES the tally rather than maxing it', () {
    // The max rule is only monotone while the scoring function is fixed, and it
    // is not — strain depends on the trailing nightly resting HR, which moves.
    // Maxing forever would ratchet a session up to the highest value any RHR
    // the profile ever reported would have produced, with no way back down.
    final r = reconcileSessionScore(
      liveStrain: 14.0, // scored earlier against a lower resting HR
      liveCalories: 700,
      liveMaxHr: 190,
      liveZoneMinutes: const [0, 0, 30, 0, 0],
      substrate: _substrate(
        strain: 11.4,
        calories: 480,
        maxHr: 168,
        zone: const [4, 12, 20, 9, 1],
      ),
      substrateIsComplete: true,
    );
    expect(r.strain, 11.4, reason: 'current anchors, not the historic peak');
    expect(r.calories, 480);
    expect(r.maxHr, 168);
    expect(r.zoneMinutes, const [4, 12, 20, 9, 1]);
    expect(r.changed, isTrue);
  });

  test('completeness does not invent values the substrate lacks', () {
    final r = reconcileSessionScore(
      liveStrain: 9.0,
      liveCalories: 250,
      liveMaxHr: 170,
      liveZoneMinutes: const [1, 2, 0, 0, 0],
      // Zone minutes need a HRmax the profile may not carry, so an empty
      // vector alongside complete coverage is a real case — and must not wipe
      // the split that was already stored.
      substrate: _substrate(
        strain: null,
        calories: null,
        maxHr: null,
        zone: const [],
      ),
      substrateIsComplete: true,
    );
    expect(r.strain, 9.0, reason: 'no profile anchor ⇒ nothing to replace with');
    expect(r.calories, 250);
    expect(r.maxHr, 170);
    expect(r.zoneMinutes, const [1, 2, 0, 0, 0]);
  });

  test('zone minutes come from one source, never element-wise mixed', () {
    // A per-element max would invent a total neither source observed.
    final r = reconcileSessionScore(
      liveStrain: null,
      liveCalories: null,
      liveMaxHr: null,
      liveZoneMinutes: const [10, 0, 0, 0, 0], // 10 min total
      substrate: _substrate(zone: const [0, 3, 9, 2, 0]), // 14 min total
    );
    expect(r.zoneMinutes, const [0, 3, 9, 2, 0]);
    expect(r.zoneMinutes.fold<double>(0, (a, b) => a + b), 14);
  });
}
