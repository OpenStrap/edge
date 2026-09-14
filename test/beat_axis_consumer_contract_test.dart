// The contract edge owes analytics: the beat axis it hands over ascends.
//
// `cardioStager` binary-searches `rrTsMs` and asserts it is non-decreasing.
// Its own comment claims "the producer guarantees it — beats inherit their
// record's second and the records are sorted", and that guarantee stopped
// being true the day edge started placing beats at their MODELLED sub-second
// position instead of the record's whole second. One overlapping pair took
// the whole night's staging down.
//
// So this drives the real entry point rather than re-asserting our own array:
// a unit test on `Substrate.rrTsMs` alone cannot notice if analytics tightens
// what it needs. Note the assert is compiled out in release — under
// `flutter test` it is live, which is exactly why this test can see it.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart';
import 'package:openstrap_edge/compute/derive_prepare.dart';
import 'package:openstrap_edge/compute/substrate.dart';

const _t0 = 1788786610;

Map<String, dynamic> _frame(int recTs) => {
  'rec_ts': recTs,
  'hr': 58,
  'ax': 0.0,
  'ay': 0.0,
  'az': 1.0,
  'device_family': 'gen5',
};

/// A window of records whose sub-second anchors drift the way a real 32 kHz
/// RTC does — and therefore overlap at the seams, since each record's beats
/// are walked BACKWARDS from its own anchor.
({List<Map<String, dynamic>> frames, List<Map<String, dynamic>> beats}) _night(
  int seconds,
) {
  final frames = <Map<String, dynamic>>[];
  final beats = <Map<String, dynamic>>[];
  for (var s = 0; s < seconds; s++) {
    final recTs = _t0 + s;
    frames.add(_frame(recTs));
    // Anchor drift that wraps — at the wrap the next record's first beat lands
    // BEFORE this record's last, which is the real defect.
    final anchorMs = recTs * 1000 + (s * 37) % 1000;
    final rrLate = 900 + (s % 5) * 10;
    final rrEarly = 920 + (s % 3) * 10;
    beats.add({
      'rec_ts': recTs,
      'beat_index': 0,
      'rr_ts_ms': recTs * 1000,
      'rr_ms': rrEarly,
      'beat_ts_ms': anchorMs - rrLate,
    });
    beats.add({
      'rec_ts': recTs,
      'beat_index': 1,
      'rr_ts_ms': recTs * 1000,
      'rr_ms': rrLate,
      'beat_ts_ms': anchorMs,
    });
  }
  return (frames: frames, beats: beats);
}

void main() {
  test('the fixture really does invert — otherwise this test proves nothing',
      () {
    final n = _night(120);
    // The raw modelled placements, before any repair.
    final raw = [
      for (final b in n.beats) (b['beat_ts_ms'] as int).toDouble(),
    ];
    var inversions = 0;
    for (var i = 1; i < raw.length; i++) {
      if (raw[i] < raw[i - 1]) inversions++;
    }
    expect(inversions, greaterThan(0),
        reason: 'the anchor drift must actually wrap within the window');
  });

  test('the substrate edge builds satisfies analytics without throwing', () {
    final n = _night(120);
    final sub = substrateFromDecodedPage(n.frames, n.beats);

    // Pre-condition, stated the way analytics states it.
    for (var i = 1; i < sub.rrTsMs.length; i++) {
      expect(sub.rrTsMs[i], greaterThanOrEqualTo(sub.rrTsMs[i - 1]));
    }

    // The real consumer. This threw `Bad state: … rrTsMs must be
    // non-decreasing` before the repair.
    final accel = [
      for (var i = 0; i < sub.tsSec.length; i++)
        AccelSample(sub.tsSec[i] * 1000.0, 0.0, 0.0, 1.0),
    ];
    final hr = [for (final v in sub.hr) v.toDouble()];

    expect(
      () => cardioStager(hr, accel, rrMs: sub.rrMs, rrTsMs: sub.rrTsMs),
      returnsNormally,
    );
  });

  test('a tied axis is accepted too — the staircase fallback produces one', () {
    // Every beat of a record on one millisecond: what `rr_ts_ms` gives when
    // `beat_ts_ms` is NULL. Ties are not inversions and must not be "repaired"
    // into something else.
    final ts = <double>[1000, 1000, 1000, 2000, 2000];
    final before = [...ts];
    monotonizeBeatAxis(ts);
    expect(ts, before, reason: 'ties are already non-decreasing');
  });

  test('the clamp moves only the offending beat, by only what it must', () {
    final ts = <double>[0, 900, 100, 1000];
    monotonizeBeatAxis(ts);
    expect(ts, [0, 900, 900, 1000]);
  });
}
