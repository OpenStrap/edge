// hrLedWindow (lib/compute/inputs/canonical.dart): the HR-led night off a
// sparse watch's or ring's HR. Each case is a record laid out segment by
// segment at the device's cadence; the window must open at sleep onset and
// close at the wake, whatever share of the record the night is.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/compute/inputs/pebble_inputs.dart';

const int _t0 = 1790000000 ~/ 300 * 300;

/// A record at [c] seconds per sample from [_t0]: each segment is (minutes,
/// bpm), bpm 0 being no samples at all (the watch off its wrist). Sleep
/// drifts down 4 bpm across its segment and every sample carries a +-1 bpm
/// wobble, so no threshold lands on a flat value.
({List<int> ts, List<int> hr}) _record(int c, List<(int, int)> segments) {
  final ts = <int>[], hr = <int>[];
  var t = _t0;
  for (final (min, bpm) in segments) {
    final n = min * 60 ~/ c;
    for (var i = 0; i < n; i++, t += c) {
      if (bpm == 0) continue;
      ts.add(t);
      hr.add(bpm + (bpm < 60 ? -(4 * i ~/ n) : 0) + (i % 3 - 1));
    }
  }
  return (ts: ts, hr: hr);
}

/// Seconds from [_t0] to the start of segment [k].
int _at(int c, List<(int, int)> segments, int k) =>
    _t0 + [for (final (m, _) in segments.take(k)) m * 60 ~/ c * c]
        .fold(0, (a, b) => a + b);

void _expectNight(int c, List<(int, int)> segments, int sleepSeg) {
  final r = _record(c, segments);
  final w = hrLedWindow(r.ts, r.hr, c);
  expect(w, isNotNull);
  expect((w!.onsetSec - _at(c, segments, sleepSeg)).abs(),
      lessThanOrEqualTo(10 * 60), reason: 'onset');
  expect((w.offsetSec - _at(c, segments, sleepSeg + 1)).abs(),
      lessThanOrEqualTo(10 * 60), reason: 'wake');
}

void main() {
  for (final c in [60, 300]) {
    group('at $c s per sample', () {
      test('a full day: a slow morning is not read as sleep', () {
        _expectNight(c, const [
          (8 * 60, 74), (60, 150), (2 * 60, 74), // day, workout, evening
          (8 * 60, 54), // night
          (2 * 60, 68), (3 * 60, 74), // slow morning, day
        ], 3);
      });

      test('a partial day under 18 h (synced mid-morning)', () {
        _expectNight(c, const [
          (5 * 60, 74),
          (8 * 60, 54),
          (3 * 60, 68),
        ], 1);
      });

      test('a 10 h sleeper whose watch charged in the afternoon', () {
        // 19 h of samples, over half of them asleep: the median of the
        // record is a sleeping HR.
        _expectNight(c, const [
          (2 * 60, 74),
          (10 * 60, 54),
          (4 * 60, 72),
          (5 * 60, 0), // charging
          (3 * 60, 74),
        ], 1);
      });

      test('the first day of data, clamped 30 min before sleep', () {
        _expectNight(c, const [
          (30, 74),
          (8 * 60, 54),
          (2 * 60, 68),
          (8 * 60, 74),
        ], 1);
      });

      test('a ring worn only in bed never runs past the wake', () {
        const segments = [(60, 70), (8 * 60, 54), (30, 70)];
        final r = _record(c, segments);
        final w = hrLedWindow(r.ts, r.hr, c);
        if (w != null) {
          expect(w.onsetSec, greaterThanOrEqualTo(_at(c, segments, 1) - 600));
          expect(w.offsetSec, lessThanOrEqualTo(_at(c, segments, 2) + 600));
        }
      });

      test('a flat day has no night', () {
        final r = _record(c, const [(24 * 60, 74)]);
        expect(hrLedWindow(r.ts, r.hr, c), isNull);
      });
    });
  }

  test('a Pebble sampling HR every 10 minutes still has a night', () {
    // Minute records, HR in every tenth: 8 h awake, 8 h asleep, 8 h awake.
    final full = _record(60, const [(480, 75), (480, 52), (480, 75)]);
    final ts = [for (var i = 0; i < full.ts.length; i += 10) full.ts[i]];
    final hr = [for (var i = 0; i < full.hr.length; i += 10) full.hr[i]];
    expect(hrLedWindow(ts, hr, 60), isNull,
        reason: 'a 5-min hole ends every run');
    final w = hrLedWindow(ts, hr, 60, maxGapSec: kPebbleHrMaxGapSec)!;
    expect((w.offsetSec - w.onsetSec) ~/ 60, inInclusiveRange(440, 500));
  });
}
