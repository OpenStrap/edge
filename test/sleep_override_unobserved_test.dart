// "I was asleep" is offered on nights with no detected sleep, and the usual
// reason there is none is that the band was on the charger. A user-set window
// over those hours is mostly unobserved, so the segmenter abstains with a
// reason. The day used to derive with sleep_source 'none' — as if no override
// existed — which threw the reason away and left the Sleep screen blaming a
// busy re-analysis.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/substrate.dart';

int _sec(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

/// Band worn [from, to) at 1 Hz: still wrist, resting HR.
void _wear(int from, int to, List<int> ts, List<int> hr, List<double> ax,
    List<double> ay, List<double> az) {
  for (var t = from; t < to; t++) {
    ts.add(t);
    hr.add(60);
    final rad = (t % 3) * 0.5 * math.pi / 180.0;
    ax.add(math.sin(rad));
    ay.add(0.0);
    az.add(math.cos(rad));
  }
}

Substrate _sub(List<(int, int)> worn) {
  final ts = <int>[], hr = <int>[];
  final ax = <double>[], ay = <double>[], az = <double>[];
  for (final (a, b) in worn) {
    _wear(a, b, ts, hr, ax, ay, az);
  }
  final n = ts.length;
  return Substrate(
    tsSec: ts,
    hr: hr,
    rrTsMs: const [],
    rrMs: const [],
    ax: ax,
    ay: ay,
    az: az,
    spo2Red: List<int>.filled(n, 0),
    spo2Ir: List<int>.filled(n, 0),
    skinTemp: List<int>.filled(n, 0),
    skinContact: List<int>.filled(n, 0),
  );
}

void main() {
  final eve = DateTime(2025, 6, 14);
  final day = DateTime(2025, 6, 15);
  final onset = _sec(DateTime(2025, 6, 14, 23));
  final wake = _sec(DateTime(2025, 6, 15, 7));
  const dayId = '2025-06-15';

  PhysioDay derive(Substrate sub, String source) => calendarDays(
        sub,
        override: SleepWindowOverride(
          dayId: dayId,
          onsetSec: onset,
          offsetSec: wake,
          source: source,
        ),
      ).firstWhere((d) => d.date == dayId);

  test('a mostly-unrecorded manual window keeps its source and its reason',
      () {
    // Worn 18:00–22:00, on the charger 22:00–06:00, worn 06:00–12:00.
    final sub = _sub([
      (_sec(DateTime(eve.year, eve.month, eve.day, 18)),
          _sec(DateTime(eve.year, eve.month, eve.day, 22))),
      (_sec(DateTime(day.year, day.month, day.day, 6)),
          _sec(DateTime(day.year, day.month, day.day, 12))),
    ]);
    final d = derive(sub, 'manual');
    expect(d.sleep.present, isFalse);
    expect(d.sleepSource, 'manual');
    expect(d.sleep.absenceReason, isNotNull);
    expect(d.flags, contains('NO_SLEEP_DETECTED'));
  });

  test('a manual window with no samples at all says it was unrecorded', () {
    // Nothing between 20:00 and 08:00 — the window holds zero seconds.
    final sub = _sub([
      (_sec(DateTime(eve.year, eve.month, eve.day, 18)),
          _sec(DateTime(eve.year, eve.month, eve.day, 20))),
      (_sec(DateTime(day.year, day.month, day.day, 8)),
          _sec(DateTime(day.year, day.month, day.day, 12))),
    ]);
    final d = derive(sub, 'manual');
    expect(d.sleep.present, isFalse);
    expect(d.sleepSource, 'manual');
    expect(d.sleep.absenceReason, isNotNull);
  });

  test('a rejected night is unchanged', () {
    final sub = _sub([
      (_sec(DateTime(eve.year, eve.month, eve.day, 18)),
          _sec(DateTime(day.year, day.month, day.day, 12))),
    ]);
    final d = derive(sub, 'rejected');
    expect(d.sleep.present, isFalse);
    expect(d.sleepSource, 'rejected');
    expect(d.flags, contains('SLEEP_REJECTED'));
  });
}
