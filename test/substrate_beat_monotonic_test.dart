// The beat time axis handed to analytics must be non-decreasing.
//
// `beat_ts_ms` places each beat where the strap's sub-second anchor says it
// was: the anchor is the record's END and the intervals are walked BACKWARDS
// from it. Two adjacent records whose anchors drift apart by less than one
// beat therefore overlap — record N+1's beat 0 lands a few hundred ms BEFORE
// record N's last beat — and `_PrepareAccumulator` emitted the pair in record
// order, so the axis stepped backwards.
//
// Analytics binary-searches the beat window and asserts the axis is
// non-decreasing, so every such day threw out of the sleep-staging isolate and
// derived nothing. Observed on a real install: 94 inversions across 39,066
// beats in one day, every one of them at `beat_index = 0`, by 7-672 ms.
//
// The repair is a CLAMP, not a sort. Beats arrive in the order the strap
// detected them and that order is the rhythm — `beat_clock_read_path_test`
// pins it — so it is the reconstructed placement that gets corrected, by the
// least it can be, and never the interval series.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derive_prepare.dart';

const _t0 = 1788786610;

Map<String, dynamic> _frame(int recTs) => {
  'rec_ts': recTs,
  'hr': 60,
  'ax': 0.0,
  'ay': 0.0,
  'az': 1.0,
  'device_family': 'gen5',
};

Map<String, dynamic> _beat(int recTs, int index, int rrMs, int beatTsMs) => {
  'rec_ts': recTs,
  'beat_index': index,
  'rr_ts_ms': recTs * 1000,
  'rr_ms': rrMs,
  'beat_ts_ms': beatTsMs,
};

void main() {
  test('overlapping record anchors do not step the beat axis backwards', () {
    // Record 0's last beat sits at .969; record 1's anchor drifted earlier, so
    // its first beat lands at .961 — 8 ms BEFORE it. Exactly the shape seen on
    // the wire (rec_ts 1788786611, beat 0, delta -8 ms).
    final frames = [_frame(_t0), _frame(_t0 + 1)];
    final beats = [
      _beat(_t0, 0, 900, _t0 * 1000 + 69),
      _beat(_t0, 1, 900, _t0 * 1000 + 969),
      _beat(_t0 + 1, 0, 935, _t0 * 1000 + 961),
      _beat(_t0 + 1, 1, 900, _t0 * 1000 + 1861),
    ];

    final sub = substrateFromDecodedPage(frames, beats);

    expect(sub.rrTsMs.length, 4);
    for (var i = 1; i < sub.rrTsMs.length; i++) {
      expect(
        sub.rrTsMs[i],
        greaterThanOrEqualTo(sub.rrTsMs[i - 1]),
        reason: 'beat axis stepped backwards at $i: ${sub.rrTsMs}',
      );
    }
    // The overlapping beat is HELD at its predecessor, not moved past it, and
    // every other beat keeps the placement the strap measured.
    expect(sub.rrTsMs, [
      _t0 * 1000 + 69,
      _t0 * 1000 + 969,
      _t0 * 1000 + 969,
      _t0 * 1000 + 1861,
    ]);
    // The interval series is untouched — same values, SAME ORDER.
    expect(sub.rrMs, [900, 900, 935, 900]);
  });

  test('an already-ordered page keeps its exact emission order', () {
    final frames = [_frame(_t0), _frame(_t0 + 1)];
    final beats = [
      _beat(_t0, 0, 900, _t0 * 1000 + 69),
      _beat(_t0, 1, 901, _t0 * 1000 + 969),
      _beat(_t0 + 1, 0, 902, _t0 * 1000 + 1069),
      _beat(_t0 + 1, 1, 903, _t0 * 1000 + 1969),
    ];

    final sub = substrateFromDecodedPage(frames, beats);

    expect(sub.rrMs, [900, 901, 902, 903]);
  });

  test('beats sharing one timestamp keep their emission order', () {
    // The staircase fallback (`rr_ts_ms`, whole seconds) puts every beat in a
    // record on one millisecond. Ties must not be reshuffled — the interval
    // series is the physiological signal and its order is the rhythm.
    final frames = [_frame(_t0)];
    final beats = [
      {'rec_ts': _t0, 'beat_index': 0, 'rr_ts_ms': _t0 * 1000, 'rr_ms': 811},
      {'rec_ts': _t0, 'beat_index': 1, 'rr_ts_ms': _t0 * 1000, 'rr_ms': 822},
      {'rec_ts': _t0, 'beat_index': 2, 'rr_ts_ms': _t0 * 1000, 'rr_ms': 833},
    ];

    final sub = substrateFromDecodedPage(frames, beats);

    expect(sub.rrMs, [811, 822, 833]);
  });
}
