// Unit tests for the pure window computation behind the BP research capture.
//
// The rules under test are the ones the storage and UI lean on:
//   · a window with no band data is NULL, not zeroes;
//   · a stat the window cannot honestly compute (no valid HR, too few
//     beats for RMSSD) is absent, never zero;
//   · rows outside the window are ignored, whatever their table's epoch
//     base is (decoded_onehz.rec_ts is SECONDS, decoded_rr.rr_ts_ms is ms).

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/health/bp_research_capture.dart';

void main() {
  const at = 1700000000000; // ms

  test('no band data in the window yields a NULL window, not zeroes', () {
    final w = researchWindowFrom(
      measuredAtMs: at,
      onehzRows: const [],
      rrRows: const [],
    );
    expect(w, isNull);
  });

  test('rows outside the ±2 min window are ignored (seconds vs ms bases)', () {
    final w = researchWindowFrom(
      measuredAtMs: at,
      onehzRows: [
        // rec_ts is epoch SECONDS. Inside the window (at/1000 ± 120).
        {'rec_ts': at ~/ 1000, 'hr': 60},
        // 10 minutes before: outside, must not land in any stat.
        {'rec_ts': at ~/ 1000 - 600, 'hr': 180},
      ],
      rrRows: [
        // rr_ts_ms is epoch MS. Inside.
        {'rr_ts_ms': at, 'rr_ms': 1000},
      ],
    );
    expect(w, isNotNull);
    expect(w!.onehzRows, 1);
    expect(w.hrMean, 60.0);
    expect(w.rrBeats, 1);
    expect(w.rmssdMs, isNull); // one beat forms no successive difference
  });

  test('invalid HR rows do not drag the mean toward zero', () {
    final w = researchWindowFrom(
      measuredAtMs: at,
      onehzRows: [
        {'rec_ts': at ~/ 1000, 'hr': 0},
        {'rec_ts': at ~/ 1000 - 1, 'hr': 58},
        {'rec_ts': at ~/ 1000 - 2, 'hr': 62},
      ],
      rrRows: const [],
    );
    expect(w!.onehzRows, 3);
    expect(w.hrMean, 60.0); // 0 excluded as invalid, not averaged in
  });

  test('RMSSD over successive differences, min/max preserved', () {
    final w = researchWindowFrom(
      measuredAtMs: at,
      onehzRows: const [],
      rrRows: [
        {'rr_ts_ms': at - 3000, 'rr_ms': 1000},
        {'rr_ts_ms': at - 2000, 'rr_ms': 1100},
        {'rr_ts_ms': at - 1000, 'rr_ms': 900},
      ],
    );
    expect(w!.rrBeats, 3);
    expect(w.rrMsMin, 900.0);
    expect(w.rrMsMax, 1100.0);
    // diffs: +100, -200 → sqrt((100² + 200²)/2) = sqrt(25000) = 158.11…
    expect(w.rmssdMs!, closeTo(158.11, 0.01));
    expect(w.hrMean, isNull); // no 1 Hz rows: absent, not zero
  });
}
