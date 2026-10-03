// readinessUnstableBaselineNote covers the absence shape
// readinessInputShortfallNote cannot: a z-cap withhold (zCapAbsentNote in
// onehz_pipeline.dart) — the composite actually computed, every input
// already cleared its own baseline floor, but the result was a saturated,
// degenerate-baseline artefact and got withheld.
//
// Flagged on PR #510: callers that only tried readinessInputShortfallNote
// fell straight to the generic "nothing recorded says why" for this case,
// losing a reason the screen used to show (as the raw, unreadable
// `unstable_baseline:z=...,cap=...` note) before this existed.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';

void main() {
  test('null note: null, the honest floor for anything unrecognised', () {
    expect(readinessUnstableBaselineNote(null), isNull);
  });

  test('an unrelated machine note is not mistaken for this one', () {
    expect(
      readinessUnstableBaselineNote(
          'need_inputs:have=1,need=2,weight=0.4,need_weight=0.5'),
      isNull,
    );
  });

  test('recognises the real zCapAbsentNote shape, raw z/cap never leaked',
      () {
    final note =
        readinessUnstableBaselineNote('unstable_baseline:z=5.823,cap=5.0');
    expect(note, isNotNull);
    expect(note, isNot(contains('5.823')),
        reason: 'a raw z-score is not something a reader can act on');
    expect(note, isNot(contains('unstable_baseline')),
        reason: 'no leaked machine note, same as every other translator here');
  });

  test('metricName swaps the noun, same as readinessInputShortfallNote', () {
    expect(
      readinessUnstableBaselineNote('unstable_baseline:z=5.823,cap=5.0'),
      contains('readiness'),
    );
    expect(
      readinessUnstableBaselineNote('unstable_baseline:z=5.823,cap=5.0',
          metricName: 'recovery'),
      contains('recovery'),
    );
  });
}
