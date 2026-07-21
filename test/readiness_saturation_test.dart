// Regression tests for the READINESS ring BOUNCING to ~100 and back (#117, the
// ready→ready case).
//
// Root cause: the composite maps its weighted robust-z to a 0–100 score via a
// logistic `score = 100 / (1 + exp(-z))`. `robustZ` (analytics util) only nulls
// on EXACT-zero MAD; a near-degenerate baseline (e.g. duplicate-day pollution
// collapsing the window toward one value) has a tiny NON-zero MAD, so robustZ
// returns a huge z, the logistic saturates, and today's headline flashes ~100
// until a cleaner re-derive snaps it back — a ready→ready bounce the
// `overnight_state == 'ready'` gate can't catch (the state is `ready` throughout).
//
// The fix (`headlineReadinessScalar` / `kReadinessZCap`) abstains from a
// saturated, physiologically-impossible readiness rather than persisting the
// bogus ~100, so no wrong value is ever headlined on any surface. These tests pin
// the saturation → abstain behaviour and prove a clean derive is unaffected.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';

void main() {
  // A near-constant but strictly-increasing baseline: tiny NON-zero MAD, exactly
  // the shape duplicate-day pollution produces (not the exact-zero-MAD blank).
  final degenerate = [for (var i = 0; i < 28; i++) 60.0 + i * 0.001];
  // A healthy, well-spread baseline: a real robust-z, well within the cap.
  final clean = [for (var i = 0; i < 28; i++) 50.0 + i.toDouble()];

  group('headlineReadinessScalar', () {
    test('a near-degenerate baseline saturates the logistic → abstained', () {
      final sat = readinessComposite([hrvInput(61.0, degenerate)]);
      // The bug precondition: it computes, and it saturates the rail.
      expect(sat.present, isTrue);
      expect(sat.value!.score, greaterThan(99),
          reason: 'tiny-MAD baseline → huge z → logistic pinned near 100');
      expect(sat.value!.compositeZ.abs(), greaterThan(kReadinessZCap));
      // The guard withholds it instead of headlining ~100.
      expect(headlineReadinessScalar(sat), isNull);
    });

    test('a clean baseline yields a real score, surfaced unchanged', () {
      final ok = readinessComposite([hrvInput(70.0, clean)]);
      expect(ok.present, isTrue);
      expect(ok.value!.compositeZ.abs(), lessThanOrEqualTo(kReadinessZCap));
      final score = headlineReadinessScalar(ok);
      expect(score, isNotNull);
      expect(score, closeTo(ok.value!.score, 1e-9),
          reason: 'a legitimate score passes through untouched');
      expect(score!, lessThan(95),
          reason: 'a real composite never approaches the saturated rail');
    });

    test('ready→ready bounce: the headline never takes the saturated value', () {
      final sat = readinessComposite([hrvInput(61.0, degenerate)]);
      final ok = readinessComposite([hrvInput(70.0, clean)]);
      // Two consecutive re-derives of the SAME already-`ready` day: a saturated
      // pass then a clean pass. What the ring would headline for each:
      final surfaced = [sat, ok].map(headlineReadinessScalar).toList();
      expect(surfaced.first, isNull, reason: 'saturated derive → no number');
      expect(surfaced.last, isNotNull, reason: 'clean derive → the real score');
      // The saturated ~100 is never surfaced (no bounce to a bogus green 100).
      expect(surfaced.contains(sat.value!.score), isFalse);
      expect(surfaced.whereType<double>().every((v) => v < 95), isTrue);
    });

    test('exact-zero MAD stays the honest blank path (unchanged)', () {
      // Fully-quantised baseline → robustZ null → composite absent → '—', not 100.
      final flat = readinessComposite([hrvInput(61.0, List.filled(28, 60.0))]);
      expect(flat.present, isFalse);
      expect(headlineReadinessScalar(flat), isNull);
    });
  });
}
