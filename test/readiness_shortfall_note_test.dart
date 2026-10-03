// readinessInputShortfallNote translates the composite's `need_inputs:`
// refusal (at least one input usable, but too few of them / too little
// combined weight — readiness_composite.dart) into a genuine, human reason
// instead of the raw machine note.
//
// Before this existed, readiness_detail.dart's absence card had no translator
// for this convention (only `need_baseline:` was handled), so it fell through
// to rendering the raw note verbatim — a string like
// "need_inputs:have=1,need=2,weight=0.4,need_weight=0.5 — renormalising this
// few would hand the whole score to one input. Refused: temp:
// unsettled_skin_temp:settled=0.666717,need=0.8." shown directly to the user.
// Reported live: 15 nights worn, HRV crossed the 14-night baseline floor but
// RHR (11 nights) and breathing rate (13 nights) had not yet, and skin temp's
// settled fraction (66.7%) was short of the 80% floor — readiness correctly
// refused to score, but the screen could not say why in words.
//
// Deliberately names no input: the per-input "X of Y nights" rows this
// sentence sits above already say which one, by name, with its own count
// (readiness_detail.dart's absence card) — this is only the overall answer,
// so a user report that it said the same thing twice on one screen doesn't
// happen again.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';

Map<String, dynamic> _diag({
  int hrv = readinessCompositeMinBaseline,
  int rhr = readinessCompositeMinBaseline,
  int resp = readinessCompositeMinBaseline,
  double? tempSettledFrac,
}) =>
    {
      'hrv': {'value': true, 'baseline_n': hrv},
      'rhr': {'value': true, 'baseline_n': rhr},
      'resp': {'value': true, 'baseline_n': resp},
      'temp': {
        'value': true,
        'baseline_n': readinessCompositeMinBaseline,
        'settled_frac': tempSettledFrac,
      },
    };

void main() {
  test('null diag: null, same as every other unrecognised case', () {
    expect(readinessInputShortfallNote(null), isNull);
  });

  test('everything clears its floor: nothing to explain', () {
    expect(
      readinessInputShortfallNote(_diag(tempSettledFrac: 0.95)),
      isNull,
    );
  });

  test('reports the WORST baseline shortfall, not the first one found', () {
    // RHR (11 of 14, short by 3) is further from ready than breathing rate
    // (13 of 14, short by 1) — the actual bottleneck is RHR's count, 3, even
    // though no input is named in the sentence itself.
    final note = readinessInputShortfallNote(
      _diag(rhr: 11, resp: 13, tempSettledFrac: 0.95),
    );
    expect(note, 'Needs 3 more nights before readiness can score.');
  });

  test('singular night is grammatically correct', () {
    final note = readinessInputShortfallNote(_diag(resp: 13));
    expect(note, 'Needs 1 more night before readiness can score.');
  });

  test(
      'a baseline shortfall takes precedence over an ALSO-unsettled temp — '
      'no compound sentence, the night count alone is the overall answer',
      () {
    final note = readinessInputShortfallNote(
      _diag(rhr: 11, tempSettledFrac: 0.666717),
    );
    expect(note, 'Needs 3 more nights before readiness can score.');
  });

  test(
      'temp unsettled with every OTHER input already past 14 nights: a '
      'generic quality message, with NO night count (the settled-fraction '
      'gate is a quality threshold, not an elapsed-time one — promising a '
      'day count here would be the exact fabrication this function exists '
      'to avoid)', () {
    final note =
        readinessInputShortfallNote(_diag(tempSettledFrac: 0.666717));
    expect(note, 'Needs more consistently measured nights before readiness '
        'can score.');
    expect(note, isNot(matches(RegExp(r'\d'))),
        reason: 'no fabricated day-count ETA');
  });

  test('a settled-enough temp is not mentioned at all', () {
    expect(
      readinessInputShortfallNote(_diag(rhr: 11, tempSettledFrac: 0.95)),
      'Needs 3 more nights before readiness can score.',
    );
  });

  test('a missing baseline_n is treated as zero history, not a crash', () {
    final diag = {
      'hrv': <String, dynamic>{'value': false},
      'rhr': {'value': true, 'baseline_n': readinessCompositeMinBaseline},
      'resp': {'value': true, 'baseline_n': readinessCompositeMinBaseline},
      'temp': {'value': true, 'baseline_n': readinessCompositeMinBaseline},
    };
    expect(
      readinessInputShortfallNote(diag),
      'Needs $readinessCompositeMinBaseline more nights before readiness '
      'can score.',
    );
  });

  test(
      'metricName swaps the noun for Home\'s "Recovery" ring without '
      'touching the number — same diagnostic, same count, only the label '
      'differs between the ring and the Readiness detail screen', () {
    final diag = _diag(rhr: 11);
    expect(
      readinessInputShortfallNote(diag),
      'Needs 3 more nights before readiness can score.',
      reason: 'default stays "readiness", matching the detail screen',
    );
    expect(
      readinessInputShortfallNote(diag, metricName: 'recovery'),
      'Needs 3 more nights before recovery can score.',
    );
  });

  test('metricName also swaps the noun in the temp-only, no-count case', () {
    expect(
      readinessInputShortfallNote(
        _diag(tempSettledFrac: 0.666717),
        metricName: 'recovery',
      ),
      'Needs more consistently measured nights before recovery can score.',
    );
  });
}
