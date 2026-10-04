// Pure window computation behind the BP research capture.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/health/bp_research_capture.dart';

void main() {
  const at = 1700000000000; // ms
  // The default rest window: [at − 5 min, at).
  const preStart = at - 5 * 60 * 1000;

  test('no band data in the window yields a NULL window, not zeroes', () {
    final w = researchWindowFrom(
      measuredAtMs: at,
      onehzRows: const [],
      rrRows: const [],
    );
    expect(w, isNull);
  });

  test('the rest window lies BEFORE the measurement, inflation excluded', () {
    final w = researchWindowFrom(
      measuredAtMs: at,
      onehzRows: [
        // Inside the rest window (seconds base).
        {'rec_ts': preStart ~/ 1000 + 60, 'hr': 60},
        // The measurement instant itself (the half-open end) and AFTER it:
        // the cuff inflating. Outside the window — must not land in any stat.
        {'rec_ts': at ~/ 1000, 'hr': 180},
        {'rec_ts': at ~/ 1000 + 1, 'hr': 190},
      ],
      rrRows: const [],
    );
    expect(w, isNotNull);
    expect(w!.windowStartMs, preStart);
    expect(w.windowEndMs, at);
    expect(w.onehzRows, 1);
    expect(w.hrMean, 60.0);
  });

  test('rows outside the window are ignored (seconds vs ms bases)', () {
    final w = researchWindowFrom(
      measuredAtMs: at,
      onehzRows: [
        // rec_ts is epoch SECONDS. Inside the rest window.
        {'rec_ts': preStart ~/ 1000 + 10, 'hr': 60},
        // 10 minutes before the window: outside, must not land in any stat.
        {'rec_ts': preStart ~/ 1000 - 600, 'hr': 180},
      ],
      rrRows: [
        // rr_ts_ms is epoch MS. Inside.
        {'rr_ts_ms': preStart + 1000, 'rr_ms': 1000},
      ],
    );
    expect(w, isNotNull);
    expect(w!.onehzRows, 1);
    expect(w.hrMean, 60.0);
    expect(w.rrBeats, 1);
    expect(w.rmssdMs, isNull); // one beat forms no successive difference
  });

  test('unsorted rows are sorted; duplicate timestamps deduplicated', () {
    final w = researchWindowFrom(
      measuredAtMs: at,
      onehzRows: [
        {'rec_ts': preStart ~/ 1000 + 30, 'hr': 64},
        // Same second twice — one row, not two.
        {'rec_ts': preStart ~/ 1000 + 10, 'hr': 56},
        {'rec_ts': preStart ~/ 1000 + 10, 'hr': 56},
      ],
      rrRows: [
        {'rr_ts_ms': preStart + 3000, 'rr_ms': 900},
        // Same instant twice — one interval, not two.
        {'rr_ts_ms': preStart + 1000, 'rr_ms': 1000},
        {'rr_ts_ms': preStart + 1000, 'rr_ms': 1000},
      ],
    );
    expect(w!.onehzRows, 2);
    expect(w.rrBeats, 2);
    expect(w.hrMean, 60.0); // (56 + 64) / 2
  });

  test('beats of one record are NOT duplicates (beat identity)', () {
    // decoded_rr keys beats by (rec_ts, beat_index); rr_ts_ms alone is
    // rec_ts*1000 for EVERY beat of the record. Deduplicating by rr_ts_ms
    // would drop real beats and corrupt RMSSD.
    final w = researchWindowFrom(
      measuredAtMs: at,
      onehzRows: const [],
      rrRows: [
        // One record at rec_ts, four beats — same rr_ts_ms, different
        // beat_index.
        {'rr_ts_ms': preStart + 1000, 'beat_index': 0, 'rr_ms': 1000},
        {'rr_ts_ms': preStart + 1000, 'beat_index': 1, 'rr_ms': 1100},
        {'rr_ts_ms': preStart + 1000, 'beat_index': 2, 'rr_ms': 900},
        {'rr_ts_ms': preStart + 1000, 'beat_index': 3, 'rr_ms': 1050},
      ],
    );
    expect(w!.rrBeats, 4); // all four beats survive
    expect(w.validIntervalCount, 4);
    // All three successive pairs are usable (whole-second heuristic: the
    // beats of one second share a time, so the pairs count as contiguous).
    expect(w.validIntervalPairCount, 3);
    expect(w.rmssdMs, isNotNull);
  });

  test('beat_ts_ms is the beat identity when the decoder provides it', () {
    final w = researchWindowFrom(
      measuredAtMs: at,
      onehzRows: const [],
      rrRows: [
        // Same (rr_ts_ms, beat_index) twice but DIFFERENT measured beat
        // instants — two real beats, not a duplicate.
        {
          'rr_ts_ms': preStart + 1000,
          'beat_index': 0,
          'beat_ts_ms': preStart + 1000,
          'rr_ms': 1000,
        },
        {
          'rr_ts_ms': preStart + 1000,
          'beat_index': 0,
          'beat_ts_ms': preStart + 2000,
          'rr_ms': 1100,
        },
      ],
    );
    expect(w!.rrBeats, 2);
    // 1000 ms apart: contiguous, one RMSSD pair.
    expect(w.validIntervalPairCount, 1);
  });

  test('invalid HR rows do not drag the mean toward zero', () {
    final w = researchWindowFrom(
      measuredAtMs: at,
      onehzRows: [
        {'rec_ts': preStart ~/ 1000, 'hr': 0},
        {'rec_ts': preStart ~/ 1000 + 1, 'hr': 58},
        {'rec_ts': preStart ~/ 1000 + 2, 'hr': 62},
        // Non-finite junk: rejected outright.
        {'rec_ts': preStart ~/ 1000 + 3, 'hr': -5},
      ],
      rrRows: const [],
    );
    expect(w!.onehzRows, 4); // raw rows
    expect(w.validHrSeconds, 2); // valid seconds
    expect(w.hrMean, 60.0); // 0 and −5 excluded, not averaged in
  });

  test('coverage counts VALID seconds only; off-skin zeroes do not cover', () {
    // 300 raw rows, 200 of them hr = 0 (band off skin): coverage must be
    // 1/3, not 1.0 — an off-skin window must not escape the gappy verdict.
    final onehz = [
      for (var i = 0; i < 300; i++)
        {'rec_ts': preStart ~/ 1000 + i, 'hr': i < 200 ? 0 : 60},
    ];
    final w = researchWindowFrom(
      measuredAtMs: at,
      onehzRows: onehz,
      rrRows: const [],
    );
    expect(w!.onehzRows, 300);
    expect(w.validHrSeconds, 100);
    expect(w.coverageFraction, closeTo(1 / 3, 0.001));
    expect(w.qualityStatus, 'gappy');
  });

  test('observed bounds come from VALID rows, not raw rows', () {
    final w = researchWindowFrom(
      measuredAtMs: at,
      onehzRows: [
        // Invalid rows at the edges must not extend the observed signal.
        {'rec_ts': preStart ~/ 1000, 'hr': 0},
        {'rec_ts': preStart ~/ 1000 + 120, 'hr': 60},
        {'rec_ts': preStart ~/ 1000 + 180, 'hr': 62},
        {'rec_ts': preStart ~/ 1000 + 299, 'hr': 0},
      ],
      rrRows: const [],
    );
    expect(w!.observedStartMs, preStart + 120000);
    expect(w.observedEndMs, preStart + 180000);
  });

  test('RMSSD over successive differences, min/max preserved', () {
    final w = researchWindowFrom(
      measuredAtMs: at,
      onehzRows: const [],
      rrRows: [
        {'rr_ts_ms': preStart + 1000, 'rr_ms': 1000},
        {'rr_ts_ms': preStart + 2000, 'rr_ms': 1100},
        {'rr_ts_ms': preStart + 3000, 'rr_ms': 900},
      ],
    );
    expect(w!.rrBeats, 3);
    expect(w.rrMsMin, 900.0);
    expect(w.rrMsMax, 1100.0);
    // diffs: +100, −200 → sqrt((100² + 200²)/2) = sqrt(25000) = 158.11…
    expect(w.rmssdMs!, closeTo(158.11, 0.01));
    expect(w.validIntervalCount, 3);
    expect(w.validIntervalPairCount, 2);
    expect(w.hrMean, isNull); // no 1 Hz rows: absent, not zero
  });

  test(
    'RMSSD never spans a sensor gap; the pair-rejection fraction reports',
    () {
      final w = researchWindowFrom(
        measuredAtMs: at,
        onehzRows: const [],
        rrRows: [
          // A contiguous pair before the gap.
          {'rr_ts_ms': preStart + 1000, 'rr_ms': 1000},
          {'rr_ts_ms': preStart + 2000, 'rr_ms': 1100},
          // THE GAP: two minutes of nothing. The pair across it must not
          // enter RMSSD — a difference across a sensor gap is a fabricated
          // HRV sample, not a real one.
          {'rr_ts_ms': preStart + 140000, 'rr_ms': 800},
          // A contiguous pair after the gap.
          {'rr_ts_ms': preStart + 141000, 'rr_ms': 850},
        ],
      );
      expect(w!.rrBeats, 4);
      expect(w.validIntervalCount, 4);
      // Two of three successive pairs are contiguous; one spans the gap.
      expect(w.validIntervalPairCount, 2);
      // The metric is named for what it measures: the share of successive
      // PAIRS rejected — not an interval-exclusion rate.
      expect(w.rejectedIntervalFraction, closeTo(1 / 3, 0.001));
      // RMSSD over the two REAL pairs: diffs +100, −50 → sqrt((10000+2500)/2).
      expect(w.rmssdMs!, closeTo(math.sqrt(12500 / 2), 0.01));
      // One rejected pair of three is under the >50% threshold, and no 1 Hz
      // rows means coverage is NULL (absent) rather than low — so the honest
      // verdict is 'ok', with the rejected-pair fraction carried alongside.
      expect(w.qualityStatus, 'ok');
    },
  );

  test('a window whose end lies in the future is pending', () {
    // An internal, data-level state: the UI refuses future instants, so
    // it can never produce one — this pins the honest labelling for any
    // caller that still passes such a window.
    final w = researchWindowFrom(
      measuredAtMs: at,
      onehzRows: [
        {'rec_ts': preStart ~/ 1000, 'hr': 60},
      ],
      rrRows: const [],
      nowMs: at - 60000, // "now" is a minute before the measurement
    );
    expect(w!.qualityStatus, 'pending');
  });

  test('a well-covered window is ok; coverage is honest', () {
    // 300 valid seconds of a half-open 300-second window = coverage 1.0
    // exactly — never more, because the end instant itself is excluded.
    final onehz = [
      for (var i = 0; i < 300; i++) {'rec_ts': preStart ~/ 1000 + i, 'hr': 60},
    ];
    final w = researchWindowFrom(
      measuredAtMs: at,
      onehzRows: onehz,
      rrRows: const [],
    );
    expect(w!.qualityStatus, 'ok');
    expect(w.coverageFraction, closeTo(1.0, 0.001));
    expect(w.coverageFraction!, lessThanOrEqualTo(1.0));
    expect(w.validHrSeconds, 300);
    expect(w.featureVersion, kResearchFeatureVersion);
  });

  test('requested bounds and observed bounds are distinct', () {
    final w = researchWindowFrom(
      measuredAtMs: at,
      onehzRows: [
        {'rec_ts': preStart ~/ 1000 + 120, 'hr': 60},
        {'rec_ts': preStart ~/ 1000 + 180, 'hr': 62},
      ],
      rrRows: const [],
    );
    // Requested: the full 5 minutes. Observed: 60 s in the middle.
    expect(w!.windowStartMs, preStart);
    expect(w.windowEndMs, at);
    expect(w.observedStartMs, preStart + 120000);
    expect(w.observedEndMs, preStart + 180000);
    expect(w.coverageFraction, closeTo(2 / 300, 0.001));
  });

  test('a custom postMs window can include the measurement itself', () {
    final w = researchWindowFrom(
      measuredAtMs: at,
      onehzRows: [
        {'rec_ts': at ~/ 1000 + 30, 'hr': 70}, // after the instant: inside now
      ],
      rrRows: const [],
      postMs: 60000,
    );
    expect(w!.windowEndMs, at + 60000);
    expect(w.onehzRows, 1);
  });
  test('a window whose local data does not provably reach its end is '
      'pending (sync watermark), never a final verdict', () {
    // Full, perfectly valid data — but the watermark proves the band
    // has not synced up to the window END: the missing tail may still
    // arrive, so 'pending', NOT 'ok' (and never 'no_data'/'gappy').
    final rows = <Map<String, Object?>>[
      for (int s = 0; s < 300; s++) {'rec_ts': at ~/ 1000 - 300 + s, 'hr': 60},
    ];
    final w = researchWindowFrom(
      measuredAtMs: at,
      onehzRows: rows,
      rrRows: const [],
      dataThroughMs: at - 60000, // synced only to T-60s
    );
    expect(w, isNotNull);
    expect(w!.qualityStatus, 'pending');
    // The data itself is still frozen — pending is a VERDICT about
    // finality, not a rejection of the rows.
    expect(w.onehzRows, 300);
    // Once the watermark reaches the end, the SAME rows are final:
    final w2 = researchWindowFrom(
      measuredAtMs: at,
      onehzRows: rows,
      rrRows: const [],
      dataThroughMs: at,
    );
    expect(w2!.qualityStatus, 'ok');
  });

  test('pending outranks a would-be gappy classification (precedence)', () {
    // Half the coverage missing AND the watermark short: the missing
    // part may still arrive, so 'pending', not 'gappy'.
    final rows = <Map<String, Object?>>[
      for (int s = 0; s < 150; s++) {'rec_ts': at ~/ 1000 - 300 + s, 'hr': 60},
    ];
    final w = researchWindowFrom(
      measuredAtMs: at,
      onehzRows: rows,
      rrRows: const [],
      dataThroughMs: at - 150000,
    );
    expect(w!.qualityStatus, 'pending');
  });

  test('an invalid beat breaks the RMSSD chain instead of being skipped', () {
    final w = researchWindowFrom(
      measuredAtMs: at,
      onehzRows: const [],
      rrRows: [
        {'rr_ts_ms': at - 3000, 'beat_index': 0, 'rr_ms': 800},
        {'rr_ts_ms': at - 2000, 'beat_index': 0, 'rr_ms': 0},
        {'rr_ts_ms': at - 1000, 'beat_index': 0, 'rr_ms': 1000},
      ],
    )!;
    expect(w.validIntervalCount, 2);
    expect(w.validIntervalPairCount, isNull);
    expect(w.rmssdMs, isNull);
  });
}
